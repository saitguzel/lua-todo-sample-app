-- Audit okuma endpoint'leri: liste, detay, istatistik, CSV export
local validation = require("todo_shared.validation")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")
local audit_repo = require("repositories.audit_repo")
local audit_model = require("models.audit")

local _M = {}

local DAY = 86400
local MAX_RANGE_DAYS = 90
local DEFAULT_RANGE_DAYS = 7

-- ISO-8601 (validation.datetime'dan geçmiş) → epoch saniye (UTC)
local function iso_to_epoch(s)
  local y, mo, d, h, mi, sec, tz = s:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)%.?%d*(.*)$")
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days_from_civil (H. Hinnant): takvimden bağımsız gün sayısı
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (mo + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  local t = days * DAY + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  local sign, oh, om = tz:match("^([%+%-])(%d%d):(%d%d)$")
  if sign then
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    t = sign == "+" and t - off or t + off
  end
  return t
end

local function epoch_to_iso(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- Sorgu parametrelerini doğrular; from/to varsayılanı son 7 gün, aralık en fazla 90 gün
local function parse_audit_query()
  local raw = ngx.req.get_uri_args()
  local clean, ferr = validation.validate(validation.schemas.audit_query, raw)
  if not clean then return nil, errors.validation(ferr) end
  local now = ngx.time()
  local to_t = clean.to and iso_to_epoch(clean.to) or now
  local from_t = clean.from and iso_to_epoch(clean.from) or (to_t - DEFAULT_RANGE_DAYS * DAY)
  if from_t >= to_t then
    return nil, errors.validation({ from = { "from, to'dan önce olmalı" } })
  end
  if to_t - from_t > MAX_RANGE_DAYS * DAY then
    return nil, errors.validation({ from = { "aralık en fazla " .. MAX_RANGE_DAYS .. " gün" } })
  end
  -- to verilmezse SQL'de üst sınır yok (aynı saniyedeki kayıtlar kaçmasın); yanıtta range.to = now
  clean.from = clean.from or epoch_to_iso(from_t)
  clean.range = { from = clean.from, to = clean.to or epoch_to_iso(to_t) }
  return clean, nil
end
_M._iso_to_epoch = iso_to_epoch

function _M.list()
  local q, err = parse_audit_query()
  if not q then return errors.respond(err) end
  local rows, total = audit_repo.list(q, q.page, q.per_page)
  if not rows then return errors.respond(total) end
  local items = {}
  -- listede old/new seçilmez (serialize nil alanları atlar)
  for i, r in ipairs(rows) do items[i] = audit_model.serialize(r) end
  local total_pages = total > 0 and math.ceil(total / (q.per_page or 20)) or 0
  local meta = { page = q.page or 1, per_page = q.per_page or 20, total = total, total_pages = total_pages }
  return { status = 200, json = { data = items, meta = meta } }
end

function _M.get(self)
  local id = self.params and self.params.id
  if not id or not id:match("^%d+$") then
    return errors.respond(errors.new("NOT_FOUND", "Kayit bulunamadi"))
  end
  local row, ferr = audit_repo.find(tonumber(id))
  if ferr then return errors.respond(ferr) end
  if not row then return errors.respond(errors.new("NOT_FOUND", "Kayit bulunamadi")) end
  return { status = 200, json = { data = audit_model.serialize(row) } }
end

function _M.stats()
  local q, err = parse_audit_query()
  if not q then return errors.respond(err) end
  local result, serr = audit_service.stats(q)
  if not result then return errors.respond(serr or errors.new("INTERNAL_ERROR", "Istatistik alinamadi")) end
  return { status = 200, json = { data = result } }
end

function _M.export()
  local q, err = parse_audit_query()
  if not q then return errors.respond(err) end
  local fname = "audit-" .. os.date("!%Y%m%d-%H%M%S") .. ".csv"
  ngx.header["Content-Type"] = "text/csv; charset=utf-8"
  ngx.header["Content-Disposition"] = 'attachment; filename="' .. fname .. '"'
  ngx.header["Cache-Control"] = "no-store"
  ngx.header["X-Request-Id"] = ngx.ctx.req_id
  local count, serr = audit_service.export(q, function(chunk)
    ngx.print(chunk)
    if ngx.flush then ngx.flush(true) end
  end)
  if not count then
    ngx.log(ngx.ERR, "audit export yarida kaldi: ", tostring(serr), " req_id=", ngx.ctx.req_id)
    ngx.print("\r\n# HATA: export tamamlanamadi, req_id=", ngx.ctx.req_id, "\r\n")
  end
  return { layout = false, skip_render = true }
end

return _M
