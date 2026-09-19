-- F13: HTTP istemcisi. JS callback'i Lua coroutine'e çevirir (yield/resume);
-- 401 TOKEN_EXPIRED'da tek-uçuş refresh yapıp isteği bir kez tekrarlar.
-- Frontend'e özel kodlar NETWORK_ERROR / INVALID_RESPONSE yalnızca burada üretilir
-- (shared/protocol'a eklenmez — 00-genel-bakis §5).

local json = require("json")

local api = {}

local cfg = {
  base = "http://localhost:28080/api/v1",
  get_tokens = function() return nil end,
  set_tokens = function() end,
  on_logout = function() end,
  on_forbidden = function() end,
}

function api.configure(opts)
  for k, v in pairs(opts) do cfg[k] = v end
end

-- --- coroutine köprüsü ------------------------------------------------------

-- JS callback'li bir çağrıyı bekler; callback senkron gelse de (test mock'u) doğru çalışır
local function await(start)
  local co, is_main = coroutine.running()
  assert(not is_main, "api.* bir coroutine içinde çağrılmalı (app.spawn kullanın)")
  local done, result, waiting = false, nil, false
  start(function(...)
    done, result = true, table.pack(...)
    if waiting then
      local ok, err = coroutine.resume(co)
      if not ok then js.log("error", "coroutine hatası: " .. tostring(err)) end
    end
  end)
  if not done then
    waiting = true
    coroutine.yield()
  end
  return table.unpack(result, 1, result.n)
end

-- Tek bir HTTP çağrısı; dönüş: res tablosu (net_err/status/text/ctype/retry_after)
local function request_once(method, path, headers, body)
  local net_err, status, text, ctype, retry_after = await(function(cb)
    js.http.request(method, cfg.base .. path, json.encode(headers), body, cb)
  end)
  return { net_err = net_err, status = status, text = text, ctype = ctype, retry_after = tonumber(retry_after) }
end

-- --- hata normalize ---------------------------------------------------------

local function client_error(code, message, status, details)
  return { code = code, message = message, status = status, details = details }
end

local function normalize(res, status)
  local body
  if res.text and #res.text > 0 then
    local ok, decoded = pcall(json.decode, res.text)
    if ok then body = decoded end
  end
  local err_tbl = type(body) == "table" and body.error
  if err_tbl and err_tbl.code then
    local e = client_error(err_tbl.code, err_tbl.message, status, err_tbl.details)
    e.retry_after = res.retry_after or (type(err_tbl.details) == "table" and err_tbl.details.retry_after) or nil
    return e
  end
  return client_error("INVALID_RESPONSE", "Beklenmeyen sunucu yanıtı", status)
end

local function encode_query(query)
  if not query then return "" end
  local parts = {}
  for k, v in pairs(query) do
    if v ~= nil and v ~= "" then
      parts[#parts + 1] = tostring(k) .. "=" .. (tostring(v):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
      end))
    end
  end
  if #parts == 0 then return "" end
  table.sort(parts)
  return "?" .. table.concat(parts, "&")
end

-- JSON dizisi mi? (boş tablo da liste sayılır: API boş listeyi {} olarak da döndürebilir)
local function is_array(t)
  if type(t) ~= "table" then return false end
  if next(t) == nil then return true end
  return t[1] ~= nil
end

-- 2xx yanıtı: liste zarfı → { items, meta }; tekil → data, nil, meta
local function handle_success(res)
  if not res.text or #res.text == 0 then return true, nil end
  local ok, body = pcall(json.decode, res.text)
  if not ok or type(body) ~= "table" then
    return nil, client_error("INVALID_RESPONSE", "Beklenmeyen sunucu yanıtı", res.status)
  end
  local data = body.data
  if body.meta ~= nil and is_array(data) then
    return { items = data, meta = body.meta }, nil, body.meta
  end
  if data == nil then return true, nil, body.meta end
  return data, nil, body.meta
end

-- --- tek-uçuş refresh --------------------------------------------------------

