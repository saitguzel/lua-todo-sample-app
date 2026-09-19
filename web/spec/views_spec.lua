-- F17: Saf view yardımcıları — audit diff_fields, storage sarmalayıcısı, json encoder.
local fake = require("helper")

describe("audit diff_fields", function()
  local audit = require("views.audit_logs")

  it("değişen alan changed=true", function()
    local rows = audit._diff_fields({ title = "eski", status = "pending" }, { title = "yeni", status = "pending" })
    local by_field = {}
    for _, r in ipairs(rows) do by_field[r.field] = r end
    assert.is_true(by_field.title.changed)
    assert.is_false(by_field.status.changed)
  end)

  it("eklenen/silinen alan tespit edilir", function()
    local rows = audit._diff_fields({ a = 1 }, { b = 2 })
    local by_field = {}
    for _, r in ipairs(rows) do by_field[r.field] = r end
    assert.is_nil(by_field.a.old); assert.equal(1, by_field.a.new)
    assert.equal(1, by_field.b.old); assert.is_nil(by_field.b.new)
  end)

  it("nil girişlerle çalışır", function()
    local rows = audit._diff_fields(nil, { x = 1 })
    assert.equal(1, #rows)
    assert.equal("x", rows[1].field)
  end)
end)

describe("json.lua", function()
  local json = require("json")

  it("temel tipler", function()
    assert.equal("42", json.encode(42))
    assert.equal('"metin"', json.encode("metin"))
    assert.equal("true", json.encode(true))
    assert.equal("null", json.encode(nil))
    assert.equal("null", json.encode(json.null))
  end)

  it("dizi ve nesne ayrımı", function()
    assert.equal("[1,2,3]", json.encode({ 1, 2, 3 }))
    assert.equal('{"a":1}', json.encode({ a = 1 }))
  end)

  it("string kaçışı", function()
    assert.equal('"a\\"b"', json.encode('a"b'))
    assert.equal('"ç\\u0007"', json.encode("ç\a"))
    -- UTF-8 aynen geçer
    assert.equal('"çöğü"', json.encode("çöğü"))
  end)

  it("iç içe yapı", function()
    local v = { items = { { id = 1, tags = { "a", "b" } } }, total = 1 }
    assert.equal('{"items":[{"id":1,"tags":["a","b"]}],"total":1}', json.encode(v))
  end)
end)

describe("storage.lua", function()
  local storage = require("storage")

  before_each(function() fake.reset() end)

  it("JSON olarak saklar ve geri okur", function()
    storage.set("todos.filters", { status = "pending", page = 2 })
    local v = storage.get("todos.filters")
    assert.equal("pending", v.status)
    assert.equal(2, v.page)
  end)

  it("bozuk JSON'da default döner", function()
    fake.storage_set("todo.auth", "{bozuk")
    assert.equals(nil, storage.get("auth"))
    assert.equal("fallback", storage.get("auth", "fallback"))
  end)

  it("raw erişim JSON sarmasını kaldırır", function()
    storage.set_raw("theme", "dark")
    assert.equal("dark", storage.get_raw("theme"))
  end)

  it("remove anahtarı siler", function()
    storage.set("auth", { a = 1 })
    storage.remove("auth")
    assert.is_nil(storage.get("auth"))
  end)
end)
