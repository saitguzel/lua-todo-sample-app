-- F17: dom.lua testleri — sahte DOM üzerinde diff/patch, keyed liste, XSS koruması, handle/listener temizliği.
local fake = require("helper")
local dom = require("dom")

local function root()
  fake.reset()
  return fake.dom.byId("app")
end

describe("dom.h", function()
  it("metin çocukları vnode'a çevirir", function()
    local v = dom.h("p", { class = "x" }, "merhaba")
    assert.equal("p", v.tag)
    assert.equal(1, #v.children)
    assert.equal("merhaba", v.children[1].text)
  end)

  it("çocuklar değişken sayıda argüman olarak verilir", function()
    local v = dom.div({}, dom.span({}, "a"), "b", dom.span({}, "c"))
    assert.equal(3, #v.children)
  end)

  it("nil/false çocukları atlar (delikli dizi dahil)", function()
    assert.equal(2, #dom.h("div", {}, { "a", nil, "b" }).children)
    assert.equal(2, #dom.div({}, "a", nil, false, "b").children)
  end)

  it("iç içe listeleri ve düz dizileri düzleştirir", function()
    local v = dom.h("ul", {}, { dom.list({ dom.h("li", {}, "1"), dom.h("li", {}, "2") }), dom.h("li", {}, "3") })
    assert.equal(3, #v.children)
    local tags = { dom.span({}, "x"), dom.span({}, "y") }
    assert.equal(3, #dom.div({}, "etiket:", tags).children) -- "table: 0x..." yazılmaz
  end)

  it("eksik etiket kısayolları tanımlı", function()
    for _, t in ipairs({ "caption", "dl", "dt", "dd", "kbd", "details", "summary", "dialog" }) do
      assert.is_function(dom[t], t)
    end
  end)
end)

describe("dom.patch", function()
  it("mount ağacı kurar", function()
    local r = root()
    local tree = dom.mount(r, dom.h("div", { id = "a" }, "metin"))
    assert.is_truthy(tree._h)
    assert.equal("a", fake.node(tree._h).attrs.id)
  end)

  it("aynı tag'de düğüm yeniden yaratılmaz (odak/imleç korunur)", function()
    local r = root()
    local t1 = dom.mount(r, dom.h("input", { value = "eski" }))
    local created_before = fake.dom_stats.created
    local result = dom.patch(r, t1, dom.h("input", { value = "yeni" }))
    assert.equal(created_before, fake.dom_stats.created)
    assert.equal(t1._h, result._h)
    assert.equal("yeni", fake.node(result._h).props.value)
  end)

  it("tag değişirse aynı konumda değiştirilir", function()
    local r = root()
    local t1 = dom.mount(r, dom.div({}, dom.span({}, "1"), dom.span({}, "2"), dom.span({}, "3")))
    local t2 = dom.patch(r, t1, dom.div({}, dom.span({}, "1"), dom.p({}, "2"), dom.span({}, "3")))
    local kids = fake.node(t2._h).children
    assert.equal(3, #kids)
    assert.equal("p", kids[2].kind) -- sona eklenmedi, yerinde
  end)

  it("kaldırılan alt ağaç release edilir (handle sızıntısı yok)", function()
    local r = root()
    local t1 = dom.mount(r, dom.h("ul", {}, dom.h("li", {}, "1"), dom.h("li", {}, "2")))
    local released_before = fake.dom_stats.released
    dom.patch(r, t1, dom.h("ul", {}))
    assert.is_true(fake.dom_stats.released >= released_before + 2)
  end)

  it("metin değişimi setText ile olur", function()
    local r = root()
    local t1 = dom.mount(r, dom.h("p", {}, "eski"))
    local t2 = dom.patch(r, t1, dom.h("p", {}, "yeni"))
    assert.equal("yeni", fake.node(t2._h).children[1].text)
  end)

  it("kaldırılan prop'lar property olarak da sıfırlanır (checkbox)", function()
    local r = root()
    local t1 = dom.mount(r, dom.input({ type = "checkbox", checked = "checked" }))
    local t2 = dom.patch(r, t1, dom.input({ type = "checkbox" }))
    assert.is_false(fake.node(t2._h).props.checked)
  end)
end)

describe("keyed diff", function()
  local function list(keys)
    local items = {}
    for i, k in ipairs(keys) do items[i] = dom.li({ key = k }, k) end
    return dom.ul({}, items)
  end

  it("yeniden sıralamada düğümler yeniden yaratılmaz", function()
    local r = root()
    local t1 = dom.mount(r, list({ "a", "b", "c" }))
    local created = fake.dom_stats.created
    local t2 = dom.patch(r, t1, list({ "c", "a", "b" }))
    assert.equal(created, fake.dom_stats.created)
    local kids = fake.node(t2._h).children
    assert.equal("c", kids[1].children[1].text)
    assert.equal("a", kids[2].children[1].text)
  end)

  it("ortadaki öğe silinince yalnızca o kaldırılır", function()
    local r = root()
    local t1 = dom.mount(r, list({ "a", "b", "c" }))
    local a_h, c_h = t1.children[1]._h, t1.children[3]._h
    local t2 = dom.patch(r, t1, list({ "a", "c" }))
    assert.equal(a_h, t2.children[1]._h)
    assert.equal(c_h, t2.children[2]._h)
    assert.equal(2, #fake.node(t2._h).children)
  end)
end)

describe("event handler'ları", function()
  it("render'da handler değişse de JS'e ikinci listener bağlanmaz, güncel handler çağrılır", function()
    local r = root()
    local hit = nil
    local t1 = dom.mount(r, dom.button({ onclick = function() hit = 1 end }, "x"))
    local l1 = fake.dom_stats.listeners
    local t2 = dom.patch(r, t1, dom.button({ onclick = function() hit = 2 end }, "x"))
    assert.equal(l1, fake.dom_stats.listeners)
    fake.fire(t2._h, "click")
    assert.equal(2, hit)
  end)

  it("handler değişmeden yeniden render'da listener kopmaz", function()
    local r = root()
    local n = 0
    local fn = function() n = n + 1 end
    local t = dom.mount(r, dom.button({ onclick = fn }, "x"))
    for _ = 1, 3 do t = dom.patch(r, t, dom.button({ onclick = fn }, "x")) end
    fake.fire(t._h, "click")
    assert.equal(1, n)
  end)

  it("alt ağaç kaldırılınca listener'lar temizlenir", function()
    local r = root()
    local t1 = dom.mount(r, dom.div({}, dom.button({ onclick = function() end }, "a")))
    assert.equal(1, fake.dom_stats.listeners)
    dom.patch(r, t1, dom.div({}))
    assert.equal(0, fake.dom_stats.listeners)
  end)
end)

describe("XSS koruması", function()
  it("javascript: href'i DOM'a yazılmaz", function()
    local r = root()
    local t = dom.mount(r, dom.h("a", { href = "javascript:alert(1)" }, "tıkla"))
    assert.is_nil(fake.node(t._h).attrs.href)
  end)

  it("innerHTML yok; HTML metni text node olarak kalır", function()
    local r = root()
    local t = dom.mount(r, dom.h("div", {}, '<img src=x onerror=alert(1)>'))
    local child = fake.node(t._h).children[1]
    assert.equal("#text", child.kind)
    assert.equal('<img src=x onerror=alert(1)>', child.text)
  end)
end)
