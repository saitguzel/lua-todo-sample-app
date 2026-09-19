-- OpenAPI 3.1 spec: Lua tablosu, shared enum'lardan uretilir
local cjson = require("cjson.safe")
local types = require("todo_shared.types")
local protocol = require("todo_shared.protocol")
local config = require("config")

local _M = {}
local EMPTY = cjson.empty_array

local function ref(name)
  return { ["$ref"] = "#/components/schemas/" .. name }
end

local function json_body(schema_name, example)
  return { required = true, content = { ["application/json"] = { schema = ref(schema_name), example = example } } }
end

-- Tek içerik tipli yanıt nesnesi
local function resp(description, schema, ctype)
  return { description = description, content = { [ctype or "application/json"] = { schema = schema } } }
end

local function data_of(schema)
  return { type = "object", required = { "data" }, properties = { data = schema } }
end

local function page_of(item_schema_name)
  return {
    type = "object", required = { "data", "meta" },
    properties = { data = { type = "array", items = ref(item_schema_name) }, meta = ref("PaginationMeta") },
  }
end

local function qp(name)
  return { ["$ref"] = "#/components/parameters/" .. name }
end

local function op(o)
  o.responses = o.responses or {}
  -- Yetki gereksinimi hem insan (description) hem makine (x-page-key) için
  local pk = o["x-page-key"]
  if pk then
    o.description = (o.description and (o.description .. "\n\n") or "") .. "Yetki: " .. pk
  end
  if o.errors then
    for _, code in ipairs(o.errors) do
      local status = tostring(protocol.http_status(code))
      if not o.responses[status] then
        o.responses[status] = { ["$ref"] = "#/components/responses/" .. code }
      end
    end
    o.errors = nil
  end
  -- always include 500 and 503 if not open
  if not o.responses["500"] then o.responses["500"] = { ["$ref"] = "#/components/responses/INTERNAL_ERROR" } end
  if not o.responses["503"] and o.tags and o.tags[1] ~= "system" then
    o.responses["503"] = { ["$ref"] = "#/components/responses/DB_UNAVAILABLE" }
  end
  return o
end

local TAGS = { type = "array", maxItems = 20, uniqueItems = true,
  items = { type = "string", minLength = 1, maxLength = 50 } }
local NSTR = { type = { "string", "null" } }

