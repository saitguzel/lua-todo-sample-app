-- Kullanici repository: auth ve user yonetimi icin SQL sorgulari
-- Tum sorgular parametreli ($n) ve db/query uzerinden.
local query = require("db.query")

local _M = {}

function _M.find_by_email(email)
  return query.query_one("SELECT * FROM users WHERE email = $1 LIMIT 1", email)
end

function _M.find_by_id(id)
  return query.query_one("SELECT * FROM users WHERE id = $1 LIMIT 1", id)
end

function _M.touch_last_login(id)
  return query.exec("UPDATE users SET last_login_at = now() WHERE id = $1", id)
end

function _M.update_password(id, hash)
  return query.exec("UPDATE users SET password_hash = $2 WHERE id = $1", id, hash)
end

function _M.reset_token_create(user_id, hash, ttl)
  return query.exec(
    [[INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
      VALUES ($1, $2, now() + make_interval(secs => $3))]],
    user_id, hash, ttl
  )
end

function _M.reset_token_find_valid_for_update(hash)
  return query.query_one(
    [[SELECT id, user_id
      FROM password_reset_tokens
      WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now() FOR UPDATE]],
    hash
  )
end

function _M.reset_token_mark_used(id)
  return query.exec("UPDATE password_reset_tokens SET used_at = now() WHERE id = $1", id)
end

function _M.reset_token_invalidate_all(user_id)
  return query.exec("UPDATE password_reset_tokens SET used_at = now() WHERE user_id = $1 AND used_at IS NULL", user_id)
end

-- F7: list / count / insert / update / delete

function _M.list(filters, page, per_page, sort_col, sort_dir)
  filters = filters or {}
  page = page or 1
  per_page = per_page or 20
  sort_col = sort_col or "created_at"
  sort_dir = sort_dir or "DESC"
  local allowed_sort = { created_at = true, email = true, full_name = true, last_login_at = true, role = true }
  if not allowed_sort[sort_col] then sort_col = "created_at" end
  if sort_dir ~= "ASC" and sort_dir ~= "DESC" then sort_dir = "DESC" end
  local clauses = {}
  local params = {}
  local function add(sql, val)
    params[#params + 1] = val
    clauses[#clauses + 1] = sql:gsub("%$%?", "$" .. #params)
  end
  if filters.role then add("role = $?::user_role", filters.role) end
  if filters.is_active ~= nil then add("is_active = $?", filters.is_active) end
  if filters.q then
    local pat = query.like_pattern(filters.q)
    params[#params + 1] = pat
    local idx = #params
    clauses[#clauses + 1] = "(email ILIKE $" .. idx .. " ESCAPE '\\' OR full_name ILIKE $" .. idx .. " ESCAPE '\\')"
  end
  local where = #clauses > 0 and ("WHERE " .. table.concat(clauses, " AND ")) or ""
  local offset = (page - 1) * per_page
  -- limit/offset parametreleri
  params[#params + 1] = per_page
  local lim_idx = #params
  params[#params + 1] = offset
  local off_idx = #params
  local sql = string.format(
    [[SELECT id, email, full_name, role, is_active, last_login_at, created_at, updated_at,
      COUNT(*) OVER() AS total_count
      FROM users %s
      ORDER BY %s %s, id
      LIMIT $%d OFFSET $%d]],
    where, sort_col, sort_dir, lim_idx, off_idx
  )
  local rows, err = query.query(sql, unpack(params))
  if not rows then return nil, err end
  local total = 0
  if rows[1] and rows[1].total_count then total = tonumber(rows[1].total_count) or 0 end
  for _, r in ipairs(rows) do r.total_count = nil end
  return rows, total
end

function _M.insert(u)
  return query.query_one(
    [[INSERT INTO users (email, password_hash, full_name, role, is_active)
      VALUES ($1, $2, $3, $4::user_role, $5)
      RETURNING *]],
    u.email, u.password_hash, u.full_name, u.role, u.is_active
  )
end

function _M.find_for_update(id)
  return query.query_one("SELECT * FROM users WHERE id = $1 FOR UPDATE", id)
end

function _M.update(id, fields)
  if not fields or not next(fields) then return _M.find_by_id(id) end
  local set_map = {
    email = "email = $?",
    password_hash = "password_hash = $?",
    full_name = "full_name = $?",
    role = "role = $?::user_role",
    is_active = "is_active = $?",
  }
  local sets = {}
  local params = {}
  for k, expr in pairs(set_map) do
    if fields[k] ~= nil then
      params[#params + 1] = fields[k]
      local sql = expr:gsub("%$%?", "$" .. #params)
      sets[#sets + 1] = sql
    end
  end
  if #sets == 0 then return _M.find_by_id(id) end
  params[#params + 1] = id
  local sql = "UPDATE users SET " .. table.concat(sets, ", ") .. " WHERE id = $" .. #params .. " RETURNING *"
  return query.query_one(sql, unpack(params))
end

function _M.delete(id)
  return query.query_one("DELETE FROM users WHERE id = $1 RETURNING *", id)
end

function _M.lock_active_admins()
  local rows, err = query.query("SELECT id FROM users WHERE role = 'admin' AND is_active = true FOR UPDATE")
  if not rows then return nil, err end
  return rows
end

function _M.count_active_admins()
  local row = query.query_one("SELECT count(*)::int AS c FROM users WHERE role = 'admin' AND is_active = true")
  if row then return row.c end
  return 0
end

return _M
