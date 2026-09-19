-- Auth HTTP handler'lari: body dogrular, servise delege eder
local validation = require("todo_shared.validation")
local errors = require("middleware.error_handler")
local auth_service = require("services.auth_service")
local rbac_service = require("services.rbac_service")

local _M = {}

function _M.login()
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, field_errors = validation.validate(validation.schemas.login, input)
  if not clean then return errors.respond(errors.validation(field_errors)) end
  local result, serr = auth_service.login(clean.email, clean.password)
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result } }
end

-- Gövde opsiyonel: yoksa yalnızca access token iptal edilir
function _M.logout()
  local input = {}
  local has_body = (tonumber(ngx.var.content_length) or 0) > 0 or ngx.var.http_transfer_encoding ~= nil
  if has_body then
    local body, err = errors.read_json_body()
    if not body then return errors.respond(err) end
    local clean, field_errors = validation.validate(validation.schemas.logout, body)
    if not clean then return errors.respond(errors.validation(field_errors)) end
    input = clean
  end
  local ok, serr = auth_service.logout(ngx.ctx.identity, input.refresh_token)
  if not ok then return errors.respond(serr) end
  return { status = 204, layout = false }
end

function _M.refresh()
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, field_errors = validation.validate(validation.schemas.refresh, input)
  if not clean then return errors.respond(errors.validation(field_errors)) end
  local result, serr = auth_service.refresh(clean.refresh_token)
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result } }
end

function _M.forgot_password()
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, field_errors = validation.validate(validation.schemas.forgot_password, input)
  if not clean then return errors.respond(errors.validation(field_errors)) end
  local ok, serr = auth_service.forgot_password(clean.email)
  if not ok then
    if serr and serr.code == "RATE_LIMITED" then return errors.respond(serr) end
    -- diger hatalar yine 202 (sızdırmaz)
  end
  return { status = 202, json = { data = { message = "Eger bu e-posta kayitliysa sifirlama baglantisi gonderildi." } } }
end

function _M.reset_password()
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, field_errors = validation.validate(validation.schemas.reset_password, input)
  if not clean then return errors.respond(errors.validation(field_errors)) end
  local ok, serr = auth_service.reset_password(clean.token, clean.new_password)
  if not ok then return errors.respond(serr) end
  return { status = 204, layout = false }
end

-- İzinler token'daki değil DB'deki güncel rolden hesaplanır (rol değişimi anında yansır)
function _M.me()
  local user_data, err = auth_service.me(ngx.ctx.identity)
  if not user_data then return errors.respond(err) end
  local perms = rbac_service.permissions_for(user_data.role)
  return { status = 200, json = { data = { user = user_data, permissions = perms } } }
end

return _M