local refreshing = nil -- nil | { waiters = { co, ... } }

local function do_refresh()
  local tokens = cfg.get_tokens()
  if not tokens or not tokens.refresh_token then return false end
  local res = request_once("POST", "/auth/refresh", { ["Content-Type"] = "application/json" },
    json.encode({ refresh_token = tokens.refresh_token }))
  if res.net_err or res.status ~= 200 then return false end
  local ok, body = pcall(json.decode, res.text)
  if not ok or type(body) ~= "table" or type(body.data) ~= "table" then return false end
  cfg.set_tokens(body.data.access_token, body.data.refresh_token)
  return true
end

local function refresh_once()
  if refreshing then
    local co = coroutine.running()
    table.insert(refreshing.waiters, co)
    return coroutine.yield() -- resume(co, ok) ile döner
  end
  refreshing = { waiters = {} }
  local ok = do_refresh()
  local waiters = refreshing.waiters
  refreshing = nil
  for _, co in ipairs(waiters) do
    local r, e = coroutine.resume(co, ok)
    if not r then js.log("error", tostring(e)) end
  end
  return ok
end

-- --- public API ---------------------------------------------------------------

-- Authorization eklenmeyen uçlar (/auth/me ve /auth/logout token ister)
local function is_public_auth(path)
  return path:find("^/auth/") ~= nil and not path:find("^/auth/me") and not path:find("^/auth/logout")
end

local function call(method, path, query, body)
  local url = path .. encode_query(query)
  local headers = { Accept = "application/json" }
  if body ~= nil then headers["Content-Type"] = "application/json" end
  local public = is_public_auth(path)
  local tokens = cfg.get_tokens()
  if tokens and tokens.access_token and not public then
    headers["Authorization"] = "Bearer " .. tokens.access_token
  end
  local payload = body ~= nil and json.encode(body) or nil

  local res = request_once(method, url, headers, payload)
  if res.net_err then
    return nil, client_error("NETWORK_ERROR", "Sunucuya ulaşılamadı")
  end

  if res.status == 401 and not public then
    local err = normalize(res, 401)
    -- yalnızca süresi dolmuş access token yenilenir; diğer 401'ler oturumu kapatır
    if err.code == "TOKEN_EXPIRED" and refresh_once() then
      local tokens2 = cfg.get_tokens()
      headers["Authorization"] = tokens2 and tokens2.access_token and ("Bearer " .. tokens2.access_token) or nil
      res = request_once(method, url, headers, payload)
      if res.net_err then return nil, client_error("NETWORK_ERROR", "Sunucuya ulaşılamadı") end
      if res.status >= 200 and res.status < 300 then return handle_success(res) end
      err = normalize(res, res.status)
      if res.status ~= 401 then return nil, err end
    end
    cfg.on_logout()
    return nil, err
  end

  if res.status >= 200 and res.status < 300 then
    return handle_success(res)
  end
  local err = normalize(res, res.status)
  -- 403: izinler değişmiş olabilir → menü/guard için tazele
  if res.status == 403 and err.code == "FORBIDDEN" then cfg.on_forbidden() end
  return nil, err
end

function api.get(path, query) return call("GET", path, query, nil) end
function api.post(path, body) return call("POST", path, nil, body) end
function api.put(path, body) return call("PUT", path, nil, body) end
function api.patch(path, body) return call("PATCH", path, nil, body) end
function api.delete(path) return call("DELETE", path, nil, nil) end

-- CSV export: blob indirme (Authorization'ı JS tarafı ekler). Coroutine içinde: bitene kadar bekler.
function api.download(path, filename, query)
  local tokens = cfg.get_tokens()
  local err = await(function(cb)
    js.http.download(cfg.base .. path .. encode_query(query), tokens and tokens.access_token or nil, filename, cb)
  end)
  if err then return nil, client_error("NETWORK_ERROR", tostring(err)) end
  return true
end

-- Test yardımcıları
api._encode_query = encode_query
api._normalize = normalize

return api