local function components()
  local schemas = {
    Error = {
      type = "object", required = { "code", "message" },
      properties = {
        code = { type = "string", enum = protocol.CODE_LIST },
        message = { type = "string" },
        details = { type = { "object", "null" } },
        req_id = ref("Uuid"),
      },
    },
    ErrorResponse = { type = "object", required = { "error" }, properties = { error = ref("Error") } },
    PaginationMeta = {
      type = "object", required = { "page", "per_page", "total", "total_pages" },
      properties = {
        page = { type = "integer", minimum = 1 },
        per_page = { type = "integer", minimum = 1, maximum = 100 },
        total = { type = "integer", minimum = 0 },
        total_pages = { type = "integer", minimum = 0 },
      },
    },
    Uuid = { type = "string", format = "uuid", pattern = "^[0-9a-fA-F-]{36}$" },
    Timestamp = { type = "string", format = "date-time" },
    Role = { type = "string", enum = types.ROLES },
    TodoStatus = { type = "string", enum = types.TODO_STATUS },
    TodoPriority = { type = "string", enum = types.TODO_PRIORITY },
    PageKey = { type = "string", enum = types.PAGES },
    User = {
      type = "object",
      required = { "id", "email", "role", "is_active", "created_at", "updated_at" },
      properties = {
        id = ref("Uuid"), email = { type = "string", format = "email" },
        full_name = { type = { "string", "null" }, maxLength = 255 },
        role = ref("Role"), is_active = { type = "boolean" },
        last_login_at = { type = { "string", "null" }, format = "date-time" },
        created_at = ref("Timestamp"), updated_at = ref("Timestamp"),
      },
    },
    Permissions = {
      type = "object",
      propertyNames = ref("PageKey"),
      additionalProperties = { type = "boolean" },
      example = { dashboard = true, ["todos.list"] = true },
    },
    Me = {
      type = "object", required = { "user", "permissions" },
      properties = { user = ref("User"), permissions = ref("Permissions") },
    },
    UserCreate = {
      type = "object", required = { "email", "password", "role" },
      properties = {
        email = { type = "string", format = "email", maxLength = 255 },
        password = { type = "string", minLength = 8, maxLength = 128, writeOnly = true, example = "Ornek123!" },
        full_name = { type = { "string", "null" }, maxLength = 255 },
        role = ref("Role"), is_active = { type = "boolean" },
      },
    },
    UserUpdate = {
      type = "object", description = "Tüm alanlar opsiyonel; gönderilmeyen alan değişmez",
      properties = {
        email = { type = "string", format = "email" },
        full_name = NSTR,
        role = ref("Role"), is_active = { type = "boolean" },
        password = { type = "string", minLength = 8, maxLength = 128, writeOnly = true },
      },
    },
    Todo = {
      type = "object",
      required = { "id", "user_id", "title", "status", "priority", "tags", "created_at", "updated_at" },
      properties = {
        id = ref("Uuid"), user_id = ref("Uuid"),
        title = { type = "string", minLength = 1, maxLength = 255, example = "Sunum hazirla" },
        description = { type = { "string", "null" }, maxLength = 10000 },
        status = ref("TodoStatus"), priority = ref("TodoPriority"),
        due_date = { type = { "string", "null" }, format = "date-time" },
        tags = TAGS,
        created_at = ref("Timestamp"), updated_at = ref("Timestamp"),
        completed_at = { type = { "string", "null" }, format = "date-time" },
        owner_email = { type = "string", format = "email", description = "Yalnizca admin listesinde" },
      },
    },
    TodoCreate = {
      type = "object", required = { "title" },
      properties = {
        title = { type = "string", minLength = 1, maxLength = 255 },
        description = { type = { "string", "null" }, maxLength = 10000 },
        status = ref("TodoStatus"), priority = ref("TodoPriority"),
        due_date = { type = { "string", "null" }, format = "date-time" },
        tags = TAGS,
        user_id = ref("Uuid"),
      },
      additionalProperties = false,
    },
    TodoReplace = {
      type = "object", required = { "title" },
      description = "Tam temsil: eksik alanlar varsayılana döner "
        .. "(status=pending, priority=medium, description/due_date=null, tags=[])",
      properties = {
        title = { type = "string", minLength = 1, maxLength = 255 },
        description = NSTR,
        status = ref("TodoStatus"), priority = ref("TodoPriority"),
        due_date = { type = { "string", "null" }, format = "date-time" },
        tags = TAGS,
      },
      additionalProperties = false,
    },
    TodoPatch = {
      type = "object",
      properties = {
        title = { type = "string", minLength = 1, maxLength = 255 },
        description = NSTR,
        status = ref("TodoStatus"), priority = ref("TodoPriority"),
        due_date = { type = { "string", "null" }, format = "date-time" },
        tags = TAGS,
      },
      minProperties = 1, additionalProperties = false,
    },
    TodoStats = {
      type = "object",
      properties = {
        total = { type = "integer" },
        by_status = { type = "object", properties = {
          pending = { type = "integer" }, in_progress = { type = "integer" }, completed = { type = "integer" },
        } },
        by_priority = { type = "object" },
        overdue = { type = "integer" }, due_today = { type = "integer" }, due_week = { type = "integer" },
        completion_rate = { type = "number" },
        completed_last_7_days = { type = "array", items = { type = "object", properties = {
          day = { type = "string" }, count = { type = "integer" } } } },
        scope = { type = "string", enum = { "user", "all" } },
      },
    },
    LoginRequest = {
      type = "object", required = { "email", "password" },
      properties = { email = { type = "string", format = "email" }, password = { type = "string", maxLength = 128 } },
    },
    TokenPair = {
      type = "object",
      properties = {
        access_token = { type = "string" }, refresh_token = { type = "string" },
        token_type = { type = "string", const = "Bearer" }, expires_in = { type = "integer" },
        refresh_expires_in = { type = "integer" }, user = ref("User"), permissions = ref("Permissions"),
      },
    },
    RefreshRequest = { type = "object", required = { "refresh_token" },
      properties = { refresh_token = { type = "string" } } },
    LogoutRequest = { type = "object", properties = { refresh_token = { type = "string" } } },
    ForgotPasswordRequest = { type = "object", required = { "email" },
      properties = { email = { type = "string", format = "email" } } },
    ResetPasswordRequest = { type = "object", required = { "token", "new_password" }, properties = {
      token = { type = "string", pattern = "^[0-9a-fA-F]+$" }, new_password = { type = "string", minLength = 8 } } },
    MessageResponse = { type = "object", required = { "data" },
      properties = { data = { type = "object", properties = { message = { type = "string" } } } } },
    RbacPage = {
      type = "object", properties = {
        key = { type = "string" }, label = { type = "string" }, group = { type = "string" },
        locked_for = { type = "array", items = { type = "string" } },
      },
    },
    RbacMatrix = {
      type = "object",
      properties = {
        roles = { type = "array", items = ref("Role") },
        pages = { type = "array", items = ref("PageKey") },
        matrix = { type = "object",
          additionalProperties = { type = "object", additionalProperties = { type = "boolean" } } },
      },
    },
    RbacMatrixUpdate = {
      type = "object", properties = { matrix = { type = "object", description = "Kismi gonderim kabul edilir" } },
      description = "Kismi matris gonderilebilir, eksik hucre degismez",
    },
    RbacCellUpdate = { type = "object", required = { "can_access" },
      properties = { can_access = { type = "boolean" } } },
    AuditLog = {
      type = "object",
      properties = {
        id = { type = "integer" }, user_id = NSTR, user_email = NSTR,
        action = { type = "string" }, entity_type = NSTR, entity_id = NSTR,
        old_value = { type = { "object", "null" } }, new_value = { type = { "object", "null" } },
        ip_address = NSTR, user_agent = NSTR,
        status = { type = "string" }, error_message = NSTR, created_at = ref("Timestamp"),
      },
    },
    AuditLogSummary = {
      type = "object",
      properties = {
        id = { type = "integer" }, created_at = ref("Timestamp"), user_email = NSTR,
        action = { type = "string" }, entity_type = NSTR, entity_id = NSTR,
        status = { type = "string" }, ip_address = NSTR, user_agent = NSTR,
      },
    },
    AuditStats = {
      type = "object",
      required = { "range", "total", "by_status", "by_action", "by_day", "top_users", "failed_logins_24h" },
      properties = {
        range = { type = "object", properties = { from = ref("Timestamp"), to = ref("Timestamp") } },
        total = { type = "integer" },
        by_status = { type = "object",
          properties = { success = { type = "integer" }, failure = { type = "integer" } } },
        by_action = { type = "array", items = { type = "object", properties = {
          action = { type = "string" }, count = { type = "integer" } } } },
        by_day = { type = "array", items = { type = "object", properties = {
          day = { type = "string", format = "date" }, count = { type = "integer" } } } },
        top_users = { type = "array", items = { type = "object", properties = {
          user_email = { type = "string" }, count = { type = "integer" } } } },
        failed_logins_24h = { type = "integer" },
      },
    },
    Health = {
      type = "object",
      properties = { status = { type = "string", enum = { "ok" } }, version = { type = "string" } },
    },
    Readiness = {
      type = "object",
      properties = {
        status = { type = "string", enum = { "ready", "unavailable" } },
        db = { type = "string", enum = { "up", "down" } },
      },
    },
  }
  local parameters = {
    IdPath = { name = "id", ["in"] = "path", required = true, schema = ref("Uuid") },
    AuditIdPath = { name = "id", ["in"] = "path", required = true, schema = { type = "integer", minimum = 1 } },
    Page = { name = "page", ["in"] = "query", schema = { type = "integer", minimum = 1, default = 1 } },
    PerPage = { name = "per_page", ["in"] = "query",
      schema = { type = "integer", minimum = 1, maximum = 100, default = 20 } },
    Sort = { name = "sort", ["in"] = "query", schema = { type = "string" }, description = "Endpoint bazli whitelist" },
    From = { name = "from", ["in"] = "query", schema = { type = "string", format = "date-time" },
      description = "Varsayılan: to − 7 gün; from–to en fazla 90 gün" },
    To = { name = "to", ["in"] = "query", schema = { type = "string", format = "date-time" },
      description = "Varsayılan: şimdi" },
    UserIdQuery = { name = "user_id", ["in"] = "query", schema = ref("Uuid"),
      description = "Yalnızca admin için anlamlı; todouser'da yok sayılır" },
    Q = { name = "q", ["in"] = "query", schema = { type = "string", maxLength = 100 },
      description = "Metin araması (ILIKE)" },
    TodoStatusQuery = { name = "status", ["in"] = "query", schema = ref("TodoStatus") },
    TodoPriorityQuery = { name = "priority", ["in"] = "query", schema = ref("TodoPriority") },
    Tag = { name = "tag", ["in"] = "query", schema = { type = "string", maxLength = 50 } },
    DueBefore = { name = "due_before", ["in"] = "query", schema = { type = "string", format = "date-time" } },
    DueAfter = { name = "due_after", ["in"] = "query", schema = { type = "string", format = "date-time" } },
    RoleQuery = { name = "role", ["in"] = "query", schema = ref("Role") },
    IsActiveQuery = { name = "is_active", ["in"] = "query", schema = { type = "string", enum = { "true", "false" } } },
    Action = { name = "action", ["in"] = "query", schema = { type = "string", maxLength = 100 },
      description = "Tam ad veya önek: `auth.*`" },
    AuditStatus = { name = "status", ["in"] = "query", schema = { type = "string", enum = { "success", "failure" } } },
    EntityType = { name = "entity_type", ["in"] = "query", schema = { type = "string", maxLength = 50 } },
    EntityId = { name = "entity_id", ["in"] = "query", schema = { type = "string", maxLength = 100 } },
    UserEmail = { name = "user_email", ["in"] = "query", schema = { type = "string", maxLength = 255 } },
    Ip = { name = "ip", ["in"] = "query", schema = { type = "string", maxLength = 45 } },
  }
  local responses = {}
  for _, code in ipairs(protocol.CODE_LIST) do
    responses[code] = {
      description = protocol.message(code),
      content = { ["application/json"] = { schema = ref("ErrorResponse"), example = { error = {
        code = code, message = protocol.message(code), req_id = "5b1d9c1e-7f7a-4c1b-9a8e-3f2d8e1c0a11" } } } },
    }
  end
  responses.RATE_LIMITED.headers = { ["Retry-After"] = { schema = { type = "integer" } } }
  local securitySchemes = {
    bearerAuth = { type = "http", scheme = "bearer", bearerFormat = "JWT",
      description = "POST /auth/login'den alinan access_token" },
  }
  return { schemas = schemas, parameters = parameters, responses = responses, securitySchemes = securitySchemes }
