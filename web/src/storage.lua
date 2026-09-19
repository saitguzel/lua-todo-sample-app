-- F13: localStorage sarmalayıcısı. Değerler JSON olarak saklanır;
-- bozuk JSON veya erişim hatası → default döner (uygulama çökmez).

local json = require("json")

local storage = {}
local PREFIX = "todo."

function storage.get(key, default)
  local raw = js.storage.get(PREFIX .. key)
  if raw == nil or raw == "" then return default end
  local ok, val = pcall(json.decode, raw)
  if not ok then return default end
  return val
end

function storage.set(key, value)
  local ok, raw = pcall(json.encode, value)
  if not ok then return false end
  return js.storage.set(PREFIX .. key, raw) == true
end

function storage.remove(key)
  js.storage.remove(PREFIX .. key)
end

-- Düz string erişimi (todo.theme boot.js ile paylaşılır; JSON sarması yok)
function storage.get_raw(key)
  local raw = js.storage.get(PREFIX .. key)
  if raw == nil or raw == "" then return nil end
  -- JSON string '"dark"' sarmasını kaldır
  return raw:match('^"(.*)"$') or raw
end

function storage.set_raw(key, value)
  return js.storage.set(PREFIX .. key, value) == true
end

return storage
