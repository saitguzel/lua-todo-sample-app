-- Uygulama konfigürasyonu: env'den okunur, doğrulanır, immutable
-- _FILE desteği ve cross_validate ile prod kontrolleri içerir.
local _M = {}

_M.current = nil

local SPEC = {
  APP_ENV = { type = "enum", values = { "development", "test", "production" }, default = "development" },
  APP_PORT = { type = "int", default = 8080, min = 1, max = 65535 },
  APP_BASE_URL = { type = "url", default = "http://localhost:28080" },
  WEB_BASE_URL = { type = "url", default = "http://localhost:28000" },
  DB_HOST = { type = "string", default = "postgres", required = true },
  DB_PORT = { type = "int", default = 5432, min = 1, max = 65535 },
  DB_NAME = { type = "string", default = "todo", required = true },
  DB_USER = { type = "string", default = "todo", required = true },
  DB_PASSWORD = { type = "string", required = true, secret = true },
  DB_SSL = { type = "bool", default = false },
  DB_POOL_SIZE = { type = "int", default = 20, min = 1, max = 200 },
  DB_POOL_IDLE_TIMEOUT_MS = { type = "int", default = 60000, min = 1000 },
  DB_CONNECT_TIMEOUT_MS = { type = "int", default = 3000, min = 100 },
  DB_QUERY_TIMEOUT_MS = { type = "int", default = 10000, min = 1000 },
  JWT_SECRET = { type = "string", required = true, secret = true, min_len = 32 },
  JWT_ISSUER = { type = "string", default = "todo-api" },
  JWT_ACCESS_TTL = { type = "int", default = 900, min = 60 },
  JWT_REFRESH_TTL = { type = "int", default = 604800, min = 3600 },
  ARGON2_T_COST = { type = "int", default = 3, min = 1 },
  ARGON2_M_COST = { type = "int", default = 12, min = 10, max = 20 },
  ARGON2_PARALLELISM = { type = "int", default = 1, min = 1 },
  PASSWORD_RESET_TTL = { type = "int", default = 3600, min = 60 },
  LOGIN_RATE_LIMIT = { type = "int", default = 5, min = 1, max = 1000 },
  SMTP_HOST = { type = "string", default = "mailhog" },
  SMTP_PORT = { type = "int", default = 1025, min = 1, max = 65535 },
  SMTP_USER = { type = "string", default = "" },
  SMTP_PASSWORD = { type = "string", default = "", secret = true },
  SMTP_FROM = { type = "email", default = "no-reply@todoapp.local" },
  SMTP_TLS = { type = "bool", default = false },
  CORS_ORIGINS = { type = "csv", default = "http://localhost:28000,http://127.0.0.1:28000" },
  TRUSTED_PROXIES = { type = "csv", default = "127.0.0.1" },
  LOG_FORMAT = { type = "enum", values = { "json", "text" }, default = "json" },
  LOG_LEVEL = { type = "enum", values = { "debug", "info", "warn", "error" }, default = "info" },
  AUDIT_LOG_RETENTION_DAYS = { type = "int", default = 30, min = 1 },
  AUDIT_CLEANUP_ENABLED = { type = "bool", default = true },
  AUDIT_CLEANUP_HOUR = { type = "int", default = 3, min = 0, max = 23 },
  AUDIT_CLEANUP_BATCH_SIZE = { type = "int", default = 1000, min = 100, max = 10000 },
  SEED_DEFAULTS = { type = "bool", default = false },
  RBAC_CACHE_TTL = { type = "int", default = 60, min = 1 },
}

local function is_url(s)
  return s:match("^https?://[%w%p]+$") ~= nil
end

local function is_email(s)
  return s:match("^[%w%.%%%+%-_]+@[%w%.%-]+%.%a%a+$") ~= nil
end

