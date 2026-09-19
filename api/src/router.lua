-- Route tablosu ve middleware zinciri birlestirici
-- Zincir: cors -> logger -> audit_context -> auth -> authorization -> handler
local errors = require("middleware.error_handler")
local protocol = require("todo_shared.protocol")

local _M = {}

_M.API_PREFIX = "/api/v1"

function _M.chain(middlewares, handler)
  local n = #middlewares
  return function(self)
    return errors.guard(function()
      for i = 1, n do
        local res = middlewares[i](self)
        if res then return res end
      end
      return handler(self)
    end)
  end
end

-- Route tanimlari: method, path, handler, auth, page, name
-- Handler string "module#func" ise lazy require edilir

-- F18: liveness — DB'ye dokunmaz (DB kesintisinde restart döngüsü olmasın)
local function health()
  return { status = 200, json = { status = "ok", version = "0.1.0" } }
end

-- F18: readiness — DB SELECT 1 (timeout 1 sn) + shared dict erişilebilirlik
local function health_ready()
  local query = require("db.query")
  local ok = query.ping()
  local dict_ok = ngx.shared.metrics ~= nil and ngx.shared.jwt_denylist ~= nil
  if ok and dict_ok then
    return { status = 200, json = { status = "ready", db = "up" } }
  end
  return { status = 503, json = { status = "unavailable", db = ok and "up" or "down" } }
end

-- F18: Prometheus metin formatında sayaçlar (metrics shared dict, 00 §9)
local function metrics()
  local dict = ngx.shared.metrics
  local lines = {
    "# TYPE todo_http_requests_total counter",
    ("todo_http_requests_total %d"):format(dict and dict:get("req_total") or 0),
    ("todo_http_requests_by_class_total{class=\"2xx\"} %d"):format(dict and dict:get("req:2xx") or 0),
    ("todo_http_requests_by_class_total{class=\"4xx\"} %d"):format(dict and dict:get("req:4xx") or 0),
    ("todo_http_requests_by_class_total{class=\"5xx\"} %d"):format(dict and dict:get("req:5xx") or 0),
    "# TYPE todo_http_latency_ms_sum counter",
    ("todo_http_latency_ms_sum %.0f"):format(dict and dict:get("latency_sum_ms") or 0),
  }
  ngx.header["Content-Type"] = "text/plain; version=0.0.4"
  ngx.print(table.concat(lines, "\n") .. "\n")
  -- gövde doğrudan yazıldı; Lapis tekrar status/gövde yazmasın
  return { skip_render = true }
end

