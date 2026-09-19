-- RBAC servis: cache, matris okuma/yazma, kilit kurali
local cjson = require("cjson.safe")
local config = require("config")
local types = require("todo_shared.types")
local rbac_repo = require("repositories.rbac_repo")
local rbac_model = require("models.rbac")
local errors = require("middleware.error_handler")
local query = require("db.query")

local _M = {}

local function role_map(role)
  local cache = ngx.shared.rbac_cache
  local key = "rbac:" .. role
  if cache then
    local raw = cache:get(key)
    if raw then
      local ok, decoded = pcall(cjson.decode, raw)
      if ok and decoded then return decoded end
    end
  end
  local rows, err = rbac_repo.by_role(role)
  if not rows then
    ngx.log(ngx.ERR, "rbac yuklenemedi: ", err and err.message or tostring(err))
    return nil
  end
  -- 9 sayfanın hepsi döner; DB'de satırı olmayan anahtar false
  local map = {}
  for _, page in ipairs(types.PAGES) do map[page] = false end
  for _, r in ipairs(rows) do
    if map[r.page_key] ~= nil then map[r.page_key] = r.can_access == true end
  end
  if cache then
    local ttl = config.get() and config.get().rbac_cache_ttl or 60
    local ok, serr = cache:set(key, cjson.encode(map), ttl)
    if not ok then ngx.log(ngx.WARN, "rbac_cache set basarisiz: ", serr) end
  end
  return map
end

function _M.can(role, page_key)
  local map = role_map(role)
  return map ~= nil and map[page_key] == true
end

-- UI için izin haritası; DB okunamazsa F1 varsayılanları (sunucu tarafı `can` yine fail-closed)
function _M.permissions_for(role)
  local map = role_map(role)
  if map then return map end
  map = {}
  for _, page in ipairs(types.PAGES) do map[page] = types.default_permission(role, page) end
  return map
end

function _M.pages()
  local list = {}
  for _, key in ipairs(types.PAGES) do
    local meta = types.PAGE_META[key] or { label = key, group = "genel" }
    local locked_for = {}
    for _, entry in ipairs(types.LOCKED_PERMISSIONS) do
      if entry.page_key == key then locked_for[#locked_for + 1] = entry.role end
    end
    list[#list + 1] = { key = key, label = meta.label, group = meta.group, locked_for = locked_for }
  end
  return list
end

function _M.matrix()
  local rows, err = rbac_repo.all()
  if not rows then return nil, err end
  local matrix = rbac_model.from_rows(rows)
  return {
    roles = types.ROLES,
    pages = types.PAGES,
    matrix = matrix,
  }
end

function _M.invalidate(role_or_nil)
  local cache = ngx.shared.rbac_cache
  if not cache then return end
  if role_or_nil then
    cache:delete("rbac:" .. role_or_nil)
  else
    for _, r in ipairs(types.ROLES) do cache:delete("rbac:" .. r) end
  end
end

function _M.update_matrix(_, matrix_input)
  -- Kabul edilen gövdeler: kanonik { permissions = { {role, page_key, can_access}, ... } } (F1 rbac_matrix),
  -- { matrix = { role = { page = bool } } } veya doğrudan { role = { page = bool } } (set_cell)
  local input_matrix
  if type(matrix_input.permissions) == "table" then
    input_matrix = {}
    for i, p in ipairs(matrix_input.permissions) do
      if type(p) ~= "table" or type(p.role) ~= "string" or type(p.page_key) ~= "string" then
        return nil, errors.new("VALIDATION_FAILED", nil, { permissions = { "[" .. i .. "]: role/page_key zorunlu" } })
      end
      input_matrix[p.role] = input_matrix[p.role] or {}
      input_matrix[p.role][p.page_key] = p.can_access
    end
  else
    input_matrix = matrix_input.matrix or matrix_input
  end
  if type(input_matrix) ~= "table" then
    return nil, errors.new("VALIDATION_FAILED", nil, { matrix = { "nesne olmalı" } })
  end
  -- validation: bilinmeyen rol/page ve kilit
  for role, pages in pairs(input_matrix) do
    if not types.ROLE_SET[role] or type(pages) ~= "table" then
      return nil, errors.new("VALIDATION_FAILED", "Gecersiz rol", { role = { "gecersiz rol: " .. tostring(role) } })
    end
    for page_key, val in pairs(pages) do
      if not types.PAGE_SET[page_key] then
        return nil, errors.new("VALIDATION_FAILED", "Gecersiz sayfa", { page_key = { "gecersiz: " .. page_key } })
      end
      if type(val) ~= "boolean" then
        return nil, errors.new("VALIDATION_FAILED", "can_access boolean olmali", { can_access = { "boolean olmali" } })
      end
      if rbac_model.violates_lock(role, page_key, val) then
        return nil, errors.new("CONFLICT", "Admin rolunun rbac.matrix izni kapatilamaz")
      end
    end
  end

  local old_matrix
  local changes
  local ok, err = query.with_transaction(function()
    local locked, lerr = rbac_repo.lock_all()
    if not locked then return nil, lerr end
    local rows, rerr = rbac_repo.all()
    if not rows then return nil, rerr end
    old_matrix = rbac_model.from_rows(rows)
    -- merge
    local merged = {}
    for role, pages in pairs(old_matrix) do
      merged[role] = {}
      for k, v in pairs(pages) do merged[role][k] = v end
    end
    for role, pages in pairs(input_matrix) do
      merged[role] = merged[role] or {}
      for k, v in pairs(pages) do merged[role][k] = v end
    end
    changes = rbac_model.diff(old_matrix, merged)
    for _, ch in ipairs(changes) do
      local done, uerr = rbac_repo.upsert(ch.role, ch.page_key, ch.new)
      if not done then return nil, uerr end
    end
    return merged
  end)
  if not ok then return nil, err end
  if changes and #changes > 0 then
    _M.invalidate(nil)
    local audit_service = require("services.audit_service")
    local old_cells = {}
    local new_cells = {}
    for _, ch in ipairs(changes) do
      old_cells[#old_cells + 1] = { role = ch.role, page_key = ch.page_key, value = ch.old }
      new_cells[#new_cells + 1] = { role = ch.role, page_key = ch.page_key, value = ch.new }
    end
    audit_service.record("rbac.matrix.update", {
      entity_type = "rbac", status = "success",
      old_value = { cells = old_cells }, new_value = { cells = new_cells },
    })
  end
  return _M.matrix()
end

function _M.set_cell(identity, role, page_key, can_access)
  if not types.ROLE_SET[role] then
    return nil, errors.new("NOT_FOUND", "Rol bulunamadi")
  end
  if not types.PAGE_SET[page_key] then
    return nil, errors.new("NOT_FOUND", "Sayfa bulunamadi")
  end
  if type(can_access) ~= "boolean" then
    return nil, errors.new("VALIDATION_FAILED", "can_access boolean olmali", { can_access = { "boolean olmali" } })
  end
  if rbac_model.violates_lock(role, page_key, can_access) then
    return nil, errors.new("CONFLICT", "Admin rolunun rbac.matrix izni kapatilamaz")
  end
  local ok, res = _M.update_matrix(identity, { [role] = { [page_key] = can_access } })
  if not ok then return nil, res end
  return ok
end

return _M