local function coerce(name, spec, raw)
  if raw == nil or raw == "" then
    if spec.required and spec.default == nil then
      return nil, name .. ": zorunlu"
    end
    return spec.default, nil
  end
  if spec.type == "string" or spec.type == "email" then
    local v = raw
    if spec.type == "email" and raw ~= "" then
      if not is_email(raw) then return nil, name .. ": gecersiz e-posta" end
    end
    if spec.min_len and #v < spec.min_len then
      return nil, name .. ": en az " .. spec.min_len .. " karakter"
    end
    return v, nil
  elseif spec.type == "url" then
    if not is_url(raw) then return nil, name .. ": gecersiz URL" end
    return raw, nil
  elseif spec.type == "int" then
    local n = tonumber(raw)
    if not n or n ~= math.floor(n) then return nil, name .. ": tamsayi olmali" end
    if spec.min and n < spec.min then return nil, name .. ": en az " .. spec.min end
    if spec.max and n > spec.max then return nil, name .. ": en fazla " .. spec.max end
    return n, nil
  elseif spec.type == "bool" then
    if raw == "true" or raw == "1" then return true, nil end
    if raw == "false" or raw == "0" or raw == "" then return false, nil end
    return nil, name .. ": true/false olmali"
  elseif spec.type == "enum" then
    for _, v in ipairs(spec.values) do if v == raw then return raw, nil end end
    return nil, name .. ": gecersiz deger " .. raw
  elseif spec.type == "csv" then
    local t = {}
    for part in raw:gmatch("[^,]+") do
      local s = part:match("^%s*(.-)%s*$")
      if s ~= "" then t[#t + 1] = s end
    end
    return t, nil
  else
    return raw, nil
  end
end

local function read_env(getenv, name)
  local file_key = name .. "_FILE"
  local file_path = getenv(file_key)
  local val = getenv(name)
  if file_path and file_path ~= "" then
    if val and val ~= "" then
      if ngx and ngx.log then
        ngx.log(ngx.WARN, name .. " ve " .. file_key .. " birlikte tanimli, dosya kullaniliyor")
      end
    end
    local fh, err = io.open(file_path, "r")
    if not fh then return nil, name .. ": dosya okunamadi " .. file_path .. ": " .. tostring(err) end
    local content = fh:read("*a")
    fh:close()
    content = content:gsub("\r?\n$", "")
    return content, nil
  end
  return val, nil
end

local function cross_validate(c)
  local errs = {}
  if c.app and c.app.env == "production" then
    if c.jwt and c.jwt.secret == "dev-secret-change-me-dev-secret-change-me" then
      errs[#errs + 1] = "JWT_SECRET uretimde ornek deger olamaz"
    end
    if c.db and c.db.password and #c.db.password < 16 then
      errs[#errs + 1] = "DB_PASSWORD uretimde en az 16 karakter"
    end
    for _, o in ipairs(c.cors_origins_list or {}) do
      if o == "*" then errs[#errs + 1] = "CORS_ORIGINS uretimde * iceremez" end
    end
    if c.log and c.log.level == "debug" then
      if ngx and ngx.log then ngx.log(ngx.WARN, "LOG_LEVEL debug uretimde onerilmez") end
    end
    if c.seed_defaults then
      if ngx and ngx.log then ngx.log(ngx.WARN, "SEED_DEFAULTS true uretimde") end
    end
  end
  return errs
end

-- salt okunur proxy → gerçek tablo (proxy boş olduğu için pairs() hiçbir şey döndürmez)
local backing = setmetatable({}, { __mode = "k" })

function _M.load(getenv)
  getenv = getenv or os.getenv
  local errors = {}
  local raw_vals = {}
  for name in pairs(SPEC) do
    local raw, err = read_env(getenv, name)
    if err then
      errors[#errors + 1] = err
    else
      raw_vals[name] = raw
    end
  end

  local values = {}
  for name, spec in pairs(SPEC) do
    local v, err = coerce(name, spec, raw_vals[name])
    if err then
      errors[#errors + 1] = err
    else
      values[name] = v
    end
  end

  if #errors > 0 then
    error("Konfigurasyon hatasi:\n  " .. table.concat(errors, "\n  "), 0)
  end

  -- gruplanmis config
  local c = {}
  c.app = {
    env = values.APP_ENV,
    port = values.APP_PORT,
    base_url = values.APP_BASE_URL,
    web_base_url = values.WEB_BASE_URL,
  }
  c.db = {
    host = values.DB_HOST,
    port = values.DB_PORT,
    database = values.DB_NAME,
    user = values.DB_USER,
    password = values.DB_PASSWORD,
    ssl = values.DB_SSL,
    pool_size = values.DB_POOL_SIZE,
    idle_timeout_ms = values.DB_POOL_IDLE_TIMEOUT_MS,
    connect_timeout_ms = values.DB_CONNECT_TIMEOUT_MS,
    query_timeout_ms = values.DB_QUERY_TIMEOUT_MS,
  }
  c.jwt = {
    secret = values.JWT_SECRET,
    issuer = values.JWT_ISSUER,
    access_ttl = values.JWT_ACCESS_TTL,
    refresh_ttl = values.JWT_REFRESH_TTL,
  }
  c.argon2 = {
    t_cost = values.ARGON2_T_COST,
    m_cost = values.ARGON2_M_COST,
    parallelism = values.ARGON2_PARALLELISM,
  }
  c.smtp = {
    host = values.SMTP_HOST,
    port = values.SMTP_PORT,
    user = values.SMTP_USER,
    password = values.SMTP_PASSWORD,
    from = values.SMTP_FROM,
    tls = values.SMTP_TLS,
  }
  -- cors_origins set ve list
  local cors_set = {}
  local cors_list = values.CORS_ORIGINS
  if type(cors_list) == "string" then cors_list = { cors_list } end
  if type(cors_list) == "table" then
    for _, v in ipairs(cors_list) do cors_set[v] = true end
  end
  c.cors_origins = cors_set
  c.cors_origins_list = cors_list
  c.trusted_proxies = values.TRUSTED_PROXIES
  if type(c.trusted_proxies) == "string" then c.trusted_proxies = { c.trusted_proxies } end
  -- trusted set
  c.trusted_proxies_set = {}
  if type(values.TRUSTED_PROXIES) == "table" then
    for _, ip in ipairs(values.TRUSTED_PROXIES) do c.trusted_proxies_set[ip] = true end
  end
  c.log = { format = values.LOG_FORMAT, level = values.LOG_LEVEL }
  c.audit = {
    retention_days = values.AUDIT_LOG_RETENTION_DAYS,
    cleanup_enabled = values.AUDIT_CLEANUP_ENABLED,
    cleanup_hour = values.AUDIT_CLEANUP_HOUR,
    cleanup_batch_size = values.AUDIT_CLEANUP_BATCH_SIZE,
  }
  c.password_reset_ttl = values.PASSWORD_RESET_TTL
  c.login_rate_limit = values.LOGIN_RATE_LIMIT
  c.seed_defaults = values.SEED_DEFAULTS
  c.rbac_cache_ttl = values.RBAC_CACHE_TTL
  -- expose raw for migrator
  c._raw = values

  -- ham degerler icin kolay erisim (or: config.get().APP_ENV)
  for k, v in pairs(values) do c[k] = v end

  local c_errs = cross_validate(c)
  if #c_errs > 0 then
    error("Konfigurasyon hatasi:\n  " .. table.concat(c_errs, "\n  "), 0)
  end

  local proxy = {}
  backing[proxy] = c
  setmetatable(proxy, {
    __index = c,
    __newindex = function() error("config salt okunur", 2) end,
    __metatable = false,
  })
  _M.current = proxy
  return proxy
end

function _M.get()
  return _M.current
end

function _M.redacted(c)
  c = c or _M.current
  if not c then return nil end
  c = backing[c] or c
  local out = {}
  for k, v in pairs(c) do
    -- _raw: ham env kopyası gizli değerleri içerir; loglara hiç yazılmaz
    if k == "_raw" then -- luacheck: ignore 542
    elseif k == "db" and type(v) == "table" then
      out.db = {}
      for kk, vv in pairs(v) do
        if kk == "password" then out.db[kk] = "***" else out.db[kk] = vv end
      end
    elseif k == "jwt" and type(v) == "table" then
      out.jwt = {}
      for kk, vv in pairs(v) do
        if kk == "secret" then out.jwt[kk] = "***" else out.jwt[kk] = vv end
      end
    elseif k == "smtp" and type(v) == "table" then
      out.smtp = {}
      for kk, vv in pairs(v) do
        if kk == "password" then out.smtp[kk] = "***" else out.smtp[kk] = vv end
      end
    elseif k == "DB_PASSWORD" or k == "JWT_SECRET" or k == "SMTP_PASSWORD" then
      out[k] = "***"
    else
      out[k] = v
    end
  end
  return out
end

function _M.spec_keys()
  local keys = {}
  for k in pairs(SPEC) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys, SPEC
end

return _M
