-- Todo HTTP handler'lari: query/body parse, validation, servis cagrisi
local validation = require("todo_shared.validation")
local errors = require("middleware.error_handler")
local todo_service = require("services.todo_service")
local todo_model = require("models.todo")

local _M = {}

local UUID_RE = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function valid_id(self)
  local id = self.params and self.params.id
  return type(id) == "string" and id:match(UUID_RE) ~= nil
end

local function parse_list_query()
  local clean, err = validation.validate(validation.schemas.todo_list_query, ngx.req.get_uri_args())
  if not clean then return nil, errors.validation(err) end
  if clean.sort and not todo_model.SORTABLE[clean.sort:gsub("^-", "")] then
    return nil, errors.validation({ sort = { "gecersiz siralama alani" } })
  end
  return clean, nil
end

function _M.list()
  local q, err = parse_list_query()
  if not q then return errors.respond(err) end
  local result, serr = todo_service.list(ngx.ctx.identity, q)
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result.items, meta = result.meta } }
end

function _M.get(self)
  if not valid_id(self) then
    return errors.respond(errors.new("TODO_NOT_FOUND", "Todo bulunamadi"))
  end
  local todo, err = todo_service.get(ngx.ctx.identity, self.params.id)
  if not todo then return errors.respond(err) end
  return { status = 200, json = { data = todo } }
end

function _M.create()
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, ferr = validation.validate(validation.schemas.todo_create, input)
  if not clean then return errors.respond(errors.validation(ferr)) end
  -- tags normalize is in service
  local todo, serr = todo_service.create(ngx.ctx.identity, clean)
  if not todo then return errors.respond(serr) end
  return { status = 201, json = { data = todo }, headers = { Location = "/api/v1/todos/" .. todo.id } }
end

function _M.replace(self)
  if not valid_id(self) then
    return errors.respond(errors.new("TODO_NOT_FOUND", "Todo bulunamadi"))
  end
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, ferr = validation.validate(validation.schemas.todo_update, input)
  if not clean then return errors.respond(errors.validation(ferr)) end
  local todo, serr = todo_service.replace(ngx.ctx.identity, self.params.id, clean)
  if not todo then return errors.respond(serr) end
  return { status = 200, json = { data = todo } }
end

function _M.patch(self)
  if not valid_id(self) then
    return errors.respond(errors.new("TODO_NOT_FOUND", "Todo bulunamadi"))
  end
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  if not next(input) then
    return errors.respond(errors.validation({ _ = { "en az bir alan gonderilmeli" } }))
  end
  local clean, ferr = validation.validate(validation.schemas.todo_patch, input)
  if not clean then return errors.respond(errors.validation(ferr)) end
  local has = false
  for _, k in ipairs(todo_model.MUTABLE) do if clean[k] ~= nil then has = true; break end end
  if not has then return errors.respond(errors.validation({ _ = { "en az bir alan gonderilmeli" } })) end
  local todo, serr = todo_service.patch(ngx.ctx.identity, self.params.id, clean)
  if not todo then return errors.respond(serr) end
  return { status = 200, json = { data = todo } }
end

function _M.delete(self)
  if not valid_id(self) then
    return errors.respond(errors.new("TODO_NOT_FOUND", "Todo bulunamadi"))
  end
  local ok, err = todo_service.delete(ngx.ctx.identity, self.params.id)
  if not ok then return errors.respond(err) end
  return { status = 204, layout = false }
end

function _M.stats()
  local user_id = ngx.req.get_uri_args().user_id
  if user_id ~= nil and not validation.is_uuid(user_id) then
    return errors.respond(errors.validation({ user_id = { "gecersiz UUID" } }))
  end
  local result, serr = todo_service.stats(ngx.ctx.identity, { user_id = user_id })
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result } }
end

return _M
