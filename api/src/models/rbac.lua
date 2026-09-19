-- RBAC matris yardimcilari: DB satirlari <-> matris donusumu ve diff
local types = require("todo_shared.types")

local _M = {}

function _M.from_rows(rows)
  local m = {}
  for _, role in ipairs(types.ROLES) do
    m[role] = {}
    for _, page in ipairs(types.PAGES) do m[role][page] = false end
  end
  for _, r in ipairs(rows) do
    if m[r.role] and m[r.role][r.page_key] ~= nil then
      -- pgmoon boolean (OID 16) → Lua boolean
      m[r.role][r.page_key] = r.can_access == true
    end
  end
  return m
end

function _M.diff(old, new)
  local changes = {}
  for role, pages in pairs(new) do
    for page, nv in pairs(pages) do
      local ov = old[role] and old[role][page]
      if ov ~= nv then
        changes[#changes + 1] = { role = role, page_key = page, old = ov, new = nv }
      end
    end
  end
  return changes
end

function _M.violates_lock(role, page_key, value)
  return role == "admin" and page_key == "rbac.matrix" and value == false
end

return _M
