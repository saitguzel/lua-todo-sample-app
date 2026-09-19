-- F16: Klavye kısayolu kaydı. View'lar register/unregister_scope yapar;
-- glue.js tek keydown dinleyicisini app.lua'ya bağlar, bu modül dağıtır.

local shortcuts = {}

-- WCAG 2.1.4: tek tuş kısayolları kullanıcı tarafından kapatılabilir (profil ayarı, localStorage'da kalıcı)
local STORAGE_KEY = "todo.shortcuts"
function shortcuts.enabled()
  return js.storage.get(STORAGE_KEY) ~= "off"
end
function shortcuts.set_enabled(on)
  if on then js.storage.remove(STORAGE_KEY) else js.storage.set(STORAGE_KEY, "off") end
end

-- scope -> { [key] = { fn, description } }
local registry = {}

function shortcuts.register(scope, key, fn, description)
  registry[scope] = registry[scope] or {}
  registry[scope][key] = { fn = fn, description = description or "" }
end

function shortcuts.unregister_scope(scope)
  registry[scope] = nil
end

-- yardım modalı için
function shortcuts.list()
  local out = {}
  for scope, keys in pairs(registry) do
    for key, entry in pairs(keys) do
      out[#out + 1] = { scope = scope, key = key, description = entry.description }
    end
  end
  table.sort(out, function(a, b)
    if a.scope ~= b.scope then return a.scope < b.scope end
    return a.key < b.key
  end)
  return out
end

-- Aktif route'a göre bakılacak scope'lar (todos_new/todo_edit de "todos" view'ıdır)
local function active_scopes()
  local scopes = {}
  local ok, app = pcall(require, "app")
  local name = ok and app.get_state().route.name or nil
  if name then
    scopes[#scopes + 1] = name
    if name:find("^todo") then scopes[#scopes + 1] = "todos" end
  end
  scopes[#scopes + 1] = "global"
  return scopes
end

-- app.lua js.keyboard.onKey'den çağrılır. Dönüş true → JS e.preventDefault() yapar.
function shortcuts.handle_key(key, typing, ctrl, alt)
  -- tarayıcı kısayollarıyla çakışmasın; kullanıcı kapattıysa hiçbiri çalışmaz
  if ctrl or alt or not shortcuts.enabled() then return false end
  -- editable hedefte tek harfliler tetiklenmez (WCAG 2.1.4); yalnız Esc çalışır
  if typing and key ~= "Escape" then return false end
  -- açık native dialog Esc'i kendi cancel olayıyla yönetir; diğer kısayollar da arka planda çalışmaz
  if js.dom.modalOpen and js.dom.modalOpen() then return false end

  for _, sc in ipairs(active_scopes()) do
    local entry = registry[sc] and registry[sc][key]
    if entry then
      local ok, prevent = pcall(entry.fn)
      if not ok then js.log("error", "kısayol hatası: " .. tostring(prevent)) end
      return ok and prevent == true
    end
  end
  return false
end

return shortcuts
