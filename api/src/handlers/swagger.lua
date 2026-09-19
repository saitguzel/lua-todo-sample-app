-- Swagger/OpenAPI handler'lar: spec JSON ve UI
local cjson = require("cjson.safe")
local spec = require("openapi.spec")

local resty_sha256 = require("resty.sha256")

local _M = {}
local cached_json
local cached_html
local cached_csp

-- CSP: CDN + inline init script'in sha256'sı (index.html'den çalışma anında hesaplanır → değişince bozulmaz)
local CSP_TPL = "default-src 'none'; script-src https://cdn.jsdelivr.net %s; "
  .. "style-src https://cdn.jsdelivr.net 'unsafe-inline'; img-src 'self' data: https://cdn.jsdelivr.net; "
  .. "connect-src 'self'; font-src https://cdn.jsdelivr.net; frame-ancestors 'none'"

function _M.csp_for(html)
  local hashes = {}
  for body in html:gmatch("<script>(.-)</script>") do
    local h = resty_sha256:new()
    h:update(body)
    hashes[#hashes + 1] = "'sha256-" .. ngx.encode_base64(h:final()) .. "'"
  end
  return CSP_TPL:format(table.concat(hashes, " "))
end

function _M.spec_json()
  if not cached_json then
    cached_json = assert(cjson.encode(spec.build()))
  end
  ngx.header["Content-Type"] = "application/json; charset=utf-8"
  ngx.header["Cache-Control"] = "public, max-age=300"
  ngx.header["Content-Length"] = tostring(#cached_json)
  ngx.print(cached_json)
  return { status = 200, layout = false }
end

function _M.ui()
  if not cached_html then
    local prefix = ngx.config.prefix() or "/app/"
    local path = prefix .. "public/swagger/index.html"
    -- fallback
    local f = io.open(path, "rb")
    if not f then f = io.open("/app/public/swagger/index.html", "rb") end
    if f then
      cached_html = f:read("*a")
      f:close()
    else
      cached_html = "<html><body>Swagger UI not found</body></html>"
    end
    cached_csp = _M.csp_for(cached_html)
  end
  ngx.header["Content-Type"] = "text/html; charset=utf-8"
  ngx.header["Content-Security-Policy"] = cached_csp
  ngx.header["Content-Length"] = tostring(#cached_html)
  ngx.print(cached_html)
  return { status = 200, layout = false }
end

return _M
