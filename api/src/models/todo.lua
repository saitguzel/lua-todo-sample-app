-- Todo modeli: DB satirini public JSON gorunumune cevirir
local cjson = require("cjson.safe")

local _M = {}

_M.SORTABLE = {
  created_at = true, updated_at = true, due_date = true,
  priority = true, status = true, title = true,
}

_M.MUTABLE = { "title", "description", "status", "priority", "due_date", "tags" }

function _M.from_row(row)
  if not row then return nil end
  return {
    id = row.id,
    user_id = row.user_id,
    title = row.title,
    description = row.description,
    status = row.status,
    priority = row.priority,
    due_date = row.due_date,
    tags = row.tags,
    created_at = row.created_at,
    updated_at = row.updated_at,
    completed_at = row.completed_at,
    owner_email = row.owner_email,
  }
end

function _M.serialize(row)
  if not row then return nil end
  local tags = row.tags
  if tags == nil or tags == cjson.null then
    tags = cjson.empty_array
  elseif type(tags) == "table" and next(tags) == nil then
    tags = cjson.empty_array
  end
  return {
    id = row.id,
    user_id = row.user_id,
    title = row.title,
    description = row.description or cjson.null,
    status = row.status,
    priority = row.priority,
    due_date = row.due_date or cjson.null,
    tags = tags,
    created_at = row.created_at,
    updated_at = row.updated_at,
    completed_at = row.completed_at or cjson.null,
    owner_email = row.owner_email,
  }
end

return _M
