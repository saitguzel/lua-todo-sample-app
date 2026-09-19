-- Log temizleme işi: saatlik kontrol, günde bir kez (AUDIT_CLEANUP_HOUR, UTC) batch DELETE
-- Yalnızca worker 0 zamanlar; çok instance için pg_try_advisory_lock, worker içi için job_locks dict.
local config = require("config")
local pool = require("db.pool")
local cjson = require("cjson.safe")

local ngx_log = ngx.log
local ngx_now = ngx.now

local _M = {}

_M.ADVISORY_LOCK_KEY = 7310001
_M.CHECK_INTERVAL = 3600
_M.BATCH_PAUSE = 0.05

local DELETE_SQL = [[
  DELETE FROM audit_logs WHERE id IN (
    SELECT id FROM audit_logs WHERE created_at < now() - make_interval(days => $1)
    ORDER BY created_at LIMIT $2)
  RETURNING 1]]

local META_SQL = [[
  INSERT INTO cleanup_logs (job_name, table_name, deleted_count, batch_count, duration_ms, status, error_message)
  VALUES ('log_cleanup', 'audit_logs', $1, $2, $3, $4, $5)]]

local function log_event(level, event, fields)
  fields = fields or {}
  fields.event = event
  fields.level = level == ngx.ERR and "error" or (level == ngx.WARN and "warn" or "info")
  ngx_log(level, cjson.encode(fields))
end

-- Saf karar fonksiyonu: bu saat hedef saat mi ve bugün çalışmadı mı?
function _M.should_run(now_utc, hour, last_run_day)
  local t = os.date("!*t", now_utc)
  if t.hour ~= hour then return false end
  return last_run_day ~= os.date("!%Y-%m-%d", now_utc)
end

-- Meta-log ayrı bağlantıyla yazılır; başarısızlık yalnızca loglanır
local function write_meta(deleted, batches, duration_ms, status, err_msg)
  local c2, cerr = pool.acquire()
  if not c2 then
    log_event(ngx.ERR, "job.log_cleanup.meta_failed", { error = tostring(cerr) })
    return
  end
  local res, qerr = c2:query(META_SQL, deleted, batches, duration_ms, status, err_msg or cjson.null)
  pool.release(c2, res == nil)
  if res == nil then log_event(ngx.ERR, "job.log_cleanup.meta_failed", { error = tostring(qerr) }) end
end

function _M.run_once()
  local audit_cfg = (config.get() or {}).audit or {}
  local retention = audit_cfg.retention_days or 30
  local batch_size = audit_cfg.cleanup_batch_size or 1000
  local started = ngx_now()
  local deleted, batches, status = 0, 0, "success"

  local conn, cerr = pool.acquire()
  if not conn then
    local msg = "db baglantisi yok: " .. tostring(cerr)
    log_event(ngx.ERR, "job.log_cleanup.failed", { error = msg })
    return nil, msg
  end

  local locked = false
  local ok, perr = pcall(function()
    -- pgmoon sayıyı numeric gönderebilir → metin + ::bigint cast
    local rows, lerr = conn:query("SELECT pg_try_advisory_lock($1::bigint) AS ok", tostring(_M.ADVISORY_LOCK_KEY))
    if rows == nil then error(lerr, 0) end
    locked = rows[1] and (rows[1].ok == true or rows[1].ok == "t")
    if not locked then status = "skipped"; return end
    while true do
      if ngx.worker.exiting() then status = "partial"; break end
      local del_rows, qerr = conn:query(DELETE_SQL, retention, batch_size)
      if del_rows == nil then error(qerr, 0) end
      local n = #del_rows
      if n == 0 then break end
      deleted = deleted + n
      batches = batches + 1
      if n < batch_size then break end
      ngx.sleep(_M.BATCH_PAUSE)
    end
  end)

  if locked then
    local ures = conn:query("SELECT pg_advisory_unlock($1::bigint)", tostring(_M.ADVISORY_LOCK_KEY))
    pool.release(conn, ures == nil)
  else
    pool.release(conn, not ok)
  end

  if status == "skipped" then
    log_event(ngx.NOTICE, "job.log_cleanup.skipped")
    return { deleted = 0, batches = 0, duration_ms = 0, status = "skipped" }
  end

  local duration_ms = math.floor((ngx_now() - started) * 1000)
  local err_msg
  if not ok then
    status, err_msg = "failure", tostring(perr)
    log_event(ngx.ERR, "job.log_cleanup.failed", { error = err_msg, deleted = deleted })
  end
  write_meta(deleted, batches, duration_ms, status, err_msg)
  if not ok then return nil, err_msg end

  local dict = ngx.shared.job_locks
  if dict then dict:set("last_run:log_cleanup", os.date("!%Y-%m-%d", ngx.time()), 86400) end
  log_event(ngx.NOTICE, "job.log_cleanup.done",
    { deleted = deleted, batches = batches, duration_ms = duration_ms, status = status })
  collectgarbage("collect")
  return { deleted = deleted, batches = batches, duration_ms = duration_ms, status = status }
end

-- Tek tick: saat/gün kontrolü + worker içi kilit; hiçbir hata worker'ı düşürmez
function _M.tick(premature)
  if premature then return end
  local cfg = config.get()
  local dict = ngx.shared.job_locks
  local last = dict and dict:get("last_run:log_cleanup")
  if not _M.should_run(ngx.time(), cfg.audit.cleanup_hour or 3, last) then return end
  if dict then
    local added = dict:add("lock:log_cleanup", ngx.worker.pid(), 3600)
    if not added then return end
  end
  local ok, err = pcall(_M.run_once)
  if dict then dict:delete("lock:log_cleanup") end
  if not ok then log_event(ngx.ERR, "job.log_cleanup.failed", { error = tostring(err) }) end
end

function _M.start()
  local cfg = config.get()
  if not cfg or not cfg.audit or not cfg.audit.cleanup_enabled then
    log_event(ngx.NOTICE, "job.log_cleanup.disabled")
    return true
  end
  if ngx.worker.id() ~= 0 then return true end
  local ok, err = ngx.timer.at(0, _M.tick)
  if not ok then return nil, "timer.at: " .. tostring(err) end
  ok, err = ngx.timer.every(_M.CHECK_INTERVAL, _M.tick)
  if not ok then return nil, "timer.every: " .. tostring(err) end
  log_event(ngx.NOTICE, "job.log_cleanup.scheduled", { interval = _M.CHECK_INTERVAL })
  return true
end

return _M
