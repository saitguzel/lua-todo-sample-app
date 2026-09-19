-- OpenAPI spec yapi ve kapsama testleri
local cjson = require("cjson.safe")

describe("openapi spec", function()
  local spec, routes
  setup(function()
    local cfg = { app = { base_url = "http://localhost:28080", env = "test" }, rbac_cache_ttl = 60,
                  APP_BASE_URL = "http://localhost:28080", APP_ENV = "test" }
    package.loaded["config"] = { get = function() return cfg end, current = cfg }
    spec = require("openapi.spec").build()
    routes = require("router").route_list()
  end)

  it("3.1.0 surumunu bildirir", function()
    assert.equal("3.1.0", spec.openapi)
  end)

  it("router'daki her route spec'te var", function()
    for _, r in ipairs(routes) do
      local p = r.path:gsub("^/api/v1", ""):gsub(":([%w_]+)", "{%1}")
      assert.is_table(spec.paths[p], "spec'te yok: " .. p)
      assert.is_table(spec.paths[p][r.method:lower()], "metot yok: " .. r.method .. " " .. p)
    end
  end)

  it("spec'teki her operasyon router'da var (ters yon)", function()
    local route_map = {}
    for _, r in ipairs(routes) do
      local p = r.path:gsub("^/api/v1", ""):gsub(":([%w_]+)", "{%1}")
      route_map[p .. "#" .. r.method:lower()] = true
    end
    for path, methods in pairs(spec.paths) do
      for method, _ in pairs(methods) do
        if ({ get = true, post = true, put = true, patch = true, delete = true })[method] then
          local key = path .. "#" .. method
          assert.truthy(route_map[key], "router'da yok: " .. method .. " " .. path)
        end
      end
    end
  end)

  it("Error.code enum'u protocol.CODE_LIST ile ayni", function()
    local protocol = require("todo_shared.protocol")
    assert.same(protocol.CODE_LIST, spec.components.schemas.Error.properties.code.enum)
  end)

  it("JSON'a encode edilebilir ve acik endpoint'lerde security = []", function()
    local json = cjson.encode(spec)
    assert.truthy(json:find('"security":%[%]'))
  end)

  it("korumali operasyonlar x-page-key tasir (auth ve system haric)", function()
    local http_methods = { get = true, post = true, put = true, patch = true, delete = true }
    for path, methods in pairs(spec.paths) do
      for method, op in pairs(methods) do
        local public = type(op.security) == "table" and #op.security == 0
        local tag = op.tags and op.tags[1]
        if http_methods[method] and not public and tag ~= "auth" and tag ~= "system" then
          assert.is_string(op["x-page-key"], "x-page-key yok: " .. method .. " " .. path)
        end
      end
    end
  end)
end)
