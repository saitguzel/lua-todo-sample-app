-- F17: dom.lua testleri — sahte DOM üzerinde diff/patch, XSS koruması, handle serbest bırakma.
local fake = require("helper")
local dom = require("dom")

describe("dom.h", function()
  it("metin çocukları vnode'a çevirir", function()
    local v = dom.h("p", { class = "x" }, "merhaba")
    assert.equal("p", v.tag)
    assert.equal(1, #v.children)
    assert.equal("merhaba", v.children[1].text)
  end)

  it("nil çocukları atlar", function()
    local v = dom.h("div", {}, { "a", nil, "b" })
    assert.equal(2, #v.children)
  end)

  it("iç içe listeleri düzleştirir", function()
    local v = dom.h("ul", {}, { dom.list({ dom.h("li", {}, "1"), dom.h("li", {}, "2") }), dom.h("li", {}, "3") })
    assert.equal(3, #v.children)
  end)
end)

describe("dom.patch", function()
  before_each(function() fake.reset() end)

  it("mount ağacı kurar", function()
    local root = fake.dom.byId("app")
    local tree = dom.mount(root, dom.h("div", { id = "a" }, "metin"))
    assert.is_truthy(tree._h)
  end)

  it("aynı tag'de düğüm yeniden yaratılmaz (odak/imleç korunur)", function()
    local root = fake.dom.byId("app")
    local t1 = dom.mount(root, dom.h("input", { value = "eski" }, nil))
    local created_before = fake.dom_stats.created
    local t2 = dom.h("input", { value = "yeni" }, nil)
    local result = dom.patch(root, t1, t2)
    assert.equal(created_before, fake.dom_stats.created) -- yeni create yok
    assert.equal(t1._h, result._h) -- aynı handle
  end)

  it("tag değişirse replace olur", function()
    local root = fake.dom.byId("app")
    local t1 = dom.mount(root, dom.h("span", {}, "x"))
    local created_before = fake.dom_stats.created
    dom.patch(root, t1, dom.h("div", {}, "x"))
    assert.equal(created_before + 1, fake.dom_stats.created)
  end)

  it("kaldırılan alt ağaç release edilir (handle sızıntısı yok)", function()
    local root = fake.dom.byId("app")
    local t1 = dom.mount(root,
      dom.h("ul", {}, dom.list({ dom.h("li", {}, "1"), dom.h("li", {}, "2") })))
    local released_before = fake.dom_stats.released
    dom.patch(root, t1, dom.h("ul", {}, nil)) -- tüm çocuklar gitti
    assert.equal(released_before + 2, fake.dom_stats.released) -- 2 li release
  end)

  it("metin değişimi setText ile olur", function()
    local root = fake.dom.byId("app")
    local t1 = dom.mount(root, dom.h("p", {}, "eski"))
    local t2 = dom.patch(root, t1, dom.h("p", {}, "yeni"))
    local node = fake.node(t2._h)
    assert.equal("yeni", node.text)
  end)
end)

describe("XSS koruması", function()
  it("javascript: href'i DOM'a yazılmaz", function()
    fake.reset()
    local root = fake.dom.byId("app")
    local t = dom.mount(root, dom.h("a", { href = "javascript:alert(1)" }, "tıkla"))
    local node = fake.node(t._h)
    assert.is_nil(node.attrs.href)
  end)

  it("innerHTML prop'u yok; metin text node olarak kalır", function()
    fake.reset()
    local root = fake.dom.byId("app")
    local t = dom.mount(root, dom.h("div", {}, '<img src=x onerror=alert(1)>'))
    local node = fake.node(t._h)
    assert.equal('<img src=x onerror=alert(1)>', node.children[1].text) -- string olarak kalır, element olmaz
  end)
end)
