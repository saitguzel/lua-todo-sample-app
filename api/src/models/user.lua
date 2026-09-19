-- Kullanici modeli: DB satiri -> Lua tablosu, public serilestirme
-- password_hash hicbir public ciktiya girmez.
local cjson = require("cjson.safe")
local audit = require("models.audit")

local _M = {}

function _M.from_row(row)
  if not row then return nil end
  return {
    id = row.id,
    email = row.email,
    password_hash = row.password_hash,
    full_name = row.full_name,
    role = row.role,
    is_active = row.is_active,
    last_login_at = row.last_login_at,
    created_at = row.created_at,
    updated_at = row.updated_at,
  }
end

function _M.serialize(u)
  if not u then return nil end
  return {
    id = u.id,
    email = u.email,
    full_name = u.full_name or cjson.null,
    role = u.role,
    is_active = u.is_active,
    last_login_at = u.last_login_at or cjson.null,
    created_at = u.created_at,
    updated_at = u.updated_at,
  }
end

function _M.serialize_for_audit(u)
  local copy = _M.from_row(u)
  if not copy then return nil end
  return audit.mask(copy)
end

_M.COLUMNS = "id, email, password_hash, full_name, role, is_active, last_login_at, created_at, updated_at"
_M.PUBLIC_COLUMNS = "id, email, full_name, role, is_active, last_login_at, created_at, updated_at"

return _M
