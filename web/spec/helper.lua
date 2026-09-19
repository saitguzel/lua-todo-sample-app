-- luacheck: std lua54+busted
-- F17: Test yardımcısı — glue.js köprüsünün (bridge) bellek içi sahtesi.
-- Frontend modülleri yalnızca global js tablosuna dokunur; bu dosya onu glue.js ile aynı API'de mock'lar.
-- Handle'lar glue.js'teki gibi sayıdır; fake.node(h) ile sahte düğüme erişilir.

-- shared modüller bundle'da "todo_shared.<ad>" olarak yer alır; testte ../shared/src'ye eşlenir
table.insert(package.searchers, 2, function(name)
  local short = name:match("^todo_shared%.(.+)$")
  if not short then return nil end
  local path = "../shared/src/" .. short:gsub("%.", "/") .. ".lua"
  local chunk, err = loadfile(path)
  if not chunk then return "\n\t" .. tostring(err) end
  return chunk, path
end)

local fake = {}

-- --- sahte DOM: handle (sayı) → düğüm tablosu ------------------------------------
local nodes, seq = {}, 0

local function make_node(kind)
  seq = seq + 1
  fake.dom_stats.created = fake.dom_stats.created + 1
  nodes[seq] = { id = seq, kind = kind, attrs = {}, props = {}, text = "", children = {}, listeners = {} }
  return seq
end

local function detach(n)
  local p = n.parent
  if not p then return end
  for i, c in ipairs(p.children) do
    if c == n then table.remove(p.children, i) break end
  end
  n.parent = nil
end

function fake.node(h) return nodes[h] end

