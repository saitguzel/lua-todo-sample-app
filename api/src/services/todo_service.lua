-- Todo servis: kapsam, sahiplik, PUT/PATCH semantiği, stats
local types = require("todo_shared.types")
local todo_repo = require("repositories.todo_repo")
local todo_model = require("models.todo")
local errors = require("middleware.error_handler")
local query = require("db.query")
local cjson = require("cjson.safe")
local validation = require("todo_shared.validation")
local audit_service = require("services.audit_service")

local _M = {}

local ADMIN = "admin"

local function scope_user_id(identity, requested)
  if identity.role == ADMIN then return requested end
  return identity.user_id
end

local function can_touch(identity, row)
  if not row then return false end
  return identity.role == ADMIN or row.user_id == identity.user_id
end

-- tags normalize: trim, boşları at, tekrarları kaldır (sıra korunur)
local function norm_tags(tags)
  if type(tags) ~= "table" then return tags end
  local seen, out = {}, {}
  for _, t in ipairs(tags) do
    local v = t:match("^%s*(.-)%s*$")
    if v ~= "" and not seen[v] then seen[v] = true; out[#out + 1] = v end
  end
  return out
end

-- Serileştirilmiş iki değer aynı mı (tags dizisi dahil)
local function same_value(a, b)
  if type(a) == "table" and type(b) == "table" then
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
  end
  return a == b
end

local function fill_zero(map, list)
  local out = {}
  for _, k in ipairs(list) do out[k] = map[k] or 0 end
  return out
end

function _M.list(identity, q)
  q = q or {}
  local uid = scope_user_id(identity, q.user_id)
  local filters = {
    user_id = uid,
    status = q.status,
    priority = q.priority,
    q = q.q,
    tag = q.tag,
    due_before = q.due_before,
    due_after = q.due_after,
  }
  local rows, total = todo_repo.list(filters, q.page, q.per_page, q.sort)
  if not rows then return nil, total end
  local items = {}
  for i, r in ipairs(rows) do items[i] = todo_model.serialize(r) end
  local total_pages = total > 0 and math.ceil(total / (q.per_page or 20)) or 0
  local per_page = q.per_page or 20
  return { items = items, meta = { page = q.page or 1, per_page = per_page, total = total, total_pages = total_pages } }
end

function _M.get(identity, id)
  local row, ferr = todo_repo.find(id)
  if ferr then return nil, ferr end
  if not can_touch(identity, row) then
    return nil, errors.new("TODO_NOT_FOUND", "Todo bulunamadi")
  end
  return todo_model.serialize(row)
end

function _M.create(identity, input)
  -- todouser yalnızca kendi adına; admin başkası adına oluşturabilir
  local owner = identity.user_id
  if input.user_id and input.user_id ~= identity.user_id then
    if identity.role ~= ADMIN then
      return nil, errors.new("FORBIDDEN", "Bu islem icin yetkiniz yok")
    end
    owner = input.user_id
  end
  local row, err = todo_repo.insert({
    user_id = owner,
    title = input.title,
    description = input.description,
    status = input.status,
    priority = input.priority,
    due_date = input.due_date,
    tags = norm_tags(input.tags),
  })
  if not row then
    if err and err.sqlstate == "23503" then
      return nil, errors.new("USER_NOT_FOUND", "Kullanici bulunamadi")
    end
    return nil, err
  end
  local todo = todo_model.serialize(row)
  audit_service.record("todo.create", { entity_type = "todo", entity_id = row.id, new_value = todo })
  return todo
end

-- PUT: tam temsil; eksik alanlar varsayılana döner (F6 §2.3)
local function full_fields(input)
  return {
    title = input.title,
    description = input.description == nil and cjson.null or input.description,
    status = input.status or "pending",
    priority = input.priority or "medium",
    due_date = input.due_date == nil and cjson.null or input.due_date,
    tags = norm_tags(input.tags) or {},
  }
end

-- PATCH: yalnızca gönderilen ve mevcut değerden farklı alanlar
local function changed_fields(input, old)
  local fields = {}
  for _, k in ipairs(todo_model.MUTABLE) do
    local v = input[k]
    if v ~= nil then
      if k == "tags" then v = norm_tags(v) end
      local cmp = (v == validation.NULL) and cjson.null or v
      if not same_value(cmp, old[k]) then fields[k] = v end
    end
  end
  return fields
end

-- PUT ve PATCH ortak akışı: kilitle → sahiplik → alanlar → update; değişiklik yoksa audit yok
local function modify(identity, id, build)
  local old_val, new_val
  local result, err = query.with_transaction(function()
    local old, ferr = todo_repo.find_for_update(id)
    if ferr then return nil, ferr end
    if not can_touch(identity, old) then
      return nil, errors.new("TODO_NOT_FOUND", "Todo bulunamadi")
    end
    old_val = todo_model.serialize(old)
    local fields = build(old_val)
    if next(fields) == nil then return old_val end
    local new_row, uerr = todo_repo.update(id, fields)
    if not new_row then return nil, uerr end
    new_val = todo_model.serialize(new_row)
    return new_val
  end)
  if not result then return nil, err end
  if new_val then
    audit_service.record("todo.update",
      { entity_type = "todo", entity_id = id, old_value = old_val, new_value = new_val })
  end
  return result
end

function _M.replace(identity, id, input)
  return modify(identity, id, function() return full_fields(input) end)
end

function _M.patch(identity, id, input)
  return modify(identity, id, function(old_val) return changed_fields(input, old_val) end)
end

function _M.delete(identity, id)
  local row, ferr = todo_repo.find(id)
  if ferr then return nil, ferr end
  if not can_touch(identity, row) then
    return nil, errors.new("TODO_NOT_FOUND", "Todo bulunamadi")
  end
  local deleted, derr = todo_repo.delete(id)
  if derr then return nil, derr end
  if not deleted then return nil, errors.new("TODO_NOT_FOUND", "Todo bulunamadi") end
  audit_service.record("todo.delete",
    { entity_type = "todo", entity_id = id, old_value = todo_model.serialize(deleted) })
  return true
end

function _M.stats(identity, q)
  q = q or {}
  local uid = scope_user_id(identity, q.user_id)
  -- 4 bağımsız aggregate paralel (00 §11 #16); her thread kendi bağlantısını alır
  local fns = {
    function() return todo_repo.stats_by_status(uid) end,
    function() return todo_repo.stats_by_priority(uid) end,
    function() return todo_repo.stats_due(uid) end,
    function() return todo_repo.stats_completed_daily(uid, 7) end,
  }
  local threads, res = {}, {}
  for i, fn in ipairs(fns) do threads[i] = ngx.thread.spawn(fn) end
  for i, th in ipairs(threads) do
    local ok, r, err = ngx.thread.wait(th)
    if not ok or not r then
      for j = i + 1, #threads do ngx.thread.kill(threads[j]) end
      return nil, err or errors.new("INTERNAL_ERROR", "Istatistik alinamadi")
    end
    res[i] = r
  end
  local r1, r2, r3, r4 = res[1], res[2], res[3], res[4]
  local by_status = fill_zero(r1, types.TODO_STATUS)
  local by_priority = fill_zero(r2, types.TODO_PRIORITY)
  local total = (by_status.pending or 0) + (by_status.in_progress or 0) + (by_status.completed or 0)
  local completion_rate = total > 0 and math.floor(by_status.completed * 1000 / total) / 10 or 0
  return {
    total = total,
    by_status = by_status,
    by_priority = by_priority,
    overdue = r3.overdue or 0,
    due_today = r3.due_today or 0,
    due_week = r3.due_week or 0,
    completion_rate = completion_rate,
    completed_last_7_days = r4,
    scope = uid and "user" or "all",
  }
end

return _M
