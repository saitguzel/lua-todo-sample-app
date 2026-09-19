-- Audit log modeli ve hassas alan maskeleme

local _M = {}

_M.SENSITIVE_KEYS = {
  password = true, password_hash = true, new_password = true, token = true,
  token_hash = true, refresh_token = true, access_token = true, secret = true,
}
_M.MASK = "***"
_M.MAX_DEPTH = 10

_M.CSV_COLUMNS = {
  "id", "created_at", "user_email", "user_id", "action", "entity_type",
  "entity_id", "status", "ip_address", "user_agent", "error_message",
  "old_value", "new_value",
}

local function mask_inner(value, depth, seen)
  if type(value) ~= "table" then return value end
  depth = depth or 0
  if depth >= _M.MAX_DEPTH then return "[derinlik siniri]" end
  if seen and seen[value] then return "[dongusel]" end
  seen = seen or {}
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    if type(k) == "string" and _M.SENSITIVE_KEYS[k:lower()] then
      out[k] = _M.MASK
    else
      if type(v) == "table" then
        out[k] = mask_inner(v, depth + 1, seen)
      else
        out[k] = v
      end
    end
  end
  local mt = getmetatable(value)
  if mt then setmetatable(out, mt) end
  seen[value] = nil
  return out
end

function _M.mask(value, seen, depth)
  if type(value) ~= "table" then return value end
  return mask_inner(value, depth or 0, seen)
end

function _M.from_row(row)
  if not row then return nil end
  return {
    id = row.id and tonumber(row.id) or row.id,
    user_id = row.user_id,
    user_email = row.user_email,
    action = row.action,
    entity_type = row.entity_type,
    entity_id = row.entity_id,
    old_value = row.old_value,
    new_value = row.new_value,
    ip_address = row.ip_address,
    user_agent = row.user_agent,
    status = row.status,
    error_message = row.error_message,
    created_at = row.created_at,
  }
end

function _M.serialize(a)
  if not a then return nil end
  return {
    id = a.id and tonumber(a.id) or a.id,
    user_id = a.user_id,
    user_email = a.user_email,
    action = a.action,
    entity_type = a.entity_type,
    entity_id = a.entity_id,
    old_value = a.old_value,
    new_value = a.new_value,
    ip_address = a.ip_address,
    user_agent = a.user_agent,
    status = a.status,
    error_message = a.error_message,
    created_at = a.created_at,
  }
end

return _M
