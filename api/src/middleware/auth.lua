-- Bearer token dogrulama -> ngx.ctx.identity
local jwt = require("security.jwt")
local errors = require("middleware.error_handler")
local auth_service = require("services.auth_service")

local _M = {}

function _M.required()
  local header = ngx.var.http_authorization
  local token = header and header:match("^[Bb]earer%s+([%w%-_%.]+)$")
  if not token then
    local err = errors.new("UNAUTHORIZED", "Kimlik dogrulama gerekli")
    err.headers = { ["WWW-Authenticate"] = 'Bearer error="invalid_token"' }
    return errors.respond(err)
  end
  local claims, err = jwt.verify(token, "access")
  if not claims then
    local code = err == "TOKEN_EXPIRED" and "TOKEN_EXPIRED" or "UNAUTHORIZED"
    local e = errors.new(code, "Gecersiz veya suresi dolmus token")
    e.headers = { ["WWW-Authenticate"] = 'Bearer error="invalid_token"' }
    return errors.respond(e)
  end
  if auth_service.is_revoked(claims.jti) then
    local e = errors.new("TOKEN_REVOKED", "Token iptal edilmis")
    e.headers = { ["WWW-Authenticate"] = 'Bearer error="invalid_token"' }
    return errors.respond(e)
  end
  ngx.ctx.identity = {
    user_id = claims.user_id,
    email = claims.email,
    role = claims.role,
    jti = claims.jti,
    exp = claims.exp,
  }
  return nil
end

return _M
