-- RBAC birim testleri (resty altında, gerçek rbac_cache shared dict'i): can, cache, kilit, authorization
local types = require("todo_shared.types")

-- Sahte repo: bellekteki matris; çağrı sayacı cache testleri için
local state = { calls = 0, matrix = {} }
local function reset_state()
  state.calls = 0
  for _, role in ipairs(types.ROLES) do
    state.matrix[role] = {}
    for _, page in ipairs(types.PAGES) do state.matrix[role][page] = types.default_permission(role, page) end
  end
end

local audit_calls = {}
local CFG = { rbac_cache_ttl = 60 }

local function load_service()
  package.loaded["config"] = { get = function() return CFG end, current = CFG }
  package.loaded["repositories.rbac_repo"] = {
    by_role = function(role)
      state.calls = state.calls + 1
      local rows = {}
      for page, v in pairs(state.matrix[role] or {}) do rows[#rows + 1] = { page_key = page, can_access = v } end
      return rows
    end,
    all = function()
      local rows = {}
      for role, pages in pairs(state.matrix) do
        for page, v in pairs(pages) do rows[#rows + 1] = { role = role, page_key = page, can_access = v } end
      end
      return rows
    end,
    upsert = function(role, page, v) state.matrix[role][page] = v; return true end,
    lock_all = function() return true end,
  }
  package.loaded["db.query"] = { with_transaction = function(fn) return fn() end }
  package.loaded["services.audit_service"] = {
    record = function(action, opts) audit_calls[#audit_calls + 1] = { action = action, opts = opts } end,
  }
  package.loaded["services.rbac_service"] = nil
  return require("services.rbac_service")
end

describe("rbac_service", function()
  local rbac

  before_each(function()
    reset_state()
    audit_calls = {}
    CFG.rbac_cache_ttl = 60
    ngx.shared.rbac_cache:flush_all()
    rbac = load_service()
  end)

  it("admin her sayfaya erişir", function()
    for _, p in ipairs(types.PAGES) do assert.is_true(rbac.can("admin", p), p) end
  end)

  it("todouser: users.list yok, todos.edit var", function()
    assert.is_false(rbac.can("todouser", "users.list"))
    assert.is_true(rbac.can("todouser", "todos.edit"))
  end)

  it("bilinmeyen page ve rol fail-closed", function()
    assert.is_false(rbac.can("admin", "yok.sayfa"))
    assert.is_false(rbac.can("root", "dashboard"))
  end)

  it("cache: ikinci çağrı repo'ya gitmez", function()
    rbac.can("admin", "dashboard")
    rbac.can("admin", "todos.list")
    assert.equal(1, state.calls)
  end)

  it("cache: TTL dolunca repo'ya tekrar gider", function()
    CFG.rbac_cache_ttl = 0.01
    rbac.can("admin", "dashboard")
    ngx.sleep(0.05)
    rbac.can("admin", "dashboard")
    assert.equal(2, state.calls)
  end)

  it("update_matrix cache'i invalidate eder ve audit yazar", function()
    assert.is_false(rbac.can("todouser", "users.list"))
    local res, err = rbac.update_matrix({ user_id = "1" },
      { permissions = { { role = "todouser", page_key = "users.list", can_access = true } } })
    assert.is_nil(err)
    assert.truthy(res)
    assert.is_true(rbac.can("todouser", "users.list"))
    assert.equal("rbac.matrix.update", audit_calls[1].action)
  end)

  it("set_cell admin/rbac.matrix false → CONFLICT", function()
    local _, err = rbac.set_cell({ user_id = "1" }, "admin", "rbac.matrix", false)
    assert.equal("CONFLICT", err.code)
    assert.is_true(state.matrix.admin["rbac.matrix"])
  end)

  it("update_matrix kilit hücresi → CONFLICT", function()
    local _, err = rbac.update_matrix({ user_id = "1" }, { admin = { ["rbac.matrix"] = false } })
    assert.equal("CONFLICT", err.code)
  end)
end)

describe("authorization middleware", function()
  local authz, saved_req, saved_var, audit_rec

  setup(function()
    -- resty timer bağlamında ngx.req/ngx.var yok; test süresince sahtele
    saved_req, saved_var = ngx.req, ngx.var
    ngx.req = { get_method = function() return "GET" end } -- luacheck: ignore 122
    ngx.var = { uri = "/api/v1/rbac/matrix" }
    package.loaded["services.audit_service"] = {
      record = function(action, opts) audit_rec = { action = action, opts = opts } end,
    }
    package.loaded["services.rbac_service"] = {
      can = function(role, page) return role == "admin" or page == "dashboard" end,
    }
    package.loaded["middleware.authorization"] = nil
    authz = require("middleware.authorization")
  end)

  teardown(function()
    ngx.req, ngx.var = saved_req, saved_var -- luacheck: ignore 122
    ngx.ctx.identity = nil
  end)

  before_each(function() audit_rec = nil end)

  it("izin varsa zincir devam eder (nil)", function()
    ngx.ctx.identity = { role = "admin", user_id = "1" }
    assert.is_nil(authz.requires("rbac.matrix")({}))
  end)

  it("izin yoksa 403 FORBIDDEN + access.denied audit", function()
    ngx.ctx.identity = { role = "todouser", user_id = "2" }
    local res = authz.requires("rbac.matrix")({})
    assert.equal(403, res.status)
    assert.equal("FORBIDDEN", res.json.error.code)
    assert.equal("access.denied", audit_rec.action)
    assert.equal("rbac.matrix", audit_rec.opts.new_value.page_key)
    assert.equal("GET", audit_rec.opts.new_value.method)
  end)

  it("identity yoksa 401 (auth çalışmamış — savunma)", function()
    ngx.ctx.identity = nil
    local res = authz.requires("dashboard")({})
    assert.equal(401, res.status)
    assert.equal("UNAUTHORIZED", res.json.error.code)
  end)
end)
