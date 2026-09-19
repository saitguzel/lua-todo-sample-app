-- CORS middleware: whitelist kontrollü Origin izni ve preflight
-- Access-Control-Allow-Credentials yok, Bearer header kullanılır.
local config = require("config")
local _M = {}

function _M.handle()
  local origin = ngx.var.http_origin
  if not origin then return nil end
  -- config yoksa (test) izin verme
  local cors_set = config.current and config.current.cors_origins or {}
  -- CORS_ORIGINS csv listesi; set ise
  if not cors_set[origin] then
    if ngx.req.get_method() == "OPTIONS" then
      return { status = 403, json = { error = { code = "FORBIDDEN", message = "Origin reddedildi" } } }
    end
    return nil
  end
  ngx.header["Access-Control-Allow-Origin"] = origin
  ngx.header["Vary"] = "Origin"
  ngx.header["Access-Control-Expose-Headers"] = "X-Request-Id, Retry-After, Content-Disposition"
  if ngx.req.get_method() == "OPTIONS" then
    ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
    ngx.header["Access-Control-Max-Age"] = "600"
    return { status = 204, layout = false }
  end
  return nil
end

return _M
