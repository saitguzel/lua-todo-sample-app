-- F17: router birim testleri — hash parse, guard, open redirect koruması, bundle yükleme.
local fake = require("helper")
local router = require("router")

describe("router.parse", function()
  it("path ve query ayırır", function()
    local r = router.parse("#/todos?status=pending&page=2")
    assert.equal("/todos", r.path)
    assert.equal("pending", r.query.status)
    assert.equal("2", r.query.page)
  end)

  it("parametreli route eşler (#/todos/:id)", function()
    local r = router.parse("#/todos/abc-123")
    assert.equal("todo_edit", r.name)
    assert.equal("abc-123", r.params.id)
  end)

  it("URL-encoded query çözer", function()
    local r = router.parse("#/todos?q=fatura%20%C3%B6de")
    assert.equal("fatura öde", r.query.q)
  end)

  it("bilinmeyen route not_found döner", function()
    local r = router.parse("#/nonsense")
    assert.equal("not_found", r.name)
  end)

  it("boş hash kök yolu olur", function()
    local r = router.parse("")
    assert.equal("/", r.path)
    assert.equal("dashboard", r.name)
  end)

  -- tablo bazlı: tüm route'lar eşleşir ("-" içeren yollar dahil — Lua pattern büyü karakteri)
  local cases = {
    { "#/login", "login" }, { "#/forgot-password", "forgot_password" },
    { "#/reset-password?token=abc", "reset_password" }, { "#/", "dashboard" }, { "#/dashboard", "dashboard" },
    { "#/todos", "todos" }, { "#/todos/new", "todos_new" }, { "#/todos/x1", "todo_edit" },
    { "#/users", "users" }, { "#/rbac", "rbac" }, { "#/audit-logs?action=x", "audit" },
    { "#/profile", "profile" }, { "#/todos/a/b", "not_found" }, { "#/audit-logsX", "not_found" },
  }
  for _, c in ipairs(cases) do
    it(c[1] .. " → " .. c[2], function() assert.equal(c[2], router.parse(c[1]).name) end)
  end

  it("encode_query sıralı ve boşları atar", function()
    assert.equal("?a=1&b=iki%20kelime", router.encode_query({ b = "iki kelime", a = 1, c = "" }))
    assert.equal("", router.encode_query({}))
  end)
end)

describe("router.load_bundle", function()
  it("admin view'ları bundle yüklenene kadar çözülmez; yüklenince çözülür", function()
    fake.reset()
    local r = router.parse("#/users")
    assert.is_false(router.bundle_ready(r.route))
    local co = coroutine.create(function() return router.load_bundle("admin") end)
    local ok, res = coroutine.resume(co)
    assert.is_true(ok); assert.is_true(res)
    assert.same({ "admin" }, fake.loaded_bundles)
    assert.is_true(router.bundle_ready(r.route))
  end)
end)

describe("router.guard", function()
  local auth_authenticated = { status = "authenticated", permissions = { ["todos.list"] = true } }
  local auth_anonymous = { status = "anonymous", permissions = {} }
  local auth_unknown = { status = "unknown", permissions = {} }

  it("unknown durumda bekler (nil)", function()
    local route = router.parse("#/todos")
    assert.is_nil(router.guard(route, auth_unknown))
  end)

  it("oturumsuz korumalı sayfa → login + next", function()
    local route = router.parse("#/todos")
    local redirect = router.guard(route, auth_anonymous)
    assert.matches("^#/login%?next=", redirect)
    assert.truthy(redirect:find("next=%23%2Ftodos", 1, true)) -- "#/todos" URL-encoded
  end)

  it("todouser page_key izni yoksa forbidden", function()
    local route = router.parse("#/rbac")
    assert.equal("forbidden", router.guard(route, auth_authenticated))
  end)

  it("izni olan geçer", function()
    local route = router.parse("#/todos")
    assert.is_nil(router.guard(route, auth_authenticated))
  end)

  it("girişliyken login → #/", function()
    local route = router.parse("#/login")
    assert.equal("#/", router.guard(route, auth_authenticated))
  end)

  it("guest-only sayfa anonymous'a açık", function()
    local route = router.parse("#/login")
    assert.is_nil(router.guard(route, auth_anonymous))
  end)
end)

describe("router.safe_next", function()
  it("#/ ile başlayan kabul", function()
    assert.equal("#/todos", router.safe_next("#/todos"))
  end)

  it("harici URL reddedilir", function()
    assert.is_nil(router.safe_next("https://evil.com"))
    assert.is_nil(router.safe_next("//evil.com"))
    assert.is_nil(router.safe_next("#//evil.com"))
    assert.is_nil(router.safe_next("javascript:alert(1)"))
    assert.is_nil(router.safe_next(nil))
  end)
end)

describe("router.can", function()
  it("page_key nil ise her zaman true", function()
    assert.is_true(router.can({ status = "anonymous" }, nil))
  end)

  it("izni olmayan false", function()
    assert.is_false(router.can({ status = "authenticated", permissions = {} }, "users.list"))
  end)

  it("izni olan true", function()
    assert.is_true(router.can({ status = "authenticated", permissions = { ["users.list"] = true } }, "users.list"))
  end)

  it("anonymous false", function()
    assert.is_false(router.can({ status = "anonymous", permissions = { ["users.list"] = true } }, "users.list"))
  end)
end)
