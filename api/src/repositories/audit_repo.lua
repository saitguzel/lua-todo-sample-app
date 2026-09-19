-- Audit repository: insert, list, find, stats, batch, delete
local query = require("db.query")

local _M = {}

function _M.insert(entry)
  return query.exec(
    [[INSERT INTO audit_logs (user_id, user_email, action, entity_type, entity_id, old_value, new_value,
      ip_address, user_agent, status, error_message)
      VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8::inet, $9, $10, $11)]],
    entry.user_id, entry.user_email, entry.action, entry.entity_type, entry.entity_id,
    entry.old_value, entry.new_value, entry.ip_address, entry.user_agent, entry.status, entry.error_message
  )
end

local function add_clause(clauses, params, sql, val)
  if val == nil then return end
  params[#params + 1] = val
  clauses[#clauses + 1] = sql:gsub("%$%?", "$" .. #params)
end

local function build_where(f)
  f = f or {}
  local clauses = {}
  local params = {}
  if f.user_id then add_clause(clauses, params, "user_id = $?", f.user_id) end
  if f.user_email then
    add_clause(clauses, params, "user_email ILIKE $? ESCAPE '\\'", query.like_pattern(f.user_email))
  end
  if f.action_prefix then add_clause(clauses, params, "action LIKE $? ESCAPE '\\'", f.action_prefix .. ".%")
  elseif f.action then add_clause(clauses, params, "action = $?", f.action) end
  if f.entity_type then add_clause(clauses, params, "entity_type = $?", f.entity_type) end
  if f.entity_id then add_clause(clauses, params, "entity_id = $?", f.entity_id) end
  if f.status then add_clause(clauses, params, "status = $?", f.status) end
  if f.ip then add_clause(clauses, params, "ip_address = $?::inet", f.ip) end
  if f.from then add_clause(clauses, params, "created_at >= $?::timestamptz", f.from) end
  if f.to then add_clause(clauses, params, "created_at < $?::timestamptz", f.to) end
  local where = #clauses > 0 and ("WHERE " .. table.concat(clauses, " AND ")) or ""
  return where, params
end

local function normalize(filters)
  filters = filters or {}
  if filters.action and filters.action:sub(-2) == ".*" then
    local clone = {}
    for k, v in pairs(filters) do clone[k] = v end
    clone.action_prefix = clone.action:sub(1, -3)
    clone.action = nil
    return clone
  end
  return filters
end

function _M.list(filters, page, per_page)
  filters = normalize(filters)
  page = page or 1
  per_page = per_page or 20
  local where, params = build_where(filters)
  local offset = (page - 1) * per_page
  params[#params + 1] = per_page
  local lim = #params
  params[#params + 1] = offset
  local off = #params
  local sql = string.format(
    [[SELECT id, user_id, user_email, action, entity_type, entity_id, ip_address, user_agent, status,
      error_message, created_at, COUNT(*) OVER() AS total_count
      FROM audit_logs %s
      ORDER BY created_at DESC, id DESC
      LIMIT $%d OFFSET $%d]],
    where, lim, off
  )
  local rows, err = query.query(sql, unpack(params))
  if not rows then return nil, err end
  local total = 0
  if rows[1] and rows[1].total_count then total = tonumber(rows[1].total_count) or 0 end
  for _, r in ipairs(rows) do r.total_count = nil end
  return rows, total
end

function _M.find(id)
  return query.query_one("SELECT * FROM audit_logs WHERE id = $1", id)
end

function _M.stats_by_action(filters)
  filters = normalize(filters)
  local where, params = build_where(filters)
  local sql = [[SELECT action, count(*)::int AS count
    FROM audit_logs ]] .. where .. " GROUP BY action ORDER BY count DESC LIMIT 20"
  return query.query(sql, unpack(params))
end

function _M.stats_by_status(filters)
  filters = normalize(filters)
  local where, params = build_where(filters)
  local sql = "SELECT status, count(*)::int AS count FROM audit_logs " .. where .. " GROUP BY status"
  return query.query(sql, unpack(params))
end

function _M.stats_by_day(filters)
  filters = normalize(filters)
  local where, params = build_where(filters)
  local sql = [[SELECT to_char(date_trunc('day', created_at), 'YYYY-MM-DD') AS day, count(*)::int AS count
    FROM audit_logs ]] .. where .. " GROUP BY 1 ORDER BY 1"
  return query.query(sql, unpack(params))
end

function _M.stats_top_users(filters)
  filters = normalize(filters)
  local where, params = build_where(filters)
  local extra = where ~= "" and " AND user_email IS NOT NULL" or "WHERE user_email IS NOT NULL"
  local sql = [[SELECT user_email, count(*)::int AS count
    FROM audit_logs ]] .. where .. extra .. " GROUP BY user_email ORDER BY count DESC LIMIT 10"
  return query.query(sql, unpack(params))
end

function _M.stats_total(filters)
  filters = normalize(filters)
  local where, params = build_where(filters)
  return query.query_one("SELECT count(*)::int AS count FROM audit_logs " .. where, unpack(params))
end

function _M.stats_failed_logins_24h()
  return query.query_one([[SELECT count(*)::int AS n
    FROM audit_logs
    WHERE action = 'auth.login.failure' AND created_at > now() - interval '24 hours']])
end

function _M.batch_after(filters, before_id, limit)
  filters = normalize(filters)
  local where, params = build_where(filters)
  -- bigint üst sınırı string: double olarak 2^63 bigint aralığını aşar
  params[#params + 1] = before_id or "9223372036854775807"
  local id_idx = #params
  params[#params + 1] = limit or 1000
  local lim_idx = #params
  local extra = "id < $" .. id_idx
  local where2
  if where == "" then where2 = "WHERE " .. extra else where2 = where .. " AND " .. extra end
  local sql = "SELECT * FROM audit_logs " .. where2 .. " ORDER BY id DESC LIMIT $" .. lim_idx
  return query.query(sql, unpack(params))
end

function _M.delete_older_than(days, limit)
  local rows, err = query.query(
    [[DELETE
      FROM audit_logs
      WHERE id IN (SELECT id
      FROM audit_logs
      WHERE created_at < now() - make_interval(days => $1)
      ORDER BY created_at
      LIMIT $2)
      RETURNING 1]],
    days, limit
  )
  if not rows then return nil, err end
  return #rows
end

return _M
