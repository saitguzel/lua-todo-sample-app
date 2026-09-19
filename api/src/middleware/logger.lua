-- İstek loglama: req_id üretir, log fazında erişim logu yazar
-- JSON veya text format, seviye filtresi, metrics dict sayaçları.
-- Satırlar nginx öneki olmadan doğrudan stderr'e yazılır → `docker logs | jq .` ile parse edilir.
local cjson = require("cjson.safe")
local random = require("security.random")
local config = require("config")

local _M = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local stderr = io.stderr

local function is_uuid(s)
  return s and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function log_cfg()
  local c = config.current and config.current.log
  return c and c.format or "json", c and c.level or "info"
end

-- ISO-8601 milisaniyeli UTC zaman damgası
local function ts()
  local now = ngx.now()
  return os.date("!%Y-%m-%dT%H:%M:%S", math.floor(now)) .. string.format(".%03dZ", math.floor(now * 1000) % 1000)
end

local function enabled(level)
  local _, min = log_cfg()
  return (LEVELS[level] or 2) >= (LEVELS[min] or 2)
end

local function write(line)
  stderr:write(line, "\n")
end

function _M.handle()
  local id = ngx.var.http_x_request_id
  if not (id and is_uuid(id)) then
    id = random.uuid4()
  end
  ngx.ctx.req_id = id
  ngx.ctx.started_at = ngx.now()
  ngx.header["X-Request-Id"] = id
  return nil
end

function _M.log_phase()
  local ctx = ngx.ctx
  local status = ngx.status or 0
  local duration = (ngx.now() - (ctx.started_at or ngx.req.start_time())) * 1000

  local metrics = ngx.shared.metrics
  if metrics then
    metrics:incr("req_total", 1, 0)
    local bucket = "req:5xx"
    if status < 400 then bucket = "req:2xx" elseif status < 500 then bucket = "req:4xx" end
    metrics:incr(bucket, 1, 0)
    metrics:incr("latency_sum_ms", duration, 0)
  end

  local level = status >= 500 and "error" or "info"
  if not enabled(level) then return end
  local fmt = log_cfg()
  local req_id = ctx.req_id or "-"
  local user_id = ctx.identity and ctx.identity.user_id or "-"
  -- query string LOGLANMAZ (reset token vb. sızmasın) — yalnızca ngx.var.uri
  if fmt == "json" then
    write(cjson.encode({
      ts = ts(),
      level = level,
      req_id = req_id,
      method = ngx.req.get_method(),
      path = ngx.var.uri,
      status = status,
      duration_ms = math.floor(duration * 100) / 100,
      user_id = user_id,
      ip = ctx.audit and ctx.audit.ip or ngx.var.remote_addr,
      bytes = tonumber(ngx.var.bytes_sent) or 0,
    }))
  else
    write(string.format("%s %s [%s] %s %s %d %.0fms user=%s", ts(), level:upper(), req_id,
      ngx.req.get_method(), ngx.var.uri, status, duration, user_id))
  end
end

-- Uygulama logu (servisler kullanır): seviye filtreli, req_id otomatik eklenir
local function app_log(level, msg, fields)
  if not enabled(level) then return end
  local fmt = log_cfg()
  local req_id = ngx.ctx and ngx.ctx.req_id or "-"
  if fmt == "json" then
    local entry = { ts = ts(), level = level, msg = msg, req_id = req_id }
    if fields then for k, v in pairs(fields) do entry[k] = v end end
    write(cjson.encode(entry))
  else
    write(string.format("%s %s [%s] %s %s", ts(), level:upper(), req_id, msg,
      fields and cjson.encode(fields) or ""))
  end
end

function _M.debug(msg, fields) app_log("debug", msg, fields) end
function _M.info(msg, fields) app_log("info", msg, fields) end
function _M.warn(msg, fields) app_log("warn", msg, fields) end
function _M.error(msg, fields) app_log("error", msg, fields) end

return _M