end

local function paths()
  local p = {}
  p["/auth/login"] = {
    post = op({
      tags = { "auth" }, operationId = "login", summary = "Giris yap",
      security = EMPTY,
      requestBody = json_body("LoginRequest", { email = "admin@todoapp.local", password = "Admin123!" }),
      responses = { ["200"] = resp("Basarili", data_of(ref("TokenPair"))) },
      errors = { "VALIDATION_FAILED", "INVALID_CREDENTIALS", "ACCOUNT_DISABLED", "RATE_LIMITED" },
    }),
  }
  p["/auth/logout"] = {
    post = op({
      tags = { "auth" }, operationId = "logout", summary = "Cikis yap",
      description = "Gövde opsiyonel; refresh_token verilirse o da iptal edilir.",
      requestBody = { required = false, content = { ["application/json"] = {
        schema = ref("LogoutRequest"), example = { refresh_token = "eyJ..." } } } },
      responses = { ["204"] = { description = "Cikis yapildi" } },
      errors = { "BAD_REQUEST", "VALIDATION_FAILED", "UNAUTHORIZED", "TOKEN_EXPIRED", "TOKEN_REVOKED" },
    }),
  }
  p["/auth/refresh"] = {
    post = op({
      tags = { "auth" }, operationId = "refreshToken", summary = "Token yenile",
      security = EMPTY,
      requestBody = json_body("RefreshRequest", { refresh_token = "eyJ..." }),
      responses = { ["200"] = resp("Yenilendi", data_of(ref("TokenPair"))) },
      errors = { "VALIDATION_FAILED", "UNAUTHORIZED", "TOKEN_EXPIRED", "TOKEN_REVOKED", "ACCOUNT_DISABLED" },
    }),
  }
  p["/auth/forgot-password"] = {
    post = op({
      tags = { "auth" }, operationId = "forgotPassword", summary = "Parola sifirlama istegi",
      security = EMPTY,
      requestBody = json_body("ForgotPasswordRequest", { email = "user@todoapp.local" }),
      responses = { ["202"] = resp("Istek alindi", ref("MessageResponse")) },
      errors = { "VALIDATION_FAILED", "RATE_LIMITED" },
    }),
  }
  p["/auth/reset-password"] = {
    post = op({
      tags = { "auth" }, operationId = "resetPassword", summary = "Parola sifirla",
      security = EMPTY,
      requestBody = json_body("ResetPasswordRequest", { token = string.rep("a", 64), new_password = "YeniPass123!" }),
      responses = { ["204"] = { description = "Sifirlandi" } },
      errors = { "VALIDATION_FAILED", "RESET_TOKEN_INVALID" },
    }),
  }
  p["/auth/me"] = {
    get = op({
      tags = { "auth" }, operationId = "getMe", summary = "Mevcut kullanici",
      responses = { ["200"] = resp("Kullanici", data_of(ref("Me"))) },
      errors = { "UNAUTHORIZED", "USER_NOT_FOUND" },
    }),
  }
  p["/todos"] = {
    get = op({
      tags = { "todos" }, operationId = "listTodos", summary = "Todo listele",
      ["x-page-key"] = "todos.list",
      parameters = { qp("TodoStatusQuery"), qp("TodoPriorityQuery"), qp("Q"), qp("Tag"), qp("DueBefore"),
        qp("DueAfter"), qp("UserIdQuery"), qp("Page"), qp("PerPage"), qp("Sort") },
      responses = { ["200"] = resp("Liste", page_of("Todo")) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
    post = op({
      tags = { "todos" }, operationId = "createTodo", summary = "Todo olustur",
      ["x-page-key"] = "todos.create",
      requestBody = json_body("TodoCreate", { title = "Sut al" }),
      responses = { ["201"] = {
        description = "Olusturuldu",
        content = { ["application/json"] = { schema = data_of(ref("Todo")) } },
        headers = { Location = { schema = { type = "string" } } },
      } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "USER_NOT_FOUND" },
    }),
  }
  p["/todos/stats"] = {
    get = op({
      tags = { "todos" }, operationId = "getTodoStats", summary = "Todo istatistikleri",
      ["x-page-key"] = "dashboard",
      parameters = { qp("UserIdQuery") },
      responses = { ["200"] = resp("Stats", data_of(ref("TodoStats"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
  }
  p["/todos/{id}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "todos" }, operationId = "getTodo", summary = "Todo getir",
      ["x-page-key"] = "todos.list",
      responses = { ["200"] = resp("Todo", data_of(ref("Todo"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "TODO_NOT_FOUND" },
    }),
    put = op({
      tags = { "todos" }, operationId = "replaceTodo", summary = "Todo degistir",
      ["x-page-key"] = "todos.edit",
      requestBody = json_body("TodoReplace", { title = "Yeni baslik", priority = "high" }),
      responses = { ["200"] = resp("Guncellendi", data_of(ref("Todo"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "TODO_NOT_FOUND", "VALIDATION_FAILED" },
    }),
    patch = op({
      tags = { "todos" }, operationId = "patchTodo", summary = "Todo kismi guncelle",
      ["x-page-key"] = "todos.edit",
      requestBody = json_body("TodoPatch", { status = "completed" }),
      responses = { ["200"] = resp("Guncellendi", data_of(ref("Todo"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "TODO_NOT_FOUND", "VALIDATION_FAILED" },
    }),
    delete = op({
      tags = { "todos" }, operationId = "deleteTodo", summary = "Todo sil",
      ["x-page-key"] = "todos.edit",
      responses = { ["204"] = { description = "Silindi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "TODO_NOT_FOUND" },
    }),
  }
  p["/users"] = {
    get = op({
      tags = { "users" }, operationId = "listUsers", summary = "Kullanici listele",
      ["x-page-key"] = "users.list",
      parameters = { qp("Q"), qp("RoleQuery"), qp("IsActiveQuery"), qp("Page"), qp("PerPage"), qp("Sort") },
      responses = { ["200"] = resp("Liste", page_of("User")) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
    post = op({
      tags = { "users" }, operationId = "createUser", summary = "Kullanici olustur",
      ["x-page-key"] = "users.create",
      requestBody = json_body("UserCreate",
        { email = "yeni@todoapp.local", password = "Ornek123!", role = "todouser" }),
      responses = { ["201"] = resp("Olusturuldu", data_of(ref("User"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "EMAIL_TAKEN", "VALIDATION_FAILED" },
    }),
  }
  p["/users/{id}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "users" }, operationId = "getUser", summary = "Kullanici getir",
      ["x-page-key"] = "users.list",
      responses = { ["200"] = resp("Kullanici", data_of(ref("User"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "USER_NOT_FOUND" },
    }),
    put = op({
      tags = { "users" }, operationId = "updateUser", summary = "Kullanici guncelle",
      ["x-page-key"] = "users.create",
      requestBody = json_body("UserUpdate", { full_name = "Yeni Ad", is_active = true }),
      responses = { ["200"] = resp("Guncellendi", data_of(ref("User"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "USER_NOT_FOUND", "EMAIL_TAKEN", "LAST_ADMIN",
        "SELF_ACTION_FORBIDDEN", "VALIDATION_FAILED" },
    }),
    delete = op({
      tags = { "users" }, operationId = "deleteUser", summary = "Kullanici sil",
      ["x-page-key"] = "users.create",
      responses = { ["204"] = { description = "Silindi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "USER_NOT_FOUND", "LAST_ADMIN", "SELF_ACTION_FORBIDDEN" },
    }),
  }
  p["/rbac/pages"] = {
    get = op({
      tags = { "rbac" }, operationId = "listRbacPages", summary = "Sayfalar",
      ["x-page-key"] = "rbac.matrix",
      responses = { ["200"] = resp("Sayfalar", data_of({ type = "array", items = ref("RbacPage") })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
  }
  p["/rbac/matrix"] = {
    get = op({
      tags = { "rbac" }, operationId = "getRbacMatrix", summary = "Matris getir",
      ["x-page-key"] = "rbac.matrix",
      responses = { ["200"] = resp("Matris", data_of(ref("RbacMatrix"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
    put = op({
      tags = { "rbac" }, operationId = "updateRbacMatrix", summary = "Matris guncelle",
      ["x-page-key"] = "rbac.matrix",
      requestBody = json_body("RbacMatrixUpdate", { matrix = { admin = { dashboard = true } } }),
      responses = { ["200"] = resp("Guncellendi", data_of(ref("RbacMatrix"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONFLICT", "VALIDATION_FAILED" },
    }),
  }
  p["/rbac/matrix/{role}/{page_key}"] = {
    parameters = {
      { name = "role", ["in"] = "path", required = true, schema = ref("Role") },
      { name = "page_key", ["in"] = "path", required = true, schema = ref("PageKey") },
    },
    patch = op({
      tags = { "rbac" }, operationId = "setRbacCell", summary = "Hucre guncelle",
      ["x-page-key"] = "rbac.matrix",
      requestBody = json_body("RbacCellUpdate", { can_access = true }),
      responses = { ["200"] = resp("Guncellendi", data_of(ref("RbacMatrix"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND", "CONFLICT", "VALIDATION_FAILED" },
    }),
  }
  p["/audit/logs"] = {
    get = op({
      tags = { "audit" }, operationId = "listAuditLogs", summary = "Denetim kayitlari",
      ["x-page-key"] = "audit.logs",
      parameters = { qp("Action"), qp("AuditStatus"), qp("EntityType"), qp("EntityId"), qp("UserIdQuery"),
        qp("UserEmail"), qp("Ip"), qp("From"), qp("To"), qp("Page"), qp("PerPage") },
      responses = { ["200"] = resp("Liste", page_of("AuditLogSummary")) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
  }
  p["/audit/logs/{id}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/AuditIdPath" } },
    get = op({
      tags = { "audit" }, operationId = "getAuditLog", summary = "Denetim detayi",
      ["x-page-key"] = "audit.logs",
      responses = { ["200"] = resp("Kayit", data_of(ref("AuditLog"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND" },
    }),
  }
  p["/audit/stats"] = {
    get = op({
      tags = { "audit" }, operationId = "getAuditStats", summary = "Denetim istatistikleri",
      ["x-page-key"] = "audit.logs",
      parameters = { qp("Action"), qp("AuditStatus"), qp("EntityType"), qp("EntityId"), qp("UserIdQuery"),
        qp("UserEmail"), qp("Ip"), qp("From"), qp("To") },
      responses = { ["200"] = resp("Stats", data_of(ref("AuditStats"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
  }
  p["/audit/export"] = {
    get = op({
      tags = { "audit" }, operationId = "exportAuditLogs", summary = "Denetim CSV export",
      ["x-page-key"] = "audit.logs",
      parameters = { qp("Action"), qp("AuditStatus"), qp("EntityType"), qp("EntityId"), qp("UserIdQuery"),
        qp("UserEmail"), qp("Ip"), qp("From"), qp("To") },
      responses = { ["200"] = resp("CSV", { type = "string", format = "binary" }, "text/csv") },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
  }
  p["/health"] = {
    get = {
      tags = { "system" }, operationId = "getHealth", summary = "Liveness (DB'ye dokunmaz)",
      security = EMPTY,
      responses = { ["200"] = resp("OK", ref("Health")) },
    },
  }
  p["/health/ready"] = {
    get = {
      tags = { "system" }, operationId = "getReadiness", summary = "Readiness (DB SELECT 1)",
      security = EMPTY,
      responses = {
        ["200"] = resp("Hazır", ref("Readiness")),
        ["503"] = resp("Hazır değil", ref("Readiness")),
      },
    },
  }
  p["/metrics"] = {
    get = {
      tags = { "system" }, operationId = "getMetrics", summary = "Prometheus sayaçları",
      description = "Prod'da proxy tarafından dışarıya kapatılır (403).",
      security = EMPTY,
      responses = {
        ["200"] = resp("Prometheus metin formatı", { type = "string" }, "text/plain"),
        ["403"] = { description = "Proxy üzerinden erişim reddedildi" },
      },
    },
  }
  p["/swagger.json"] = {
    get = {
      tags = { "system" }, operationId = "getOpenApiSpec", summary = "OpenAPI spec",
      security = EMPTY,
      responses = { ["200"] = resp("Spec", { type = "object" }) },
    },
  }
  p["/swagger"] = {
    get = {
      tags = { "system" }, operationId = "getSwaggerUi", summary = "Swagger UI",
      security = EMPTY,
      responses = { ["200"] = resp("HTML", { type = "string" }, "text/html") },
    },
  }
  return p
end

function _M.build()
  local cfg = config.get()
  local base_url = "http://localhost:28080"
  local env_desc = "development"
  if cfg then
    base_url = cfg.app and cfg.app.base_url or cfg.APP_BASE_URL or base_url
    env_desc = cfg.app and cfg.app.env or cfg.APP_ENV or env_desc
  end
  local comps = components()
  return {
    openapi = "3.1.0",
    info = {
      title = "Todo API",
      version = "0.1.0",
      description = "OpenResty + Lapis tabanli Todo REST API. Tum yanitlar JSON zarfi kullanir.",
      license = { name = "MIT", identifier = "MIT" },
    },
    jsonSchemaDialect = "https://spec.openapis.org/oas/3.1/dialect/base",
    servers = { { url = base_url .. "/api/v1", description = env_desc } },
    security = { { bearerAuth = EMPTY } },
    tags = {
      { name = "auth", description = "Kimlik dogrulama" },
      { name = "todos", description = "Gorevler" },
      { name = "users", description = "Kullanici yonetimi (admin)" },
      { name = "rbac", description = "Rol-sayfa izin matrisi (admin)" },
      { name = "audit", description = "Denetim kayitlari (admin)" },
      { name = "system", description = "Saglik ve dokumantasyon" },
    },
    components = {
      securitySchemes = comps.securitySchemes,
      schemas = comps.schemas,
      parameters = comps.parameters,
      responses = comps.responses,
    },
    paths = paths(),
  }
end

return _M