_M.ROUTES = {
  -- bare: yalnızca cors + logger (audit_context yok; probe'lar audit bağlamı üretmez)
  { method = "GET", path = "/health", handler = health, auth = false, bare = true, name = "health" },
  { method = "GET", path = "/health/ready", handler = health_ready, auth = false, bare = true, name = "health_ready" },
  { method = "GET", path = "/metrics", handler = metrics, auth = false, bare = true, name = "metrics" },
  { method = "POST", path = "/auth/login", handler = "handlers.auth#login", auth = false, name = "auth_login" },
  { method = "POST", path = "/auth/logout", handler = "handlers.auth#logout", auth = true, name = "auth_logout" },
  { method = "POST", path = "/auth/refresh", handler = "handlers.auth#refresh", auth = false, name = "auth_refresh" },
  { method = "POST", path = "/auth/forgot-password", handler = "handlers.auth#forgot_password",
    auth = false, name = "auth_forgot" },
  { method = "POST", path = "/auth/reset-password", handler = "handlers.auth#reset_password",
    auth = false, name = "auth_reset" },
  { method = "GET", path = "/auth/me", handler = "handlers.auth#me", auth = true, name = "auth_me" },
  -- todos: stats once
  { method = "GET", path = "/todos/stats", handler = "handlers.todos#stats",
    auth = true, page = "dashboard", name = "todos_stats" },
  { method = "GET", path = "/todos", handler = "handlers.todos#list",
    auth = true, page = "todos.list", name = "todos_list" },
  { method = "POST", path = "/todos", handler = "handlers.todos#create",
    auth = true, page = "todos.create", name = "todos_create" },
  { method = "GET", path = "/todos/:id", handler = "handlers.todos#get",
    auth = true, page = "todos.list", name = "todos_get" },
  { method = "PUT", path = "/todos/:id", handler = "handlers.todos#replace",
    auth = true, page = "todos.edit", name = "todos_replace" },
  { method = "PATCH", path = "/todos/:id", handler = "handlers.todos#patch",
    auth = true, page = "todos.edit", name = "todos_patch" },
  { method = "DELETE", path = "/todos/:id", handler = "handlers.todos#delete",
    auth = true, page = "todos.edit", name = "todos_delete" },
  -- users
  { method = "GET", path = "/users", handler = "handlers.users#list",
    auth = true, page = "users.list", name = "users_list" },
  { method = "POST", path = "/users", handler = "handlers.users#create",
    auth = true, page = "users.create", name = "users_create" },
  { method = "GET", path = "/users/:id", handler = "handlers.users#get",
    auth = true, page = "users.list", name = "users_get" },
  { method = "PUT", path = "/users/:id", handler = "handlers.users#update",
    auth = true, page = "users.create", name = "users_update" },
  { method = "DELETE", path = "/users/:id", handler = "handlers.users#delete",
    auth = true, page = "users.create", name = "users_delete" },
  -- rbac
  { method = "GET", path = "/rbac/pages", handler = "handlers.rbac#pages",
    auth = true, page = "rbac.matrix", name = "rbac_pages" },
  { method = "GET", path = "/rbac/matrix", handler = "handlers.rbac#matrix",
    auth = true, page = "rbac.matrix", name = "rbac_matrix_get" },
  { method = "PUT", path = "/rbac/matrix", handler = "handlers.rbac#update_matrix",
    auth = true, page = "rbac.matrix", name = "rbac_matrix_put" },
  { method = "PATCH", path = "/rbac/matrix/:role/:page_key", handler = "handlers.rbac#set_cell",
    auth = true, page = "rbac.matrix", name = "rbac_set_cell" },
  -- audit
  { method = "GET", path = "/audit/logs", handler = "handlers.audit#list",
    auth = true, page = "audit.logs", name = "audit_list" },
  { method = "GET", path = "/audit/logs/:id", handler = "handlers.audit#get",
    auth = true, page = "audit.logs", name = "audit_get" },
  { method = "GET", path = "/audit/stats", handler = "handlers.audit#stats",
    auth = true, page = "audit.logs", name = "audit_stats" },
  { method = "GET", path = "/audit/export", handler = "handlers.audit#export",
    auth = true, page = "audit.logs", name = "audit_export" },
  -- swagger
  { method = "GET", path = "/swagger.json", handler = "handlers.swagger#spec_json",
    auth = false, name = "swagger_json" },
  { method = "GET", path = "/swagger", handler = "handlers.swagger#ui", auth = false, name = "swagger_ui" },
}

local function resolve_handler(h)
  if type(h) == "function" then return h end
  if type(h) == "string" then
    local mod, func = h:match("^([^#]+)#([^#]+)$")
    if mod and func then
      local m = require(mod)
      return m[func]
    else
      return require(h)
    end
  end
  return h
end

function _M.route_list()
  local list = {}
  for _, r in ipairs(_M.ROUTES) do
    list[#list + 1] = {
      method = r.method,
      path = _M.API_PREFIX .. r.path,
      auth = r.auth,
      page = r.page,
      name = r.name,
    }
  end
  return list
end

-- Desteklenmeyen metot → 405 + Allow (Lapis respond_to on_invalid_method)
local function method_not_allowed(allow)
  return function()
    local body = protocol.error_body({ code = "BAD_REQUEST", message = "Bu metot desteklenmiyor" },
      ngx.ctx.req_id or "-")
    return { status = 405, json = body, headers = { Allow = allow } }
  end
end

function _M.register(app)
  local respond_to = require("lapis.application").respond_to
  local cors = require("middleware.cors")
  local logger = require("middleware.logger")
  local audit_context = require("middleware.audit_context")
  local auth = require("middleware.auth")
  -- authorization yüklenemezse başlangıç düşer (fail-closed; izin veren stub yok)
  local authorization = require("middleware.authorization")

  -- grupla: path -> method -> route (sıra korunur: literal path'ler önce, 00 #14)
  local grouped, order = {}, {}
  for _, r in ipairs(_M.ROUTES) do
    local full = _M.API_PREFIX .. r.path
    if not grouped[full] then grouped[full] = {}; order[#order + 1] = full end
    grouped[full][r.method] = r
  end

  for _, path in ipairs(order) do
    local actions, allow = {}, {}
    for method, route in pairs(grouped[path]) do
      local mws = { cors.handle, logger.handle }
      if not route.bare then mws[#mws + 1] = audit_context.handle end
      if route.auth then mws[#mws + 1] = auth.required end
      if route.page then mws[#mws + 1] = authorization.requires(route.page) end
      actions[method] = _M.chain(mws, assert(resolve_handler(route.handler), route.name))
      allow[#allow + 1] = method
    end
    -- OPTIONS preflight: yalnızca cors
    actions.OPTIONS = function(self)
      return cors.handle(self) or { status = 204, layout = false }
    end
    table.sort(allow)
    actions.on_invalid_method = _M.chain({ logger.handle }, method_not_allowed(table.concat(allow, ", ")))
    app:match(path, respond_to(actions))
  end
end

return _M
