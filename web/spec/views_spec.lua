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
    assert.equal(1, by_field.a.old); assert.is_nil(by_field.a.new)   -- silinen
    assert.is_nil(by_field.b.old); assert.equal(2, by_field.b.new)   -- eklenen
    assert.is_true(by_field.a.changed and by_field.b.changed)
  end)

  it("nil girişlerle çalışır", function()
    local rows = audit._diff_fields(nil, { x = 1 })
    assert.equal(1, #rows)
    assert.equal("x", rows[1].field)
  end)
end)

describe("todos filtre ↔ URL query", function()
  local todos = require("views.todos")

  it("gidiş-dönüş eşitliği; varsayılanlar URL'ye yazılmaz", function()
    local q = { status = "pending", priority = "high", q = "fatura öde", tag = "iş", sort = "due_date", page = "3" }
    local f = todos.filters_from_query(q)
    assert.equal(3, f.page)
    assert.same(q, todos.query_from_filters(f))
    assert.same({}, todos.query_from_filters(todos.filters_from_query({})))
  end)
end)

describe("audit tarih aralığı", function()
  local audit = require("views.audit_logs")
  it("bitiş başlangıçtan önce olamaz", function()
    assert.is_true(audit.valid_range("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"))
    assert.is_false(audit.valid_range("2026-01-02T00:00:00Z", "2026-01-01T00:00:00Z"))
    assert.is_true(audit.valid_range(nil, "2026-01-01T00:00:00Z"))
  end)
end)

describe("login demo kutusu", function()
  it("build_info yokken (test/prod) gösterilmez", function()
    assert.is_false(require("views.login").show_demo)
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
    fake.storage.set("todo.auth", "{bozuk")
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
