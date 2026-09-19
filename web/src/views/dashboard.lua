-- F14: Dashboard — /todos/stats kartları, tamamlanma progress bar'ı, son todo'lar.
-- F15: admin kartları izin bazlı (rol adına değil can(page_key)'e) gösterilir.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")

local _M = {}
_M.title = "Pano"
_M.layout = true

local PRIORITY_LABEL = { high = "Yüksek", medium = "Orta", low = "Düşük" }
local STATUS_LABEL = { pending = "Bekleyen", in_progress = "Devam eden", completed = "Tamamlanan" }

function _M.enter()
  app.dispatch({ type = "STATS_REQUESTED" })
  local stats, err = api.get("/todos/stats")
  if err then
    app.dispatch({ type = "STATS_FAILED", error = err })
    app.toast("error", "İstatistikler yüklenemedi")
    return
  end
  app.dispatch({ type = "STATS_LOADED", stats = stats })
  -- son 5 todo
  local recent, rerr = api.get("/todos", { per_page = 5, sort = "-updated_at" })
  if not rerr and recent and recent.items then
    app.dispatch({ type = "RECENT_TODOS_LOADED", items = recent.items })
  end
  -- admin kartları izin bazlı ve bağımsız: biri hata verirse yalnızca o kart "—"
  if app.can("audit.logs") then
    local from = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 86400)
    local astats, aerr = api.get("/audit/stats", { from = from })
    if not aerr and astats then
      app.dispatch({ type = "ADMIN_STATS_LOADED", stats = { audit = astats, audit_from = from } })
    else
      app.dispatch({ type = "ADMIN_STATS_FAILED" })
    end
  end
  if app.can("users.list") then
    local all = api.get("/users", { per_page = 1 })
    local active = api.get("/users", { per_page = 1, is_active = "true" })
    app.dispatch({ type = "ADMIN_STATS_LOADED", stats = {
      users_total = all and all.meta and all.meta.total,
      users_active = active and active.meta and active.meta.total,
    } })
  end
end

-- href verilirse kart ilgili (filtreli) sayfaya bağlantıdır
local function stat_card(label, value, opts)
  opts = opts or {}
  local body = {
    dom.p({ class = "text-sm text-[var(--fg-muted)]" }, label),
    dom.p({ class = opts.danger and "text-2xl font-bold text-[var(--danger)]" or "text-2xl font-bold" },
      tostring(value or "—")),
  }
  local cls = "stat-card block bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] p-4"
  if opts.href then
    return dom.li({}, dom.a({ href = opts.href, class = cls .. " hover:border-[var(--primary)]" }, body))
  end
  return dom.li({ class = cls }, body)
end

