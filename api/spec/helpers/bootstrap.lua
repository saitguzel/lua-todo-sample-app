-- busted helper: todo_shared.X modüllerini repo içindeki ../shared/src/X.lua'dan çözer
-- (konteynerde /app/lib/todo_shared mount'u var; testler host/CI checkout'undan koşar)
local searchers = package.loaders -- LuaJIT (5.1): searchers yerine loaders
table.insert(searchers, 2, function(name)
  local sub = name:match("^todo_shared%.(.+)$")
  if not sub then return nil end
  local path = "../shared/src/" .. sub:gsub("%.", "/") .. ".lua"
  local chunk, err = loadfile(path)
  if not chunk then return "\n\tno file '" .. path .. "' (" .. tostring(err) .. ")" end
  return chunk
end)
