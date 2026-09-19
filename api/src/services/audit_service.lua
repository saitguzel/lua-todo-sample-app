-- Audit servisi: kayit yazma, listeleme, istatistik, export
-- F5 minimal surum; F8 genisletmesi ayni imza ile devam eder.
local cjson = require("cjson.safe")
local types = require("todo_shared.types")
local audit_model = require("models.audit")
local audit_repo = require("repositories.audit_repo")

local _M = {}

local function is_ip(s)
  if type(s) ~= "string" then return false end
  return s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil or (s:find(":", 1, true) ~= nil and s:match("^[%x:%.]+$") ~= nil)
end

-- Audit kaydı yazar; hata ana işlemi bozmaz, yalnızca loglanır (F5 sözleşmesi)
function _M.record(action, opts)
  opts = opts or {}
  local ctx = ngx.ctx
  local identity = ctx.identity or {}
  local actx = ctx.audit or {}
  if not types.AUDIT_SET[action] then
    ngx.log(ngx.WARN, "audit: 00 §8 listesinde olmayan action: ", tostring(action))
  end
  local entry = {
    user_id = opts.user_id or identity.user_id,
    user_email = opts.user_email or identity.email,
    action = action,
    entity_type = opts.entity_type,
    entity_id = opts.entity_id and tostring(opts.entity_id) or nil,
    old_value = opts.old_value and cjson.encode(audit_model.mask(opts.old_value)) or nil,
    new_value = opts.new_value and cjson.encode(audit_model.mask(opts.new_value)) or nil,
    -- geçersiz IP → NULL: ::inet cast hatası kaydı düşürmesin
    ip_address = is_ip(actx.ip) and actx.ip or nil,
    user_agent = actx.user_agent,
    status = opts.status or "success",
    error_message = opts.error_message and tostring(opts.error_message):sub(1, 1000) or nil,
  }
  local ok, res, err = pcall(audit_repo.insert, entry)
  if not ok or not res then
    local e = ok and err or res
    ngx.log(ngx.ERR, "audit yazilamadi: action=", action, " req_id=", tostring(ctx.req_id),
      " err=", tostring(type(e) == "table" and (e.code .. "/" .. tostring(e.sqlstate)) or e),
      " entry=", cjson.encode({ user_id = entry.user_id, entity_type = entry.entity_type,
                                entity_id = entry.entity_id }))
    return nil, e
  end
  return true
end

-- 5 sorgu paralel (00 §11 #16); herhangi biri başarısızsa hata döner (sessizce {} değil)
function _M.stats(q)
  local fns = {
    function() return audit_repo.stats_by_action(q) end,
    function() return audit_repo.stats_by_status(q) end,
    function() return audit_repo.stats_by_day(q) end,
    function() return audit_repo.stats_top_users(q) end,
    function() return audit_repo.stats_failed_logins_24h() end,
    function() return audit_repo.stats_total(q) end,
  }
  local threads, results = {}, {}
  for i, fn in ipairs(fns) do threads[i] = ngx.thread.spawn(fn) end
  for i, th in ipairs(threads) do
    local ok, res, err = ngx.thread.wait(th)
    if not ok or not res then
      for j = i + 1, #threads do ngx.thread.kill(threads[j]) end
      return nil, err or require("middleware.error_handler").new("INTERNAL_ERROR", "Istatistik alinamadi")
    end
    results[i] = res
  end
  local by_status = { success = 0, failure = 0 }
  for _, r in ipairs(results[2]) do by_status[r.status] = r.count end
  return {
    range = q.range or { from = q.from, to = q.to },
    total = results[6].count or 0,
    by_status = by_status,
    by_action = results[1],
    by_day = results[3],
    top_users = results[4],
    failed_logins_24h = results[5].n or 0,
  }
end

-- CSV streaming: keyset batch + flush; bellek satır sayısından bağımsız
function _M.export(q, write_fn)
  local BATCH = 1000
  local MAX_ROWS = 100000
  local cols = audit_model.CSV_COLUMNS
  local ncols = #cols
  write_fn("\239\187\191" .. _M.csv_line(cols))
  local before, total = nil, 0
  local vals = {}
  while total < MAX_ROWS do
    local rows, err = audit_repo.batch_after(q, before, BATCH)
    if not rows then return nil, err end
    if #rows == 0 then break end
    local buf = {}
    for i, r in ipairs(rows) do
      -- indeksle yaz: NULL kolon kaymasın
      for c = 1, ncols do vals[c] = r[cols[c]] end
      buf[i] = _M.csv_line(vals, ncols)
    end
    write_fn(table.concat(buf))
    total = total + #rows
    before = rows[#rows].id
    if #rows < BATCH then break end
  end
  collectgarbage("collect")
  return total
end

local function csv_field(v)
  if v == nil or v == ngx.null then return "" end
  if type(v) == "table" then v = cjson.encode(v) end
  v = tostring(v)
  if v:find("^[=+%-@\t\r]") then v = "'" .. v end
  if v:find('[",\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
  return v
end

function _M.csv_line(values, n)
  local out = {}
  for i = 1, n or #values do out[i] = csv_field(values[i]) end
  return table.concat(out, ",") .. "\r\n"
end

return _M
