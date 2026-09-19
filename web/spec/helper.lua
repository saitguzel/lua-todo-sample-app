-- F17: Test yardımcısı — glue.js köprüsünün bellek içi sahtesi.
-- Frontend modülleri yalnızca js tablosuna dokunur; bu dosya onu mock'lar.

local fake = { storage_store = {}, calls = {}, fetch_queue = {}, now = 0 }

-- --- storage mock ---------------------------------------------------------
fake.storage = setmetatable({}, {
  __index = function(_, k) return fake.storage_store[k] end,
  __newindex = function(_, k, v) fake.storage_store[k] = v end,
})

fake.storage_get = function(k) return fake.storage_store[k] end
fake.storage_set = function(k, v) fake.storage_store[k] = v; return true end
fake.storage_remove = function(k) fake.storage_store[k] = nil end

-- --- http mock: kuyruktaki yanıtı callback ile verir -------------------------
fake.fetch = function(method, url, headers_json, body, cb)
  fake.calls[#fake.calls + 1] = { method = method, url = url, headers = headers_json, body = body }
  local res = table.remove(fake.fetch_queue, 1) or { status = 599, body = "{}" }
  cb(res.net_err, res.status, res.body or res.text or "", res.ctype or "application/json")
end

-- --- sahte DOM: basit Lua ağacı; create çağrıları sayılır (keyed diff testi) ---
fake.dom = {}
fake.dom_stats = { created = 0, released = 0 }
local node_seq = 0

local function make_node(kind)
  node_seq = node_seq + 1
  fake.dom_stats.created = fake.dom_stats.created + 1
  return { id = node_seq, kind = kind, attrs = {}, props = {}, text = "", children = {}, listeners = {} }
end

fake.dom.create = function(tag) return make_node(tag) end
fake.dom.text = function(s)
  local n = make_node("#text")
  n.text = s
  return n.id
end
fake.dom.byId = function(id) return make_node("div#" .. id) end
fake.dom.setAttr = function(h, k, v)
  local n = fake.node(h)
  if n then n.attrs[k] = v end
end
fake.dom.removeAttr = function(h, k)
  local n = fake.node(h)
  if n then n.attrs[k] = nil end
end
fake.dom.setProp = function(h, k, v)
  local n = fake.node(h)
  if n then n.props[k] = v end
end
fake.dom.getProp = function(h, k)
  local n = fake.node(h)
  return n and n.props[k] or nil
end
fake.dom.setText = function(h, s)
  local n = fake.node(h)
  if n then n.text = s end
end
fake.dom.append = function(p, c)
  local pn, cn = fake.node(p), fake.node(c)
  if pn and cn then pn.children[#pn.children + 1] = cn end
end
fake.dom.replaceChildren = function(p, ...) end
fake.dom.remove = function(h) fake.node(h) end
fake.dom.release = function(h) fake.dom_stats.released = fake.dom_stats.released + 1 end
fake.dom.focus = function(h) end
fake.dom.on = function(h, ev, fn)
  local n = fake.node(h)
  if n then n.listeners[ev] = fn end
  return function() end
end
fake.dom.setClass = function(h, cls, on) end
fake.dom.setRootAttr = function(k, v) fake.root_attrs[k] = v end
fake.dom.title = function(s) fake.title = s end
fake.dom.activeElement = function() return make_node("button") end
fake.dom.showModal = function(h) end
fake.dom.closeModal = function(h) end

-- handle (sayı) → node eşlemesi
local nodes_by_id = {}
fake.node = function(h)
  if type(h) == "number" then
    if not nodes_by_id[h] then nodes_by_id[h] = { id = h, attrs = {}, props = {}, text = "", children = {}, listeners = {} } end
    return nodes_by_id[h]
  end
  return nil
end
fake.root_attrs = {}

-- --- diğer köprüler ------------------------------------------------------------
fake.timer = {
  after = function(ms, fn) fn() end, -- senkron
  cancel = function() end,
  raf = function(fn) fn() end,       -- senkron
}
fake.location = {
  hash = function() return fake._hash or "#/" end,
  setHash = function(h) fake._hash = h end,
  replace = function(h) fake._hash = h end,
  onHashChange = function() end,
}
fake.keyboard = { onKey = function() end }
fake.media = {
  prefersDark = function() return false end,
  reducedMotion = function() return false end,
  matches = function() return false end,
  onChange = function() end,
}
fake.format_date = function(iso) return iso end
fake.to_iso_utc = function(v) return v end
fake.random_password = function(len) return string.rep("x", len or 16) end
fake.clipboard = function() end
fake.confetti = function() fake.calls[#fake.calls + 1] = { confetti = true } end
fake.json = { encode = function(v) return require("cjson").encode(v) end, decode = function(s) return require("cjson").decode(s) end }
fake.log = function() end
fake.config = function() return '{}' end

-- --- js modülünü yükle ------------------------------------------------------------
package.loaded["js"] = fake
_G.js = fake
_G.test_js = fake

-- spec'lerin kuyruk doldurması için yardımcılar
function fake.queue_response(status, body, opts)
  fake.fetch_queue[#fake.fetch_queue + 1] = {
    status = status, body = body or "", ctype = opts and opts.ctype,
    net_err = opts and opts.net_err,
  }
end

function fake.reset()
  fake.storage_store = {}
  fake.calls = {}
  fake.fetch_queue = {}
  fake.dom_stats = { created = 0, released = 0 }
  fake._hash = "#/"
end

return fake
