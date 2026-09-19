-- F17: shortcuts testleri — editable hedef koruması (WCAG 2.1.4), scope temizliği.
local fake = require("helper")
local shortcuts = require("shortcuts")

describe("shortcuts", function()
  before_each(function()
    fake.reset()
    shortcuts.unregister_scope("todos")
    shortcuts.unregister_scope("global")
  end)

  it("kayıtlı kısayol tetiklenir", function()
    local called = false
    shortcuts.register("todos", "n", function() called = true end, "Yeni todo")
    shortcuts.handle_key("n", false, false, false)
    assert.is_true(called)
  end)

  it("editable hedefte tek harfliler tetiklenmez", function()
    local called = false
    shortcuts.register("todos", "n", function() called = true end, "Yeni todo")
    shortcuts.handle_key("n", true, false, false) -- typing = true
    assert.is_false(called)
  end)

  it("Ctrl/Alt ile tetiklenmez", function()
    local called = false
    shortcuts.register("todos", "n", function() called = true end, "Yeni todo")
    shortcuts.handle_key("n", false, true, false) -- ctrl
    assert.is_false(called)
    shortcuts.handle_key("n", false, false, true) -- alt
    assert.is_false(called)
  end)

  it("tanımsız scope'ta tetiklenmez", function()
    local called = false
    shortcuts.register("todos", "n", function() called = true end, "")
    shortcuts.handle_key("x", false, false, false)
    assert.is_false(called)
  end)

  it("unregister_scope temizler", function()
    local called = false
    shortcuts.register("todos", "n", function() called = true end, "")
    shortcuts.unregister_scope("todos")
    shortcuts.handle_key("n", false, false, false)
    assert.is_false(called)
  end)

  it("list kayıtları döner", function()
    shortcuts.register("todos", "n", function() end, "Yeni todo")
    shortcuts.register("global", "?", function() end, "Yardım")
    local list = shortcuts.list()
    assert.equal(2, #list)
  end)
end)
