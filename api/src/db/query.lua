-- Parametreli sorgu katmanı: pgmoon extended protocol, $n yer tutucular
-- Transaction bağlantısı ngx.ctx.tx_conn içinde tutulur.
local pool = require("db.pool")
local validation = require("todo_shared.validation")

local _M = {}

local VNULL = validation.NULL

-- SQLSTATE → AppError; ham PG mesajı yalnızca loga yazılır, istemciye asla gitmez
local function map_pg_error(err)
  if err == nil then return nil end
  local sqlstate = type(err) == "table" and err.code or nil
  local constraint = type(err) == "table" and err.constraint or nil
  local app_code, details = "INTERNAL_ERROR", nil
  if not sqlstate or sqlstate:sub(1, 2) == "08" or sqlstate == "57P01" then
    -- sqlstate yoksa soket/bağlantı hatasıdır (timeout, closed, connection refused)
    app_code = "DB_UNAVAILABLE"
  elseif sqlstate == "23505" then
    app_code = (constraint or ""):find("email", 1, true) and "EMAIL_TAKEN" or "CONFLICT"
  elseif sqlstate == "23503" then
    app_code = "NOT_FOUND"
  elseif sqlstate == "22P02" or sqlstate == "22007" or sqlstate == "22008" then
    app_code = "BAD_REQUEST"
  elseif sqlstate == "23514" or sqlstate == "23502" then
    app_code = "VALIDATION_FAILED"
    -- "todos_title_check" → title
    local field = constraint and constraint:match("^[%w]+_(.-)_check$") or constraint or "_"
    details = { [field] = { "geçersiz değer" } }
  end
  local level = (app_code == "INTERNAL_ERROR" or app_code == "DB_UNAVAILABLE") and ngx.ERR or ngx.INFO
  ngx.log(level, "db hatasi sqlstate=", tostring(sqlstate), " constraint=", tostring(constraint),
    " req_id=", tostring(ngx.ctx and ngx.ctx.req_id), ": ", tostring(err))
  return {
    code = app_code,
    details = details,
    sqlstate = sqlstate,
    constraint = constraint,
    __app_error = true,
  }
end
_M.map_pg_error = map_pg_error

-- cjson.null / ngx.null (userdata) ve validation.NULL → SQL NULL (nil); arity korunur
local function normalize(...)
  local n = select("#", ...)
  local args = { ... }
  for i = 1, n do
    local v = args[i]
    if v == VNULL or type(v) == "userdata" then args[i] = nil end
  end
  return args, n
end

local function get_conn()
  if ngx.ctx.tx_conn then
    return ngx.ctx.tx_conn, false
  end
  local pg, err = pool.acquire()
  if not pg then
    return nil, map_pg_error(err)
  end
  return pg, true
end

function _M.query(sql, ...)
  local pg, owned = get_conn()
  if not pg then return nil, owned end
  local args, n = normalize(...)
  local res, qerr
  if n > 0 then
    res, qerr = pg:query(sql, unpack(args, 1, n))
  else
    res, qerr = pg:query(sql)
  end
  if res == nil then
    local app_err = map_pg_error(qerr)
    if owned then pool.release(pg, app_err.code == "DB_UNAVAILABLE") end
    return nil, app_err
  end
  if owned then pool.release(pg, false) end
  return res
end

function _M.query_one(sql, ...)
  local rows, err = _M.query(sql, ...)
  if not rows then return nil, err end
  return rows[1]
end

-- Etkilenen satır sayısını döndürür
function _M.exec(sql, ...)
  local rows, err = _M.query(sql, ...)
  if not rows then return nil, err end
  if type(rows) ~= "table" then return 0 end
  return rows.affected_rows or #rows
end

-- fn nil, err dönerse ya da hata atarsa ROLLBACK; iç içe çağrı dıştaki transaction'ı kullanır
function _M.with_transaction(fn)
  if ngx.ctx.tx_conn then
    return fn()
  end
  local pg, err = pool.acquire()
  if not pg then return nil, map_pg_error(err) end
  local bres, berr = pg:query("BEGIN")
  if bres == nil then pool.release(pg, true); return nil, map_pg_error(berr) end
  ngx.ctx.tx_conn = pg
  local ok, r1, r2 = pcall(fn)
  ngx.ctx.tx_conn = nil
  if not ok then
    pg:query("ROLLBACK")
    pool.release(pg, false)
    error(r1, 0)
  end
  if r1 == nil and r2 ~= nil then
    pg:query("ROLLBACK")
    pool.release(pg, false)
    return nil, r2
  end
  local cres, cerr = pg:query("COMMIT")
  if cres == nil then
    pool.release(pg, true)
    return nil, map_pg_error(cerr)
  end
  pool.release(pg, false)
  return r1, r2
end

-- Readiness: SELECT 1, 1 sn timeout
function _M.ping()
  local pg, err = pool.acquire()
  if not pg then return nil, map_pg_error(err) end
  if pg.sock and pg.sock.settimeout then pg.sock:settimeout(1000) end
  local res, qerr = pg:query("SELECT 1 AS ok")
  pool.release(pg, res == nil)
  if res == nil then return nil, map_pg_error(qerr) end
  return true
end

-- ILIKE için %, _ ve \ kaçışı
function _M.like_pattern(s)
  if type(s) ~= "string" then return "" end
  local esc = s:gsub("[\\%%_]", "\\%0")
  return "%" .. esc .. "%"
end

return _M
