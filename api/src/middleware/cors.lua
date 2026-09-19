-- CORS: whitelist kontrollü Origin izni. Preflight (OPTIONS) middleware zincirinde yanıtlanır;
-- ortak header'lar header_filter fazında basılır ki 404/405/413 gibi zincir dışı hatalar da okunabilsin.
-- Access-Control-Allow-Credentials yok, Bearer header kullanılır.
local config = require("config")
local _M = {}

local function allowed(origin)
  local cors_set = config.current and config.current.cors_origins or {}
  return origin ~= nil and cors_set[origin] == true
end

-- Zincirin ilk halkası: yalnızca preflight'ı sonlandırır
function _M.handle()
  if ngx.req.get_method() ~= "OPTIONS" then return nil end
  local origin = ngx.var.http_origin
  if not origin then return nil end
  if not allowed(origin) then
    return { status = 403, json = { error = { code = "FORBIDDEN", message = "Origin reddedildi" } } }
  end
  ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  ngx.header["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
  ngx.header["Access-Control-Max-Age"] = "600"
  return { status = 204, layout = false }
end

-- header_filter_by_lua (server seviyesi): her yanıta, hata dahil
function _M.header_filter()
  local origin = ngx.var.http_origin
  if not origin then return end
  -- yanıt Origin'e göre değişir; izin verilmeyen origin için de cache ayrışmalı
  ngx.header["Vary"] = "Origin"
  if not allowed(origin) then return end
  ngx.header["Access-Control-Allow-Origin"] = origin
  ngx.header["Access-Control-Expose-Headers"] = "X-Request-Id, Retry-After, Content-Disposition"
end

return _M
