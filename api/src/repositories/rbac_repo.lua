-- RBAC repository: role_page_permissions okuma/upsert
local query = require("db.query")

local _M = {}

function _M.all()
  return query.query("SELECT role, page_key, can_access FROM role_page_permissions ORDER BY role, page_key")
end

function _M.by_role(role)
  return query.query("SELECT page_key, can_access FROM role_page_permissions WHERE role = $1::user_role", role)
end

function _M.upsert(role, page_key, value)
  return query.exec(
    [[INSERT INTO role_page_permissions (role, page_key, can_access)
      VALUES ($1::user_role, $2, $3)
      ON CONFLICT (role, page_key)
      DO UPDATE
      SET can_access = EXCLUDED.can_access]],
    role, page_key, value
  )
end

function _M.lock_all()
  return query.query("SELECT 1 FROM role_page_permissions FOR UPDATE")
end

return _M
