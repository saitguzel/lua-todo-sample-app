-- RBAC handler'lari: pages, matrix, update, set_cell
local validation = require("todo_shared.validation")
local errors = require("middleware.error_handler")
local rbac_service = require("services.rbac_service")
local config = require("config")

local _M = {}

function _M.pages()
  local pages = rbac_service.pages()
  return { status = 200, json = { data = pages } }
end

function _M.matrix()
  local mat, err = rbac_service.matrix()
  if not mat then return errors.respond(err) end
  local ttl = config.get() and config.get().rbac_cache_ttl or 60
  return { status = 200, json = { data = mat, meta = { cache_ttl = ttl } } }
end

function _M.update_matrix()
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  -- testte matrix seklinde gelebilir: { matrix: {...}} veya { permissions: [...] } veya dogrudan
  local res, serr = rbac_service.update_matrix(ngx.ctx.identity, input)
  if not res then return errors.respond(serr) end
  local ttl = config.get() and config.get().rbac_cache_ttl or 60
  return { status = 200, json = { data = res, meta = { cache_ttl = ttl } } }
end

function _M.set_cell(self)
  local role = self.params and self.params.role
  local page_key = self.params and self.params.page_key
  if not role or not page_key then
    return errors.respond(errors.new("NOT_FOUND", "Kaynak bulunamadi"))
  end
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, ferr = validation.validate(validation.schemas.rbac_cell, input)
  if not clean then return errors.respond(errors.validation(ferr)) end
  local res, serr = rbac_service.set_cell(ngx.ctx.identity, role, page_key, clean.can_access)
  if not res then return errors.respond(serr) end
  local ttl = config.get() and config.get().rbac_cache_ttl or 60
  return { status = 200, json = { data = res, meta = { cache_ttl = ttl } } }
end

return _M
