-- Şema tabanlı doğrulayıcı — backend (LuaJIT) ve frontend (Lua 5.4) ortak.
-- 5.1 ve 5.4 alt kümesi uyumlu
local _M = {}

_M.NULL = {}

local function utf8_len(s)
  local len = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 128 or b >= 192 then len = len + 1 end
  end
  return len
end

_M.utf8_len = utf8_len

function _M.is_uuid(s)
  if type(s) ~= "string" then return false end
  return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = #t
  if n == 0 then
    -- boş tablo: dizi sayılır (next nil ise)
    return next(t) == nil
  end
  for i = 1, n do if t[i] == nil then return false end end
  -- hole kontrolü basit değil ama yeterli
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then return false end
  end
  return true
end

-- Yardımcı: kural kopyala ve flag ekle
local function copy_rule(rule, extra)
  local c = {}
  for k, v in pairs(rule) do c[k] = v end
  for k, v in pairs(extra) do c[k] = v end
  return c
end

function _M.optional(rule)
  return copy_rule(rule, { optional = true })
end

function _M.nullable(rule)
  return copy_rule(rule, { nullable = true })
end

-- Kural kurucular
function _M.string(opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  local pat = opts.pattern
  local do_trim = opts.trim
  local do_lower = opts.lower
  return {
    kind = "string",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "metin olmalı" } end
      local s = val
      if do_trim then
        s = s:match("^%s*(.-)%s*$") or ""
      end
      if do_lower then s = s:lower() end
      local len = utf8_len(s)
      if min and len < min then
        return false, { "en az " .. tostring(min) .. " karakter" }
      end
      if max and len > max then
        return false, { "en fazla " .. tostring(max) .. " karakter" }
      end
      if pat and not s:match(pat) then
        return false, { "geçersiz biçim" }
      end
      return true, s
    end
  }
end

function _M.integer(opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  return {
    kind = "integer",
    optional = false,
    nullable = false,
    check = function(val)
      local n = val
      if type(n) == "string" then
        n = tonumber(n)
        if n == nil then return false, { "tamsayı olmalı" } end
      end
      if type(n) ~= "number" then return false, { "tamsayı olmalı" } end
      if n ~= math.floor(n) then return false, { "tamsayı olmalı" } end
      n = math.floor(n)
      if min and n < min then return false, { "en az " .. tostring(min) } end
      if max and n > max then return false, { "en fazla " .. tostring(max) } end
      return true, n
    end
  }
end

function _M.boolean()
  return {
    kind = "boolean",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "boolean" then return false, { "true/false olmalı" } end
      return true, val
    end
  }
end

function _M.enum(list)
  local set = {}
  for _, v in ipairs(list) do set[v] = true end
  local allowed = table.concat(list, ", ")
  return {
    kind = "enum",
    optional = false,
    nullable = false,
    check = function(val)
      if not set[val] then
        return false, { "geçersiz değer: " .. tostring(val) .. " (izinli: " .. allowed .. ")" }
      end
      return true, val
    end
  }
end

function _M.email()
  return {
    kind = "email",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "geçerli bir e-posta olmalı" } end
      local s = val:match("^%s*(.-)%s*$") or ""
      s = s:lower()
      if #s == 0 or #s > 255 then return false, { "geçerli bir e-posta olmalı" } end
      if not s:match("^[%w%.%%%+%-_]+@[%w%.%-]+%.%a%a+$") then
        return false, { "geçerli bir e-posta olmalı" }
      end
      return true, s
    end
  }
end

function _M.uuid()
  return {
    kind = "uuid",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "geçerli bir UUID olmalı" } end
      if not _M.is_uuid(val) then return false, { "geçerli bir UUID olmalı" } end
      return true, val
    end
  }
end

