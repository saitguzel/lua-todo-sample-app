-- Kullanici servis: CRUD is kurallari, self/last-admin korumalari
local user_repo = require("repositories.user_repo")
local user_model = require("models.user")
local password = require("security.password")
local errors = require("middleware.error_handler")
local query = require("db.query")

local _M = {}

function _M.list(_, q)
  q = q or {}
  local sort_col = "created_at"
  local sort_dir = "DESC"
  if q.sort then
    if q.sort:sub(1, 1) == "-" then sort_col = q.sort:sub(2); sort_dir = "DESC"
    else sort_col = q.sort; sort_dir = "ASC" end
  end
  local is_active = nil
  if q.is_active == "true" then is_active = true elseif q.is_active == "false" then is_active = false end
  local filters = { q = q.q, role = q.role, is_active = is_active }
  local rows, total = user_repo.list(filters, q.page, q.per_page, sort_col, sort_dir)
  if not rows then return nil, total end
  local items = {}
  for i, r in ipairs(rows) do items[i] = user_model.serialize(r) end
  local total_pages = total > 0 and math.ceil(total / (q.per_page or 20)) or 0
  local per_page = q.per_page or 20
  return { items = items, meta = { page = q.page or 1, per_page = per_page, total = total, total_pages = total_pages } }
end

function _M.get(_, id)
  local row, err = user_repo.find_by_id(id)
  if err then return nil, err end
  if not row then return nil, errors.new("USER_NOT_FOUND", "Kullanici bulunamadi") end
  return user_model.serialize(row)
end

function _M.create(_, input)
  local email = input.email:lower():match("^%s*(.-)%s*$")
  local hash, herr = password.hash(input.password)
  if not hash then return nil, errors.new("VALIDATION_FAILED", herr) end
  local fields = {
    email = email,
    password_hash = hash,
    full_name = input.full_name,
    role = input.role or "todouser",
    is_active = input.is_active,
  }
  if fields.is_active == nil then fields.is_active = true end
  local row, err = user_repo.insert(fields)
  if not row then
    if err and err.sqlstate == "23505" then
      return nil, errors.new("EMAIL_TAKEN", "Bu e-posta zaten kullaniliyor")
    end
    return nil, errors.new("INTERNAL_ERROR", "Kullanici olusturulamadi")
  end
  require("services.audit_service").record("user.create", {
    entity_type = "user", entity_id = row.id,
    new_value = user_model.serialize_for_audit(row),
  })
  return user_model.serialize(row)
end

function _M.update(identity, id, input)
  local new_hash = nil
  if input.password then
    local h, herr = password.hash(input.password)
    if not h then return nil, errors.new("VALIDATION_FAILED", herr) end
    new_hash = h
  end
  local audit_old, audit_new
  local ok, err = query.with_transaction(function()
    local old, ferr = user_repo.find_for_update(id)
    if ferr then return nil, ferr end
    if not old then return nil, errors.new("USER_NOT_FOUND", "Kullanici bulunamadi") end
    local demoting = old.role == "admin" and input.role ~= nil and input.role ~= "admin"
    local deactivating = old.is_active and input.is_active == false
    if id == identity.user_id and (demoting or deactivating) then
      return nil, errors.new("SELF_ACTION_FORBIDDEN", "Kendi hesabiniz uzerinde bu islem yapilamaz")
    end
    if (demoting or deactivating) and old.role == "admin" and old.is_active then
      local admins, aerr = user_repo.lock_active_admins()
      if not admins then return nil, aerr end
      if #admins <= 1 then
        return nil, errors.new("LAST_ADMIN", "Sistemdeki son aktif admin degistirilemez")
      end
    end
    local fields = {
      email = input.email and input.email:lower():match("^%s*(.-)%s*$") or nil,
      full_name = input.full_name,
      role = input.role,
      is_active = input.is_active,
    }
    if new_hash then fields.password_hash = new_hash end
    local new_row, uerr = user_repo.update(id, fields)
    if not new_row then
      if uerr and uerr.sqlstate == "23505" then
        return nil, errors.new("EMAIL_TAKEN", "Bu e-posta zaten kullaniliyor")
      end
      return nil, uerr or errors.new("INTERNAL_ERROR", "Guncellenemedi")
    end
    audit_old = user_model.serialize_for_audit(old)
    audit_new = user_model.serialize_for_audit(new_row)
    -- hash her iki tarafta "***"; parola değişimi ayrıca işaretlenir
    if new_hash then audit_new.password_changed = true end
    return new_row
  end)
  if not ok then return nil, err end
  if audit_old then
    require("services.audit_service").record("user.update", {
      entity_type = "user", entity_id = id, old_value = audit_old, new_value = audit_new,
    })
  end
  return user_model.serialize(ok)
end

function _M.delete(identity, id)
  if id == identity.user_id then
    return nil, errors.new("SELF_ACTION_FORBIDDEN", "Kendi hesabiniz silinemez")
  end
  local audit_old
  local ok, err = query.with_transaction(function()
    local old, ferr = user_repo.find_for_update(id)
    if ferr then return nil, ferr end
    if not old then return nil, errors.new("USER_NOT_FOUND", "Kullanici bulunamadi") end
    if old.role == "admin" and old.is_active then
      local admins, aerr = user_repo.lock_active_admins()
      if not admins then return nil, aerr end
      if #admins <= 1 then return nil, errors.new("LAST_ADMIN", "Son admin silinemez") end
    end
    local deleted, derr = user_repo.delete(id)
    if derr then return nil, derr end
    if not deleted then return nil, errors.new("USER_NOT_FOUND", "Kullanici bulunamadi") end
    audit_old = user_model.serialize_for_audit(old)
    return true
  end)
  if not ok then return nil, err end
  require("services.audit_service").record("user.delete", {
    entity_type = "user", entity_id = id, old_value = audit_old,
  })
  return true
end

return _M
