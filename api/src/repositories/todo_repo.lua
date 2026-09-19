-- Todo repository: parametreli SQL ile dinamik filtre, liste, CRUD, stats
local query = require("db.query")
local cjson = require("cjson.safe")
local todo_model = require("models.todo")

local _M = {}

local function build_where(f)
  local clauses = {}
  local params = {}
  local function add(sql_fmt, value)
    params[#params + 1] = value
    clauses[#clauses + 1] = sql_fmt:gsub("%$%?", "$" .. #params)
  end
  if f.user_id then add("t.user_id = $?", f.user_id) end
  if f.status then add("t.status = $?::todo_status", f.status) end
  if f.priority then add("t.priority = $?::todo_priority", f.priority) end
  if f.tag then add("$? = ANY(t.tags)", f.tag) end
  if f.due_before then add("t.due_date < $?::timestamptz", f.due_before) end
  if f.due_after then add("t.due_date >= $?::timestamptz", f.due_after) end
  if f.q then
    local pat = query.like_pattern(f.q)
    add("(t.title ILIKE $? ESCAPE '\\')", pat)
  end
  local where = #clauses > 0 and ("WHERE " .. table.concat(clauses, " AND ")) or ""
  return where, params
end

function _M.list(filters, page, per_page, sort)
  filters = filters or {}
  page = page or 1
  per_page = per_page or 20
  sort = sort or "-created_at"
  local sort_col = sort:gsub("^-", "")
  local sort_dir = sort:sub(1, 1) == "-" and "DESC" or "ASC"
  if not todo_model.SORTABLE[sort_col] then sort_col = "created_at" end
  local where, params = build_where(filters)
  local offset = (page - 1) * per_page
  params[#params + 1] = per_page
  local lim_idx = #params
  params[#params + 1] = offset
  local off_idx = #params
  local order_expr = "t." .. sort_col .. " " .. sort_dir .. " NULLS LAST, t.id"
  -- priority enum sort: natural order already, but explicit
  local sql = string.format(
    [[SELECT t.*, u.email AS owner_email, COUNT(*) OVER() AS total_count
      FROM todos t
      JOIN users u ON u.id = t.user_id %s
      ORDER BY %s
      LIMIT $%d OFFSET $%d]],
    where, order_expr, lim_idx, off_idx
  )
  local rows, err = query.query(sql, unpack(params, 1, #params))
  if not rows then return nil, err end
  local total = 0
  if rows[1] and rows[1].total_count then total = tonumber(rows[1].total_count) or 0 end
  for _, r in ipairs(rows) do r.total_count = nil end
  return rows, total
end

function _M.find(id)
  return query.query_one([[SELECT t.*, u.email AS owner_email
    FROM todos t
    JOIN users u ON u.id = t.user_id
    WHERE t.id = $1]], id)
end

function _M.find_for_update(id)
  return query.query_one("SELECT * FROM todos WHERE id = $1 FOR UPDATE", id)
end

function _M.insert(fields)
  local tags_json = cjson.encode(fields.tags or {})
  return query.query_one(
    [[INSERT INTO todos (user_id, title, description, status, priority, due_date, tags, completed_at)
      VALUES ($1, $2, $3, $4::todo_status, $5::todo_priority, $6::timestamptz,
      ARRAY(SELECT jsonb_array_elements_text($7::jsonb)), CASE WHEN $4 = 'completed'
      THEN now() END)
      RETURNING *]],
    fields.user_id, fields.title, fields.description, fields.status or "pending",
    fields.priority or "medium", fields.due_date, tags_json
  )
end

-- Sabit sıralı SET listesi: yalnızca fields'ta bulunan (nil olmayan) alanlar yazılır.
-- NULL için validation.NULL / cjson.null gelir → db/query SQL NULL'a çevirir (sayaç kaymaz).
local SET_ORDER = {
  { "title", "title = $?" },
  { "description", "description = $?" },
  { "status", "status = $?::todo_status" },
  { "priority", "priority = $?::todo_priority" },
  { "due_date", "due_date = $?::timestamptz" },
  { "tags", "tags = ARRAY(SELECT jsonb_array_elements_text($?::jsonb))" },
}

function _M.update(id, fields)
  local sets, params, n = {}, {}, 0
  local status_idx
  for _, def in ipairs(SET_ORDER) do
    local field, expr = def[1], def[2]
    local val = fields[field]
    if val ~= nil then
      if field == "tags" then val = cjson.encode(val) end
      n = n + 1
      params[n] = val
      sets[#sets + 1] = expr:gsub("%$%?", "$" .. n)
      if field == "status" then status_idx = n end
    end
  end
  if n == 0 then return _M.find(id) end
  -- completed_at kuralı: completed'a geçişte (ilk kez) now(), başka duruma geçişte NULL
  if status_idx then
    sets[#sets + 1] = "completed_at = CASE WHEN $" .. status_idx
      .. "::todo_status = 'completed' THEN COALESCE(completed_at, now()) ELSE NULL END"
  end
  n = n + 1
  params[n] = id
  local sql = "UPDATE todos SET " .. table.concat(sets, ", ") .. " WHERE id = $" .. n .. " RETURNING *"
  return query.query_one(sql, unpack(params, 1, n))
end

function _M.delete(id)
  return query.query_one("DELETE FROM todos WHERE id = $1 RETURNING *", id)
end

function _M.stats_by_status(uid)
  local rows, err = query.query([[SELECT status, count(*)::int AS n
    FROM todos
    WHERE ($1::uuid IS NULL OR user_id = $1)
    GROUP BY status]], uid)
  if not rows then return nil, err end
  local map = {}
  for _, r in ipairs(rows) do map[r.status] = r.n end
  return map
end

function _M.stats_by_priority(uid)
  local rows, err = query.query([[SELECT priority, count(*)::int AS n
    FROM todos
    WHERE ($1::uuid IS NULL OR user_id = $1)
    GROUP BY priority]], uid)
  if not rows then return nil, err end
  local map = {}
  for _, r in ipairs(rows) do map[r.priority] = r.n end
  return map
end

function _M.stats_due(uid)
  local row, err = query.query_one(
    [[SELECT
        count(*) FILTER (WHERE due_date < now() AND status <> 'completed')::int AS overdue,
        count(*) FILTER (WHERE due_date::date = current_date AND status <> 'completed')::int AS due_today,
        count(*) FILTER (WHERE due_date >= now() AND due_date < now() + interval '7 days'
                           AND status <> 'completed')::int AS due_week
      FROM todos
      WHERE ($1::uuid IS NULL OR user_id = $1)]],
    uid
  )
  if not row then return nil, err end
  return row
end

function _M.stats_completed_daily(uid, days)
  days = days or 7
  local rows, err = query.query(
    [[SELECT d::date AS day, count(t.id)::int AS count
      FROM generate_series(current_date - ($2::int - 1), current_date, interval '1 day') d
      LEFT
      JOIN todos t ON t.completed_at::date = d::date
      AND ($1::uuid IS NULL OR t.user_id = $1)
      GROUP BY d
      ORDER BY d]],
    uid, days
  )
  if not rows then return nil, err end
  -- pg returns day as string "2026-09-18"
  for _, r in ipairs(rows) do
    if type(r.day) == "string" then r.day = r.day:sub(1, 10) end
  end
  return rows
end

return _M
