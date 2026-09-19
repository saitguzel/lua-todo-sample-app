-- bootstrap: shared modülleri preload et
package.path = package.path .. ";shared/src/?.lua;shared/src/?/init.lua"
package.preload["todo_shared.types"] = function() return dofile("shared/src/types.lua") end
package.preload["todo_shared.validation"] = function() return dofile("shared/src/validation.lua") end
package.preload["todo_shared.protocol"] = function() return dofile("shared/src/protocol.lua") end

local types = require("todo_shared.types")
local protocol = require("todo_shared.protocol")
local v = require("todo_shared.validation")

describe("types", function()
  it("ROLES 2 eleman ve doğru", function()
    assert.same({ "admin", "todouser" }, types.ROLES)
  end)
  it("PAGES 9 eleman", function()
    assert.equal(9, #types.PAGES)
    assert.equal("dashboard", types.PAGES[1])
    assert.equal("settings", types.PAGES[9])
  end)
  it("default_permission admin hepsi true", function()
    for _, p in ipairs(types.PAGES) do
      assert.is_true(types.default_permission("admin", p))
    end
  end)
  it("todouser yalnızca 4 sayfa", function()
    assert.is_true(types.default_permission("todouser", "dashboard"))
    assert.is_true(types.default_permission("todouser", "todos.list"))
    assert.is_true(types.default_permission("todouser", "todos.create"))
    assert.is_true(types.default_permission("todouser", "todos.edit"))
    assert.is_false(types.default_permission("todouser", "users.list"))
    assert.is_false(types.default_permission("todouser", "rbac.matrix"))
  end)
  it("is_locked", function()
    assert.is_true(types.is_locked("admin", "rbac.matrix"))
    assert.is_false(types.is_locked("todouser", "rbac.matrix"))
  end)
  it("AUDIT_ACTIONS 14 eleman", function()
    assert.equal(14, #types.AUDIT_ACTIONS)
  end)
  it("default_matrix 18 hücre ve valid", function()
    local m = types.default_matrix()
    assert.equal(18, #m.permissions)
    local clean, err = v.validate(v.schemas.rbac_matrix, m)
    assert.is_nil(err)
    assert.is_not_nil(clean)
  end)
end)

describe("protocol", function()
  it("her ERR için HTTP_STATUS ve DEFAULT_MESSAGES var", function()
    for k in pairs(protocol.ERR) do
      assert.is_not_nil(protocol.HTTP_STATUS[k], "missing HTTP_STATUS " .. k)
      assert.is_not_nil(protocol.DEFAULT_MESSAGES[k], "missing MESSAGE " .. k)
    end
  end)
  it("fazla anahtar yok", function()
    for k in pairs(protocol.HTTP_STATUS) do
      assert.is_not_nil(protocol.ERR[k], "extra HTTP_STATUS " .. k)
    end
    for k in pairs(protocol.DEFAULT_MESSAGES) do
      assert.is_not_nil(protocol.ERR[k], "extra MESSAGE " .. k)
    end
  end)
  it("CODE_LIST 21 ve tekrarsız", function()
    assert.equal(21, #protocol.CODE_LIST)
    local seen = {}
    for _, c in ipairs(protocol.CODE_LIST) do
      assert.is_nil(seen[c], "duplicate " .. c)
      seen[c] = true
      assert.is_not_nil(protocol.ERR[c])
    end
  end)
  it("bilinmeyen kod 500", function()
    assert.equal(500, protocol.http_status("XYZ"))
  end)
  it("is_refreshable", function()
    assert.is_true(protocol.is_refreshable("TOKEN_EXPIRED"))
    assert.is_false(protocol.is_refreshable("UNAUTHORIZED"))
  end)
  it("error_body şekli", function()
    local err = protocol.new_error("TODO_NOT_FOUND", nil, { id = "123" })
    local body = protocol.error_body(err, "req-123")
    assert.equal("TODO_NOT_FOUND", body.error.code)
    assert.equal("req-123", body.error.req_id)
  end)
end)

describe("validation.string", function()
  it("UTF-8 uzunluk", function()
    local sch = v.schema({ title = v.string({ min = 1, max = 3 }) })
    local c = v.validate(sch, { title = "ğüş" })
    assert.is_not_nil(c)
    local c2 = v.validate(sch, { title = "ğüşç" })
    assert.is_nil(c2)
  end)
  it("trim", function()
    local sch = v.schema({ title = v.string({ min = 1, max = 10, trim = true }) })
    local c = v.validate(sch, { title = "  x  " })
    assert.equal("x", c.title)
  end)
end)

describe("validation.enum", function()
  it("geçerli/geçersiz", function()
    local sch = v.schema({ p = v.enum({ "a", "b" }) })
    assert.is_not_nil(v.validate(sch, { p = "a" }))
    local _, e = v.validate(sch, { p = "c" })
    assert.is_not_nil(e.p)
    assert.truthy(e.p[1]:find("izinli"))
  end)
end)

describe("validation.email", function()
  it("normalize ve geçersiz", function()
    local sch = v.schema({ email = v.email() })
    local c = v.validate(sch, { email = "  Test@Example.COM " })
    assert.equal("test@example.com", c.email)
    local _, e = v.validate(sch, { email = "a@" })
    assert.is_not_nil(e)
  end)
end)

describe("validation.uuid", function()
  it("geçerli", function()
    assert.is_true(v.is_uuid("550e8400-e29b-41d4-a716-446655440000"))
  end)
  it("geçersiz", function()
    assert.is_false(v.is_uuid("not-uuid"))
  end)
end)

describe("validation.datetime", function()
  it("geçerli", function()
    local sch = v.schema({ d = v.datetime() })
    assert.is_not_nil(v.validate(sch, { d = "2026-09-18T10:00:00Z" }))
    assert.is_not_nil(v.validate(sch, { d = "2026-09-18T10:00:00+03:00" }))
  end)
  it("geçersiz ay", function()
    local sch = v.schema({ d = v.datetime() })
    local _, e = v.validate(sch, { d = "2026-13-01T10:00:00Z" })
    assert.is_not_nil(e.d)
  end)
end)

describe("validation.password", function()
  it("geçerli Admin123!", function()
    local sch = v.schema({ p = v.password() })
    assert.is_not_nil(v.validate(sch, { p = "Admin123!" }))
  end)
  it("büyük harf yok red", function()
    local sch = v.schema({ p = v.password() })
    local _, e = v.validate(sch, { p = "admin123!" })
    assert.is_not_nil(e.p)
  end)
end)

describe("validation.array_of", function()
  it("max ve unique", function()
    local sch = v.schema({ tags = v.array_of(v.string({ min = 1, max = 50 }), { max = 2 }) })
    local _, e = v.validate(sch, { tags = { "a", "b", "c" } })
    assert.is_not_nil(e.tags)
  end)
  it("eleman hatası", function()
    local sch = v.schema({ tags = v.array_of(v.string({ min = 1, max = 3 }), {}) })
    local _, e = v.validate(sch, { tags = { "ok", "toolong" } })
    assert.truthy(e.tags[1]:find("%[2%]"))
  end)
end)

describe("validation.optional/nullable", function()
  it("opsiyonel alan yok sayılır", function()
    local sch = v.schema({ a = v.optional(v.string({ min = 1 })) })
    local c = v.validate(sch, {})
    assert.is_not_nil(c)
  end)
  it("nullable NULL kabul", function()
    local sch = v.schema({ a = v.nullable(v.string({ min = 1 })) })
    local c = v.validate(sch, { a = v.NULL })
    assert.equal(v.NULL, c.a)
  end)
  it("nullable olmayan NULL hata", function()
    local sch = v.schema({ a = v.string({ min = 1 }) })
    local _, e = v.validate(sch, { a = v.NULL })
    assert.is_not_nil(e.a)
  end)
end)

describe("validation.schema strict", function()
  it("bilinmeyen alan", function()
    local sch = v.schema({ a = v.string({}) })
    local _, e = v.validate(sch, { a = "x", b = "y" })
    assert.is_not_nil(e.b)
  end)
end)

describe("validation.validate_partial", function()
  it("boş gövde hata", function()
    local sch = v.schema({ a = v.string({}) })
    local _, e = v.validate_partial(sch, {})
    assert.is_not_nil(e._)
  end)
  it("tek alan geçerli", function()
    local sch = v.schema({ a = v.string({}), b = v.string({}) })
    local c = v.validate_partial(sch, { a = "x" })
    assert.equal("x", c.a)
  end)
end)

describe("validation.schemas", function()
  it("todo_create geçer", function()
    local c = v.validate(v.schemas.todo_create, { title = "test" })
    assert.is_not_nil(c)
  end)
  it("user_create role root red", function()
    local _, e = v.validate(v.schemas.user_create, { email = "a@b.com", password = "Admin123!", role = "root" })
    assert.is_not_nil(e.role)
  end)
end)

describe("validation.datetime", function()
  local sch = v.schema({ d = v.datetime() })
  it("geçerli biçimler", function()
    for _, d in ipairs({ "2026-09-18T10:00:00Z", "2026-09-18T10:00:00.123Z", "2026-09-18T10:00:00+03:00",
                         "2024-02-29T00:00:00Z" }) do
      assert.is_not_nil(v.validate(sch, { d = d }), d)
    end
  end)
  it("geçersiz biçimler", function()
    for _, d in ipairs({ "2026-09-18T10:00:00-foo", "2026-09-18T10:00:00Zjunk", "2026-02-31T10:00:00Z",
                         "2025-02-29T00:00:00Z", "2026-09-18T10:00:00", "2026-13-01T00:00:00Z" }) do
      local c = v.validate(sch, { d = d })
      assert.is_nil(c, d)
    end
  end)
end)

describe("validation.schemas geçerli/geçersiz", function()
  local S = v.schemas
  local token = string.rep("a", 64)
  local uuid = "11111111-2222-4333-8444-555555555555"
  local cases = {
    login = { { email = "a@b.com", password = "x" }, { email = "yok" } },
    forgot_password = { { email = "a@b.com" }, { email = "a@" } },
    reset_password = { { token = token, new_password = "Yeni1234!" }, { token = "kisa", new_password = "Yeni1234!" } },
    refresh = { { refresh_token = "abc" }, {} },
    todo_create = { { title = "t", tags = { "a", "b" } }, { title = "t", tags = { "a", "a" } } },
    todo_update = { { title = "t", status = "pending", priority = "low" }, { status = "pending" } },
    todo_patch = { { status = "completed" }, { priority = "urgent" } },
    user_create = { { email = "a@b.com", password = "Admin123!", role = "todouser" },
                    { email = "a@b.com", password = "Admin123!" } },
    user_update = { { full_name = "x" }, { role = "root" } },
    rbac_cell = { { can_access = true }, { can_access = "evet" } },
    rbac_matrix = { { permissions = { { role = "admin", page_key = "dashboard", can_access = true } } },
                    { permissions = {} } },
    todo_list_query = { { status = "pending", page = "2" }, { per_page = "500" } },
    user_list_query = { { is_active = "true" }, { is_active = "evet" } },
    audit_query = { { user_id = uuid }, { user_id = "x" } },
  }
  for name, pair in pairs(cases) do
    it(name, function()
      assert.is_not_nil(S[name], "şema yok: " .. name)
      local c, e = v.validate(S[name], pair[1])
      assert.is_not_nil(c, name .. " geçerli örnek reddedildi: " .. tostring(e and next(e)))
      local c2 = v.validate(S[name], pair[2])
      assert.is_nil(c2, name .. " geçersiz örnek kabul edildi")
    end)
  end
end)

describe("saflık", function()
  it("global sızıntı yok", function()
    local before = {}
    for k in pairs(_G) do before[k] = true end
    require("todo_shared.types")
    require("todo_shared.protocol")
    for k in pairs(_G) do
      if not before[k] then
        assert.is_nil(_G[k], "global sızdı: " .. k)
      end
    end
  end)
end)

describe("5.1 uyumluluk", function()
  it("yasak yapılar yok", function()
    local function check_file(path)
      local f = io.open(path, "r")
      if not f then return end
      local content = f:read("*a")
      f:close()
      -- yorum satırları hariç değil ama basit kontrol
      assert.is_nil(content:match("//"), path .. " // içerir")
      assert.is_nil(content:match("utf8%."), path .. " utf8. içerir")
      assert.is_nil(content:match("math%.type"), path .. " math.type içerir")
    end
    check_file("shared/src/types.lua")
    check_file("shared/src/protocol.lua")
    check_file("shared/src/validation.lua")
  end)
end)