function _M.datetime()
  return {
    kind = "datetime",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "ISO-8601 tarih/saat olmalı" } end
      -- tam kalıp: YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM); sonunda başka karakter kabul edilmez
      local y, mo, d, h, mi, s, tz = val:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
      if not y or not (tz == "Z" or tz:match("^[%+%-]%d%d:%d%d$")) then
        return false, { "ISO-8601 tarih/saat olmalı" }
      end
      y = tonumber(y); mo = tonumber(mo); d = tonumber(d)
      h = tonumber(h); mi = tonumber(mi); s = tonumber(s)
      local mdays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
      if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then mdays[2] = 29 end
      if mo < 1 or mo > 12 or d < 1 or d > mdays[mo] or h > 23 or mi > 59 or s > 59 then
        return false, { "ISO-8601 tarih/saat olmalı" }
      end
      return true, val
    end
  }
end

function _M.password()
  return {
    kind = "password",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "en az 8 karakter" } end
      local msgs = {}
      if #val < 8 then msgs[#msgs+1] = "en az 8 karakter" end
      if #val > 128 then msgs[#msgs+1] = "en fazla 128 karakter" end
      if not val:match("%u") then msgs[#msgs+1] = "en az bir büyük harf içermeli" end
      if not val:match("%l") then msgs[#msgs+1] = "en az bir küçük harf içermeli" end
      if not val:match("%d") then msgs[#msgs+1] = "en az bir rakam içermeli" end
      if #msgs > 0 then return false, msgs end
      return true, val
    end
  }
end

function _M.array_of(rule, opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  local unique = opts.unique
  return {
    kind = "array_of",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "table" or not is_array(val) then
        return false, { "dizi olmalı" }
      end
      if min and #val < min then return false, { "en az " .. tostring(min) .. " eleman" } end
      if max and #val > max then return false, { "en fazla " .. tostring(max) .. " eleman" } end
      if unique then
        local seen = {}
        for _, v in ipairs(val) do
          if seen[v] then return false, { "tekrarlı değer" } end
          seen[v] = true
        end
      end
      local clean = {}
      local errors = {}
      local has_err = false
      for i, elem in ipairs(val) do
        if rule._fields then
          local c2, e2 = _M.validate(rule, elem)
          if c2 then
            clean[i] = c2
          else
            has_err = true
            local fk = next(e2)
            local msg = fk and e2[fk][1] or "geçersiz"
            errors[i] = "[" .. tostring(i) .. "]." .. tostring(fk) .. ": " .. msg
          end
        else
          local ok, out = rule.check(elem)
          if ok then clean[i] = out else
            has_err = true
            local msg = out[1] or "geçersiz"
            errors[i] = "[" .. tostring(i) .. "]: " .. msg
          end
        end
      end
      if has_err then
        local flat = {}
        for i = 1, #val do if errors[i] then flat[#flat+1] = errors[i] end end
        return false, flat
      end
      return true, clean
    end
  }
end

function _M.query_int(opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  local def = opts.default
  return {
    kind = "query_int",
    optional = false,
    nullable = false,
    check = function(val)
      if val == nil and def ~= nil then return true, def end
      local n = tonumber(val)
      if n == nil then return false, { "tamsayı olmalı" } end
      if n ~= math.floor(n) then return false, { "tamsayı olmalı" } end
      n = math.floor(n)
      if min and n < min then return false, { "en az " .. tostring(min) } end
      if max and n > max then return false, { "en fazla " .. tostring(max) } end
      return true, n
    end
  }
end

function _M.schema(fields, opts)
  opts = opts or {}
  local strict = opts.strict
  if strict == nil then strict = true end
  return {
    _fields = fields,
    _strict = strict,
  }
end

function _M.validate(schema, input, opts)
  opts = opts or {}
  local null_values = opts.null_values
  local strict = opts.strict
  if strict == nil then strict = schema._strict end

  if type(input) ~= "table" then
    return nil, { _ = { "nesne olmalı" } }
  end

  local errors = {}
  local clean = {}

  if strict then
    for k in pairs(input) do
      if schema._fields[k] == nil then
        errors[k] = { "bilinmeyen alan" }
      end
    end
  end

  for name, rule in pairs(schema._fields) do
    local val = input[name]
    local is_null_sentinel = false
    -- null_values kontrolü
    if val ~= nil then
      if null_values then
        for _, nv in ipairs(null_values) do
          if val == nv then
            val = _M.NULL
            is_null_sentinel = true
            break
          end
        end
      end
      -- cjson.null userdata için NULL
      if not is_null_sentinel and rule.nullable and type(val) == "userdata" then
        val = _M.NULL
      end
      -- js null gibi nil'e dönüşmüşse zaten nil
    end

    if val == nil then
      if not rule.optional then
        -- ancak strict hatası varsa üzerine yazma? yine de zorunlu
        if not errors[name] then
          errors[name] = { "zorunlu alan" }
        end
      end
    elseif val == _M.NULL then
      if not rule.nullable then
        errors[name] = { "boş olamaz" }
      else
        clean[name] = _M.NULL
      end
    else
      if rule._fields then
        local c2, e2 = _M.validate(rule, val)
        if c2 then
          clean[name] = c2
        else
          errors[name] = e2
          -- flatten for error message? keep as nested; spec expects details as field -> msgs
          -- For nested, store first error under field name
          if e2 and next(e2) then
            local fk = next(e2)
            errors[name] = { fk .. ": " .. e2[fk][1] }
          end
        end
      else
        local ok, out = rule.check(val)
        if ok then
          clean[name] = out
        else
          errors[name] = out
        end
      end
    end
  end

  if next(errors) ~= nil then
    return nil, errors
  end
  return clean, nil
end

function _M.validate_partial(schema, input, opts)
  if type(input) ~= "table" then
    return nil, { _ = { "nesne olmalı" } }
  end
  if next(input) == nil then
    return nil, { _ = { "en az bir alan gönderilmeli" } }
  end
  -- tüm alanları optional yap
  local fields = {}
  for k, rule in pairs(schema._fields) do
    fields[k] = copy_rule(rule, { optional = true })
  end
  local partial = { _fields = fields, _strict = schema._strict }
  return _M.validate(partial, input, opts)
end

-- Hazır şemalar (frontend ve backend ortak)
-- types gerektirenler lazy: require edildiğinde doldurur
local function init_schemas()
  local ok, types = pcall(require, "todo_shared.types")
  if not ok then
    -- fallback: env'de types yoksa minimal
    types = {
      TODO_STATUS = { "pending", "in_progress", "completed" },
      TODO_PRIORITY = { "low", "medium", "high" },
      ROLES = { "admin", "todouser" },
      PAGES = {
        "dashboard", "todos.list", "todos.create", "todos.edit",
        "users.list", "users.create", "rbac.matrix", "audit.logs", "settings",
      },
    }
  end

  _M.schemas = {}

  _M.schemas.login = _M.schema({
    email = _M.email(),
    password = _M.string({ min = 1, max = 128 }),
  })

  _M.schemas.forgot_password = _M.schema({
    email = _M.email(),
  })

  _M.schemas.reset_password = _M.schema({
    token = _M.string({ min = 64, max = 64, pattern = "^%x+$" }),
    new_password = _M.password(),
  })

  _M.schemas.refresh = _M.schema({
    refresh_token = _M.string({ min = 1, max = 2048 }),
  })

  _M.schemas.logout = _M.schema({
    refresh_token = _M.optional(_M.string({ min = 1, max = 2048 })),
  })

  _M.schemas.todo_create = _M.schema({
    title = _M.string({ min = 1, max = 255, trim = true }),
    description = _M.optional(_M.nullable(_M.string({ max = 10000 }))),
    status = _M.optional(_M.enum(types.TODO_STATUS)),
    priority = _M.optional(_M.enum(types.TODO_PRIORITY)),
    due_date = _M.optional(_M.nullable(_M.datetime())),
    tags = _M.optional(_M.array_of(_M.string({ min = 1, max = 50, trim = true }), { max = 20, unique = true })),
    user_id = _M.optional(_M.uuid()),
  })

  -- PUT: title zorunlu; eksik alanlar serviste varsayılana döner (F6 §2.3)
  _M.schemas.todo_update = _M.schema({
    title = _M.string({ min = 1, max = 255, trim = true }),
    description = _M.optional(_M.nullable(_M.string({ max = 10000 }))),
    status = _M.optional(_M.enum(types.TODO_STATUS)),
    priority = _M.optional(_M.enum(types.TODO_PRIORITY)),
    due_date = _M.optional(_M.nullable(_M.datetime())),
    tags = _M.optional(_M.array_of(_M.string({ min = 1, max = 50, trim = true }), { max = 20, unique = true })),
  })

  _M.schemas.todo_replace = _M.schemas.todo_update

  _M.schemas.todo_patch = _M.schema({
    title = _M.optional(_M.string({ min = 1, max = 255, trim = true })),
    description = _M.optional(_M.nullable(_M.string({ max = 10000 }))),
    status = _M.optional(_M.enum(types.TODO_STATUS)),
    priority = _M.optional(_M.enum(types.TODO_PRIORITY)),
    due_date = _M.optional(_M.nullable(_M.datetime())),
    tags = _M.optional(_M.array_of(_M.string({ min = 1, max = 50, trim = true }), { max = 20, unique = true })),
  })

  _M.schemas.user_create = _M.schema({
    email = _M.email(),
    password = _M.password(),
    full_name = _M.optional(_M.nullable(_M.string({ min = 1, max = 255, trim = true }))),
    role = _M.enum(types.ROLES),
    is_active = _M.optional(_M.boolean()),
  })

  _M.schemas.user_update = _M.schema({
    email = _M.optional(_M.email()),
    full_name = _M.optional(_M.nullable(_M.string({ min = 1, max = 255, trim = true }))),
    role = _M.optional(_M.enum(types.ROLES)),
    is_active = _M.optional(_M.boolean()),
    password = _M.optional(_M.password()),
  })

  _M.schemas.rbac_cell = _M.schema({
    can_access = _M.boolean(),
  })

  _M.schemas.rbac_matrix = _M.schema({
    permissions = _M.array_of(_M.schema({
      role = _M.enum(types.ROLES),
      page_key = _M.enum(types.PAGES),
      can_access = _M.boolean(),
    }, { strict = true }), { min = 1 }),
  })

  _M.schemas.todo_list_query = _M.schema({
    status = _M.optional(_M.enum(types.TODO_STATUS)),
    priority = _M.optional(_M.enum(types.TODO_PRIORITY)),
    q = _M.optional(_M.string({ max = 100 })),
    tag = _M.optional(_M.string({ max = 30 })),
    due_before = _M.optional(_M.datetime()),
    due_after = _M.optional(_M.datetime()),
    user_id = _M.optional(_M.uuid()),
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 20 })),
    sort = _M.optional(_M.string({ max = 100 })),
  })

  _M.schemas.user_list_query = _M.schema({
    q = _M.optional(_M.string({ max = 100 })),
    role = _M.optional(_M.enum(types.ROLES)),
    is_active = _M.optional(_M.enum({ "true", "false" })),
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 20 })),
    sort = _M.optional(_M.string({ max = 100 })),
  })

  _M.schemas.audit_query = _M.schema({
    action = _M.optional(_M.string({ max = 100 })),
    status = _M.optional(_M.enum({ "success", "failure" })),
    entity_type = _M.optional(_M.string({ max = 50 })),
    entity_id = _M.optional(_M.string({ max = 100 })),
    user_id = _M.optional(_M.uuid()),
    user_email = _M.optional(_M.string({ max = 255 })),
    ip = _M.optional(_M.string({ max = 45, pattern = "^[%x%.:]+$" })),
    from = _M.optional(_M.datetime()),
    to = _M.optional(_M.datetime()),
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 20 })),
  })
end

init_schemas()

return _M