fake.dom = {
  create = function(tag) return make_node(tag) end,
  text = function(s)
    local h = make_node("#text")
    nodes[h].text = s
    return h
  end,
  byId = function(id)
    fake.by_id[id] = fake.by_id[id] or make_node("div#" .. id)
    return fake.by_id[id]
  end,
  setAttr = function(h, k, v) local n = nodes[h]; if n then n.attrs[k] = v end end,
  removeAttr = function(h, k) local n = nodes[h]; if n then n.attrs[k] = nil end end,
  setProp = function(h, k, v) local n = nodes[h]; if n then n.props[k] = v end end,
  getProp = function(h, k) local n = nodes[h]; return n and n.props[k] or nil end,
  setText = function(h, s) local n = nodes[h]; if n then n.text = s end end,
  append = function(p, c)
    local pn, cn = nodes[p], nodes[c]
    if not (pn and cn) then return end
    detach(cn)
    pn.children[#pn.children + 1] = cn
    cn.parent = pn
  end,
  insertAt = function(p, c, i)
    local pn, cn = nodes[p], nodes[c]
    if not (pn and cn) or pn.children[i + 1] == cn then return end
    fake.dom_stats.moved = fake.dom_stats.moved + 1
    detach(cn)
    table.insert(pn.children, math.min(i + 1, #pn.children + 1), cn)
    cn.parent = pn
  end,
  replaceWith = function(o, n)
    local on, nn = nodes[o], nodes[n]
    if not (on and nn and on.parent) then return end
    local p = on.parent
    for i, c in ipairs(p.children) do
      if c == on then p.children[i] = nn break end
    end
    nn.parent, on.parent = p, nil
  end,
  remove = function(h)
    local n = nodes[h]
    if n then detach(n) end
    nodes[h] = nil
  end,
  release = function(h)
    fake.dom_stats.released = fake.dom_stats.released + 1
    nodes[h] = nil
  end,
  focus = function(h) fake.focused = h end,
  on = function(h, ev, fn)
    local n = nodes[h]
    if n then n.listeners[ev] = fn end
    fake.dom_stats.listeners = fake.dom_stats.listeners + 1
    return function()
      fake.dom_stats.listeners = fake.dom_stats.listeners - 1
      if n and n.listeners[ev] == fn then n.listeners[ev] = nil end
    end
  end,
  setClass = function() end,
  setRootAttr = function(k, v) fake.root_attrs[k] = v end,
  title = function(s) fake.title = s end,
  activeElement = function() return nil end,
  activeDataId = function() return fake.active_data_id end,
  openModals = function() end,
  modalOpen = function() return fake.modal_open == true end,
  focusFirst = function(sel) fake.focused_selector = sel end,
  _size = function()
    local n = 0
    for _ in pairs(nodes) do n = n + 1 end
    return n
  end,
}

-- Sahte düğümdeki olayı tetikler (testlerde tıklama/değişim)
function fake.fire(h, ev, e)
  local n = nodes[h]
  local fn = n and n.listeners[ev]
  if fn then return fn(e or { type = ev }) end
end

-- --- storage ----------------------------------------------------------------------
fake.storage = {
  get = function(k) return fake.storage_store[k] end,
  set = function(k, v) fake.storage_store[k] = v; return true end,
  remove = function(k) fake.storage_store[k] = nil end,
}

-- --- http: kuyruktaki yanıtı callback ile (senkron) verir ---------------------------
fake.http = {
  request = function(method, url, headers_json, body, cb)
    fake.calls[#fake.calls + 1] = { method = method, url = url, headers = headers_json, body = body }
    local res = table.remove(fake.fetch_queue, 1) or { status = 599, body = "{}" }
    local function respond()
      cb(res.net_err, res.status, res.body or "", res.ctype or "application/json", res.retry_after or "")
    end
    -- async modu: yanıt fake.flush() ile verilir (eşzamanlı istek senaryoları)
    if fake.async then fake.pending[#fake.pending + 1] = respond else respond() end
  end,
  download = function(url, token, filename, cb)
    fake.calls[#fake.calls + 1] = { method = "DOWNLOAD", url = url, token = token, filename = filename }
    if cb then cb(fake.download_error) end
  end,
}

-- --- diğer köprüler ------------------------------------------------------------------
fake.timer = {
  after = function(_, fn) fn(); return 0 end, -- senkron
  cancel = function() end,
  raf = function(fn) fn() end,             -- senkron
  now = function() return 0 end,
}
fake.location = {
  hash = function() return fake._hash or "#/" end,
  -- tarayıcıdaki gibi hash değişimi hashchange olayını tetikler (burada senkron)
  setHash = function(h)
    local changed = fake._hash ~= h
    fake._hash = h
    if changed and fake.hash_cb then fake.hash_cb(h) end
  end,
  replace = function(h) fake._hash = h end,
  onHashChange = function(fn) fake.hash_cb = fn end,
}
fake.keyboard = { onKey = function() end }
fake.media = {
  prefersDark = function() return fake.prefers_dark == true end,
  reducedMotion = function() return false end,
  matches = function() return false end,
  onChange = function() end,
}
fake.loadBundle = function(name, cb) fake.loaded_bundles[#fake.loaded_bundles + 1] = name; cb(nil) end
fake.format_date = function(iso) return iso end
fake.to_iso_utc = function(v) return v and (v .. ":00Z") or nil end
fake.to_local_input = function(iso) return iso and iso:sub(1, 16) or "" end
fake.random_password = function(len) return string.rep("x", len or 16) end
fake.clipboard = function() end
fake.confetti = function() fake.calls[#fake.calls + 1] = { confetti = true } end
fake.log = function(level, msg)
  if level == "error" then fake.errors[#fake.errors + 1] = msg end
end
fake.config = function() return "{}" end

-- --- JSON: glue.js JSON.parse'ın saf Lua karşılığı (null → nil, reviver ile aynı) ------
local function decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local value
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("JSON: bitmemiş string") end
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if e == "u" then
          out[#out + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16))
          pos = pos + 6
        else
          out[#out + 1] = map[e] or e
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  value = function()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
      while true do
        ws(); local k = str(); ws()
        assert(s:sub(pos, pos) == ":", "JSON: ':' bekleniyordu"); pos = pos + 1
        t[k] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return t end
        assert(d == ",", "JSON: ',' bekleniyordu")
      end
    elseif c == "[" then
      local t, i = {}, 0
      pos = pos + 1; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
      while true do
        i = i + 1
        t[i] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return t end
        assert(d == ",", "JSON: ',' bekleniyordu")
      end
    elseif c == '"' then
      return str()
    elseif s:find("^true", pos) then pos = pos + 4 return true
    elseif s:find("^false", pos) then pos = pos + 5 return false
    elseif s:find("^null", pos) then pos = pos + 4 return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then error("JSON: geçersiz değer @" .. pos) end
      pos = pos + #num
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end
  local v = value()
  ws()
  if pos <= #s then error("JSON: fazladan karakter @" .. pos) end
  return v
end
fake.json = { decode = decode, encode = function(v) return require("json").encode(v) end }

-- Bekleyen async yanıtları sırayla verir (yanıtlar yeni istek doğurursa onları da)
function fake.flush()
  while #fake.pending > 0 do table.remove(fake.pending, 1)() end
end

-- spec'lerin kuyruk doldurması için yardımcı
function fake.queue_response(status, body, opts)
  fake.fetch_queue[#fake.fetch_queue + 1] = {
    status = status, body = body or "", ctype = opts and opts.ctype,
    net_err = opts and opts.net_err, retry_after = opts and opts.retry_after,
  }
end

function fake.reset()
  fake.storage_store = {}
  fake.calls = {}
  fake.fetch_queue = {}
  fake.pending = {}
  fake.async = false
  fake.by_id = {}
  fake.loaded_bundles = {}
  fake.dom_stats = { created = 0, released = 0, moved = 0, listeners = 0 }
  fake.root_attrs = {}
  fake._hash = "#/"
  fake.active_data_id = nil
  fake.modal_open = false
  fake.download_error = nil
  fake.errors = {}
  fake.hash_cb = nil
  fake.prefers_dark = false
end
fake.reset()

_G.js = fake
package.loaded["helper"] = fake

return fake
