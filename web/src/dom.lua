-- F13: Sanal DOM + keyed diff/patch. Metin her zaman textContent/createTextNode ile
-- (innerHTML yok → XSS tasarımla engelli); handle'lar release edilerek JS haritası büyümez.

local dom = {}

-- property ile set edilmesi gereken attribute'lar (F12 bridge setProp)
local PROP_ATTRS = { value = true, checked = true, disabled = true, selected = true, indeterminate = true }

-- --- vnode üretimi -----------------------------------------------------------

local function is_vnode(c)
  return type(c) == "table" and (c.tag ~= nil or c.text ~= nil)
end

-- Delikli dizileri de (nil içeren) sırayla gezmek için tam sayı anahtarların en büyüğü
local function max_index(t)
  local n = t.n or #t
  for k in pairs(t) do
    if type(k) == "number" and k > n then n = k end
  end
  return n
end

-- çocuk: vnode | string | number | nil/false (atlanır) | düz dizi / dom.list (düzleştirilir)
local function flatten(out, c)
  if c == nil or c == false then return end
  if is_vnode(c) then
    out[#out + 1] = c
  elseif type(c) == "table" then
    for i = 1, max_index(c) do flatten(out, c[i]) end
  else
    out[#out + 1] = { text = tostring(c) }
  end
end

-- Geriye uyumluluk: dom.list{...} artık düz dizi ile aynı davranır
function dom.list(children)
  return children or {}
end

-- dom.h(tag, props, ...çocuklar)
function dom.h(tag, props, ...)
  local children = {}
  local n = select("#", ...)
  for i = 1, n do flatten(children, (select(i, ...))) end
  return { tag = tag, props = props or {}, children = children }
end

-- Yaygın etiket kısayolları
local TAGS = { "div", "span", "p", "a", "button", "input", "select", "option", "textarea", "form",
  "label", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "thead", "tbody", "tfoot", "tr",
  "th", "td", "caption", "nav", "aside", "header", "footer", "main", "section", "article", "img", "br", "hr",
  "small", "strong", "em", "dialog", "pre", "code", "kbd", "dl", "dt", "dd", "details", "summary",
  "fieldset", "legend", "time", "abbr", "figure", "figcaption", "progress" }
for _, tag in ipairs(TAGS) do
  dom[tag] = function(props, ...) return dom.h(tag, props, ...) end
end

-- --- class helper ------------------------------------------------------------

local function class_string(cls)
  if type(cls) == "table" then
    local parts = {}
    for name, on in pairs(cls) do
      if on then parts[#parts + 1] = name end
    end
    table.sort(parts)
    return table.concat(parts, " ")
  end
  return cls or ""
end

-- --- güvenlik ----------------------------------------------------------------

local function safe_href(k, v)
  if (k == "href" or k == "src" or k == "action") and type(v) == "string"
    and v:lower():match("^%s*javascript:") then
    return nil -- javascript: URL'leri tamamen atılır
  end
  return v
end

local function is_event(k) return k:sub(1, 2) == "on" end

-- --- event handler'ları --------------------------------------------------------
-- Her eleman için JS'e event başına TEK dinleyici bağlanır; dinleyici güncel handler'ı
-- paylaşılan "kutu"dan okur. Böylece her render'da yeni closure → yeni JS listener olmaz.

local function sync_events(vnode)
  local box = vnode._box
  local wanted = {}
  for k, v in pairs(vnode.props) do
    if is_event(k) and type(v) == "function" then wanted[k:sub(3):lower()] = v end
  end
  for ev, fn in pairs(wanted) do
    box.handlers[ev] = fn
    if not box.offs[ev] then
      box.offs[ev] = js.dom.on(vnode._h, ev, function(e)
        local f = box.handlers[ev]
        if f then return f(e) end
      end)
    end
  end
  for ev in pairs(box.handlers) do
    if not wanted[ev] then box.handlers[ev] = nil end
  end
end

local function unbind_events(vnode)
  local box = vnode._box
  if not box then return end
  for _, off in pairs(box.offs) do pcall(off) end
  box.offs, box.handlers = {}, {}
end

-- --- create / remove ---------------------------------------------------------

local function set_prop(h, k, v)
  local val = safe_href(k, v)
  if val == nil then return end
  if PROP_ATTRS[k] then js.dom.setProp(h, k, val)
  else js.dom.setAttr(h, k, tostring(val)) end
end

local function create(vnode)
  if vnode.text ~= nil then
    vnode._h = js.dom.text(vnode.text)
    return vnode
  end
  local h = js.dom.create(vnode.tag)
  vnode._h = h
  vnode._box = { handlers = {}, offs = {} }
  for k, v in pairs(vnode.props) do
    if not is_event(k) and k ~= "key" and k ~= "class" then set_prop(h, k, v) end
  end
  if vnode.props.class then
    js.dom.setAttr(h, "class", class_string(vnode.props.class))
  end
  sync_events(vnode)
  for _, child in ipairs(vnode.children) do
    create(child)
    js.dom.append(h, child._h)
  end
  return vnode
end

local function release_tree(vnode)
  if not vnode then return end
  unbind_events(vnode)
  if vnode.children then
    for _, c in ipairs(vnode.children) do release_tree(c) end
  end
  if vnode._h then
    js.dom.release(vnode._h)
    vnode._h = nil
  end
end

local function remove(vnode)
  js.dom.remove(vnode._h) -- JS tarafı DOM'dan kaldırır
  release_tree(vnode)
end

-- Eski düğümün yerine (aynı konumda) yenisini koyar
local function replace(old, new)
  create(new)
  js.dom.replaceWith(old._h, new._h)
  release_tree(old)
  return new
end

-- --- props diff ----------------------------------------------------------------

local function diff_props(old, new)
  local h = new._h
  for k, v in pairs(new.props) do
    if is_event(k) or k == "key" then
      -- olaylar sync_events'te; key yalnızca diff ipucu
    elseif k == "class" then
      local new_cls = class_string(v)
      if class_string(old.props.class) ~= new_cls then js.dom.setAttr(h, "class", new_cls) end
    elseif old.props[k] ~= v then
      if safe_href(k, v) == nil then js.dom.removeAttr(h, k) else set_prop(h, k, v) end
    end
  end
  -- silinen prop'lar
  for k in pairs(old.props) do
    if new.props[k] == nil and not is_event(k) and k ~= "key" then
      if k == "class" then
        js.dom.removeAttr(h, "class")
      elseif PROP_ATTRS[k] then
        -- property'ler attribute silmekle sıfırlanmaz (ör. kullanıcı işaretlediği checkbox)
        js.dom.setProp(h, k, k == "value" and "" or false)
        js.dom.removeAttr(h, k)
      else
        js.dom.removeAttr(h, k)
      end
    end
  end
end

-- --- children diff -------------------------------------------------------------

local patch_vnode

local function all_keyed(list)
  for _, c in ipairs(list) do
    if c.text ~= nil or c.props.key == nil then return false end
  end
  return true
end

-- Keyed diff: anahtarı eşleşen düğüm yeniden yaratılmaz, yalnızca yeri değişir
local function diff_keyed(parent_h, olds, news)
  local by_key = {}
  for _, o in ipairs(olds) do by_key[o.props.key] = o end
  local used = {}
  for _, n in ipairs(news) do
    local o = by_key[n.props.key]
    if o and o.tag == n.tag and not used[o] then used[o] = n end
  end
  -- eşleşmeyen eskiler önce kaldırılır (indeksler kaymasın)
  for _, o in ipairs(olds) do
    if not used[o] then remove(o) end
  end
  local matched = {}
  for o, n in pairs(used) do matched[n] = o end
  for i, n in ipairs(news) do
    local o = matched[n]
    if o then patch_vnode(parent_h, o, n) else create(n) end
    js.dom.insertAt(parent_h, n._h, i - 1) -- yerindeyse JS tarafı dokunmaz
  end
end

local function diff_children(parent_h, olds, news)
  if #news > 0 and #olds > 0 and all_keyed(olds) and all_keyed(news) then
    return diff_keyed(parent_h, olds, news)
  end
  local max = math.max(#olds, #news)
  for i = 1, max do
    local o, n = olds[i], news[i]
    if o and not n then
      remove(o)
    elseif n and not o then
      create(n)
      js.dom.append(parent_h, n._h)
    else
      patch_vnode(parent_h, o, n)
    end
  end
end

-- --- patch ---------------------------------------------------------------------

-- Eski ve yeni ağacı karşılaştırıp minimum DOM işlemi uygular; yeni ağacı döner.
-- Odak/imleç korunur: aynı düğüm yeniden kullanılır (yalnızca prop'lar güncellenir).
patch_vnode = function(parent_h, old, new)
  if old.text ~= nil and new.text ~= nil then
    if old.text ~= new.text then js.dom.setText(old._h, new.text) end
    new._h = old._h
    return new
  elseif old.text ~= nil or new.text ~= nil or old.tag ~= new.tag then
    return replace(old, new)
  end
  new._h = old._h
  new._box = old._box
  old._box = nil -- dinleyiciler yeni vnode'a devredildi
  diff_props(old, new)
  sync_events(new)
  diff_children(new._h, old.children, new.children)
  return new
end

-- İlk yerleştirme: kök handle altına vnode ağacını kurar
function dom.mount(root_handle, vnode)
  create(vnode)
  js.dom.append(root_handle, vnode._h)
  return vnode
end

-- Kök patch: mount edilmiş ağacı yenisiyle karşılaştırır
function dom.patch(root_handle, old_vnode, new_vnode)
  if not old_vnode then
    return dom.mount(root_handle, new_vnode)
  end
  return patch_vnode(root_handle, old_vnode, new_vnode)
end

-- Tek seferlik yardımcılar (render dışı)
function dom.set_text(handle, s) js.dom.setText(handle, s) end
function dom.focus(id)
  local h = js.dom.byId(id)
  if h then
    js.dom.focus(h)
    js.dom.release(h)
  end
end
function dom.value(id)
  local h = js.dom.byId(id)
  if not h then return nil end
  local v = js.dom.getProp(h, "value")
  js.dom.release(h)
  return v
end
function dom.checked(id)
  local h = js.dom.byId(id)
  if not h then return false end
  local v = js.dom.getProp(h, "checked")
  js.dom.release(h)
  return v == true
end
function dom.set_value(id, v)
  local h = js.dom.byId(id)
  if h then
    js.dom.setProp(h, "value", v)
    js.dom.release(h)
  end
end

-- Debug: JS tarafındaki canlı handle sayısı (sızıntı izleme, F13/F17)
function dom.nodes_size() return js.dom._size and js.dom._size() or 0 end

dom._release_tree = release_tree
dom._create = create

return dom
