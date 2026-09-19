-- Merkezi hata yönetimi: AppError oluşturma, HTTP yanıtına çevirme
-- Tüm middleware ve handler zinciri xpcall ile sarılır.
local cjson = require("cjson.safe")
local protocol = require("todo_shared.protocol")
local validation = require("todo_shared.validation")

local _M = {}

function _M.new(code, message, details, extra)
  local err = {
    code = code,
    message = message or protocol.message(code),
    details = details,
    __app_error = true,
  }
  if extra then
    for k, v in pairs(extra) do err[k] = v end
  end
  return err
end

function _M.is_app_error(e)
  return type(e) == "table" and e.__app_error == true
end

function _M.respond(err)
  if not _M.is_app_error(err) then
    err = _M.new("INTERNAL_ERROR", "Beklenmeyen bir hata oluştu")
  end
  local status = protocol.http_status(err.code)
  local headers = err.headers
  if status >= 500 then
    -- 5xx: iç ayrıntı (SQL, stack, host) istemciye gitmez; kanonik mesaj + details yok
    err = { code = err.code, message = protocol.message(err.code) }
  end
  local body = protocol.error_body(err, ngx.ctx and ngx.ctx.req_id or "-")
  return { status = status, json = body, headers = headers }
end

function _M.guard(fn)
  local ok, res = xpcall(fn, debug.traceback)
  if ok then return res end
  -- res string traceback veya tablo
  if _M.is_app_error(res) then
    ngx.log(ngx.ERR, cjson.encode({ req_id = ngx.ctx and ngx.ctx.req_id, err = res.code }))
    if ngx.headers_sent then return ngx.exit(ngx.ERROR) end
    return _M.respond(res)
  end
  ngx.log(ngx.ERR, cjson.encode({ req_id = ngx.ctx and ngx.ctx.req_id, err = tostring(res) }))
  if ngx.headers_sent then return ngx.exit(ngx.ERROR) end
  return _M.respond(_M.new("INTERNAL_ERROR", "Beklenmeyen bir hata oluştu"))
end

-- JSON gövde okuma (tüm handler'lar kullanır)
-- @return table | nil, AppError(BAD_REQUEST | PAYLOAD_TOO_LARGE)
function _M.read_json_body()
  ngx.req.read_body()
  local data = ngx.req.get_body_data()
  if not data and ngx.req.get_body_file() then
    -- client_body_buffer_size aşıldı (nginx 1m sınırı zaten 413 döner)
    return nil, _M.new("PAYLOAD_TOO_LARGE", "Istek govdesi cok buyuk")
  end
  local ctype = ngx.var.http_content_type or ""
  if not ctype:lower():find("^application/json") then
    return nil, _M.new("BAD_REQUEST", "Content-Type application/json olmali")
  end
  local decoded = data and cjson.decode(data)
  if decoded == nil then
    return nil, _M.new("BAD_REQUEST", "Gecersiz JSON")
  end
  if type(decoded) ~= "table" then
    return nil, _M.new("BAD_REQUEST", "JSON nesne olmali")
  end
  return decoded, nil
end

function _M.validation(field_errors)
  return _M.new("VALIDATION_FAILED", protocol.message("VALIDATION_FAILED"), field_errors)
end

function _M.require_uuid_param(self, name, not_found_code)
  local v = self.params and self.params[name]
  if not validation.is_uuid(v) then
    return nil, _M.new(not_found_code or "NOT_FOUND", "Kaynak bulunamadi")
  end
  return v, nil
end

function _M.on_unhandled(err, trace)
  ngx.log(ngx.ERR, "unhandled: ", tostring(err), " trace: ", tostring(trace))
  local body = protocol.error_body(
    { code = "INTERNAL_ERROR", message = "Beklenmeyen bir hata olustu" },
    ngx.ctx and ngx.ctx.req_id or "-"
  )
  ngx.status = 500
  ngx.header["Content-Type"] = "application/json"
  ngx.say(cjson.encode(body))
  return ngx.exit(500)
end

return _M
