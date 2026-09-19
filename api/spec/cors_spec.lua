-- CORS: preflight kararı ve header_filter'ın her yanıta (hata dahil) header basması
-- luacheck: ignore 122 (ngx.var/header/req test için stub'lanır)
describe("middleware.cors", function()
  local cors, config
  local saved = {}
  local method, origin, headers

  before_each(function()
    config = require("config")
    saved.current, saved.var, saved.header, saved.req = config.current, ngx.var, ngx.header, ngx.req
    config.current = { cors_origins = { ["http://localhost:28000"] = true } }
    headers = {}
    ngx.var = setmetatable({}, { __index = function(_, k) if k == "http_origin" then return origin end end })
    ngx.header = headers
    ngx.req = { get_method = function() return method end }
    package.loaded["middleware.cors"] = nil
    cors = require("middleware.cors")
  end)

  after_each(function()
    config.current, ngx.var, ngx.header, ngx.req = saved.current, saved.var, saved.header, saved.req
  end)

  it("izinli origin preflight → 204 + method/header izinleri", function()
    method, origin = "OPTIONS", "http://localhost:28000"
    local res = cors.handle()
    assert.equal(204, res.status)
    assert.truthy(headers["Access-Control-Allow-Methods"]:find("PATCH"))
  end)

  it("izinsiz origin preflight → 403", function()
    method, origin = "OPTIONS", "http://evil.com"
    assert.equal(403, cors.handle().status)
  end)

  it("OPTIONS olmayan istek zinciri durdurmaz", function()
    method, origin = "GET", "http://localhost:28000"
    assert.is_nil(cors.handle())
  end)

  it("header_filter: izinli origin → Allow-Origin + Vary", function()
    origin = "http://localhost:28000"
    cors.header_filter()
    assert.equal(origin, headers["Access-Control-Allow-Origin"])
    assert.equal("Origin", headers["Vary"])
  end)

  it("header_filter: izinsiz origin → yalnız Vary, Allow-Origin yok", function()
    origin = "http://evil.com"
    cors.header_filter()
    assert.is_nil(headers["Access-Control-Allow-Origin"])
    assert.equal("Origin", headers["Vary"])
  end)

  it("header_filter: Origin yoksa hiçbir header yok", function()
    origin = nil
    cors.header_filter()
    assert.is_nil(next(headers))
  end)
end)
