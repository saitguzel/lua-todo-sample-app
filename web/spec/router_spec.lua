-- F17: router birim testleri — hash parse, guard, open redirect koruması.
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
    assert.matches("next=%23%2Ftodos", redirect) -- "#/todos" URL-encoded
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