function _M.render(state)
  local stats = state.stats.data
  local status = state.stats.status
  local by_status = (stats and stats.by_status) or {}

  local cards
  if status == "loading" or status == "idle" then
    cards = require("components.skeleton").cards(5)
  else
    cards = dom.ul({ class = "grid grid-cols-2 lg:grid-cols-5 gap-3 mb-6", role = "list" },
      stat_card("Toplam", stats and stats.total, { href = "#/todos" }),
      stat_card("Bekleyen", by_status.pending, { href = "#/todos?status=pending" }),
      stat_card("Devam eden", by_status.in_progress, { href = "#/todos?status=in_progress" }),
      stat_card("Tamamlanan", by_status.completed, { href = "#/todos?status=completed" }),
      stat_card("Geciken", stats and stats.overdue, { danger = true, href = "#/todos?sort=due_date" }))
  end

  local total = tonumber(stats and stats.total) or 0
  local completed = tonumber(by_status.completed) or 0
  local pct = total > 0 and math.floor(completed * 100 / total) or 0

  -- son todo'lar
  local recent_items = {}
  for _, t in ipairs(state.stats.recent or {}) do
    recent_items[#recent_items + 1] = dom.li({ key = t.id,
      class = "flex items-center justify-between gap-2 py-2 border-b border-[var(--border)]" },
      dom.a({ href = "#/todos/" .. router.urlencode(t.id), class = "truncate hover:underline" }, t.title or ""),
      dom.span({ class = "badge badge-" .. (t.status or "pending") }, STATUS_LABEL[t.status] or t.status or ""))
  end

  -- admin kartları (izin bazlı, rol adına değil) — ilgili filtreli sayfaya bağlanır
  local admin_cards = {}
  local adm = state.stats.admin or {}
  if app.can("audit.logs") then
    local a = adm.audit or {}
    local from = adm.audit_from and router.urlencode(adm.audit_from) or ""
    admin_cards[#admin_cards + 1] = stat_card("24s audit olayı", a.total,
      { href = "#/audit-logs?from=" .. from })
    admin_cards[#admin_cards + 1] = stat_card("24s başarısız giriş",
      a.failed_logins_24h or (a.by_action and a.by_action["auth.login.failure"]),
      { danger = true, href = "#/audit-logs?action=auth.login.failure&from=" .. from })
    admin_cards[#admin_cards + 1] = stat_card("24s erişim reddi", a.by_action and a.by_action["access.denied"],
      { href = "#/audit-logs?action=access.denied&from=" .. from })
  end
  if app.can("users.list") then
    admin_cards[#admin_cards + 1] = stat_card("Kullanıcı", adm.users_total, { href = "#/users" })
    admin_cards[#admin_cards + 1] = stat_card("Aktif kullanıcı", adm.users_active, { href = "#/users?is_active=true" })
  end

  -- öncelik dağılımı bar'ları (grafik kütüphanesi yok: CSS width)
  local prio_bars = {}
  if stats and stats.by_priority then
    for _, p in ipairs({ "high", "medium", "low" }) do
      local v = tonumber(stats.by_priority[p]) or 0
      local w = total > 0 and math.floor(v * 100 / total) or 0
      prio_bars[#prio_bars + 1] = dom.div({ class = "mb-2" },
        dom.div({ class = "flex justify-between text-sm mb-1" },
          dom.span({}, PRIORITY_LABEL[p]), dom.span({}, tostring(v))),
        dom.div({ class = "h-2 bg-[var(--skeleton)] rounded-full", ["aria-hidden"] = "true" },
          dom.div({ class = "h-2 rounded-full bg-[var(--primary)]", style = "width:" .. w .. "%" })))
    end
  end

  return dom.section({ ["aria-labelledby"] = "dash-title" },
    dom.h1({ id = "dash-title", class = "text-2xl font-bold mb-4", tabindex = "-1" }, "Pano"),
    cards,
    dom.div({ class = "grid md:grid-cols-2 gap-6" },
      dom.section({ ["aria-labelledby"] = "dash-progress" },
        dom.h2({ id = "dash-progress", class = "font-semibold mb-2" }, "Tamamlanma"),
        dom.div({
          class = "h-3 bg-[var(--skeleton)] rounded-full mb-1",
          role = "progressbar", ["aria-valuenow"] = tostring(pct),
          ["aria-valuemin"] = "0", ["aria-valuemax"] = "100",
          ["aria-label"] = "Tamamlanma oranı",
        }, dom.div({ class = "h-3 rounded-full bg-[var(--success)]", style = "width:" .. pct .. "%" })),
        dom.p({ class = "text-sm text-[var(--fg-muted)] mb-4" }, pct .. "% tamamlandı"),
        dom.h2({ class = "font-semibold mb-2" }, "Öncelik dağılımı"),
        prio_bars),
      dom.section({ ["aria-labelledby"] = "dash-recent" },
        dom.h2({ id = "dash-recent", class = "font-semibold mb-2" }, "Son görevler"),
        #recent_items > 0 and dom.ul({ role = "list" }, recent_items)
          or dom.p({ class = "text-[var(--fg-muted)]" }, "Henüz görev yok"))),
    #admin_cards > 0 and dom.section({ class = "mt-6", ["aria-labelledby"] = "dash-admin" },
      dom.h2({ id = "dash-admin", class = "font-semibold mb-2" }, "Yönetim"),
      dom.ul({ class = "grid grid-cols-2 lg:grid-cols-5 gap-3", role = "list" }, admin_cards)))
end

return _M
