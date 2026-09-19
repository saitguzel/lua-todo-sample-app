-- F13/F15: Layout — üst bar (tema, kullanıcı, çıkış), izin bazlı yan menü, 403/404/iskelet blokları
-- ve view'ların paylaştığı küçük parçalar (boş durum, sayfalama, sıralanabilir tablo başlığı).
-- View'lar render(state, dispatch) → vnode sözleşmesini izler (faz-14); içerik #main içine konur.

local dom = require("dom")
local router = require("router")
local app = require("app")
local theme_toggle = require("components.theme_toggle")

local layout = {}

-- Menü öğeleri; görünürlük tamamen izne bağlı (F15)
local NAV = {
  { href = "#/", label = "Pano", page_key = "dashboard", icon = "▦", routes = { dashboard = true } },
  { href = "#/todos", label = "Todo'lar", page_key = "todos.list", icon = "✓",
    routes = { todos = true, todos_new = true, todo_edit = true } },
  { href = "#/users", label = "Kullanıcılar", page_key = "users.list", icon = "👥", routes = { users = true } },
  { href = "#/rbac", label = "Yetkiler", page_key = "rbac.matrix", icon = "🔐", routes = { rbac = true } },
  { href = "#/audit-logs", label = "Denetim", page_key = "audit.logs", icon = "☰", routes = { audit = true } },
}

function layout.render(state, dispatch, content, title)
  local auth = state.auth
  local user = auth.user or {}
  local nav_items = {}
  for _, item in ipairs(NAV) do
    if router.can(auth, item.page_key) then
      local active = item.routes[state.route.name or ""] == true
      nav_items[#nav_items + 1] = dom.li({},
        dom.a({
          href = item.href,
          class = active
            and "nav-link flex items-center gap-2 px-3 py-2 rounded-[var(--radius)] bg-[var(--primary)] " ..
              "text-[var(--primary-fg)]"
            or "nav-link flex items-center gap-2 px-3 py-2 rounded-[var(--radius)] hover:bg-[var(--bg)]",
          ["aria-current"] = active and "page" or nil,
        }, dom.span({ ["aria-hidden"] = "true" }, item.icon), item.label))
    end
  end

  return dom.div({ class = "min-h-screen flex" },
    -- yan menü (mobilde hamburger ile açılır)
    dom.aside({
      id = "sidebar",
      ["aria-label"] = "Ana menü",
      class = state.ui.sidebar_open
        and "sidebar sidebar-open w-60 border-r border-[var(--border)] bg-[var(--bg-elev)] p-4"
        or "sidebar hidden md:block w-60 border-r border-[var(--border)] bg-[var(--bg-elev)] p-4",
    },
      dom.nav({ ["aria-label"] = "Sayfalar" }, dom.ul({ class = "space-y-1", role = "list" }, nav_items))),
    -- ana kolon
    dom.div({ class = "flex-1 flex flex-col min-w-0" },
      dom.header({ class = "flex items-center justify-between gap-2 h-14 px-4 border-b border-[var(--border)]" },
        dom.div({ class = "flex items-center gap-3 min-w-0" },
          dom.button({
            type = "button",
            class = "md:hidden text-xl w-11 h-11", ["aria-label"] = "Menüyü aç",
            ["aria-controls"] = "sidebar", ["aria-expanded"] = tostring(state.ui.sidebar_open),
            onclick = function() dispatch({ type = "SIDEBAR_TOGGLED" }) end,
          }, "☰"),
          dom.span({ class = "text-lg font-semibold truncate" }, "Todo")),
        dom.div({ class = "flex items-center gap-2 md:gap-3" },
          theme_toggle.render_compact(state, dispatch),
          dom.a({ href = "#/profile", class = "text-sm text-[var(--fg-muted)] hover:underline truncate max-w-40",
            ["aria-current"] = state.route.name == "profile" and "page" or nil }, user.email or "Profil"),
          dom.button({
            type = "button",
            class = "text-sm px-3 py-1.5 rounded-[var(--radius)] border border-[var(--border)] " ..
              "hover:bg-[var(--bg-elev)]",
            onclick = function() app.logout() end,
          }, "Çıkış"))),
      dom.main({ id = "main", tabindex = "-1", class = "flex-1 p-4 md:p-6 min-w-0",
        ["aria-label"] = title }, content)))
end

-- Oturum kontrolü sürerken tam sayfa iskelet
function layout.boot_skeleton()
  return dom.div({ class = "min-h-screen flex items-center justify-center", ["aria-busy"] = "true" },
    dom.span({ class = "sr-only" }, "Yükleniyor…"),
    dom.div({ class = "skeleton w-64 h-8", ["aria-hidden"] = "true" }))
end

-- Ayrı bundle'daki sayfa yüklenirken içerik iskeleti
function layout.page_skeleton()
  return require("components.skeleton").lines(6)
end

-- 403: yönlendirme değil, içerik (faz-13 karar) — layout içinde gösterilir
function layout.forbidden_page()
  return dom.section({ class = "p-8 max-w-md mx-auto text-center" },
    dom.h1({ class = "text-2xl font-bold mb-2", tabindex = "-1" }, "Bu sayfaya erişim yetkiniz yok"),
    dom.p({ class = "text-[var(--fg-muted)] mb-4" }, "Bu alan için gerekli izin verilmedi. Yöneticinizle görüşün."),
    dom.a({ href = "#/", class = "text-[var(--primary)] underline" }, "Panoya dön"))
end

-- Boş durum yardımcısı (F16: todos, users, audit)
function layout.empty_state(opts)
  return dom.div({ class = "text-center py-16" },
    dom.div({ class = "text-4xl mb-3", ["aria-hidden"] = "true" }, opts.icon or "∅"),
    dom.h2({ class = "text-lg font-semibold mb-1" }, opts.title or "Kayıt yok"),
    dom.p({ class = "text-[var(--fg-muted)] mb-4" }, opts.text or ""),
    opts.action_label and dom.button({
      type = "button",
      class = "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]",
      onclick = opts.on_action,
    }, opts.action_label))
end

-- Sayfalama: meta = { page, total_pages, total }; on_page(n)
function layout.pagination(meta, on_page)
  meta = meta or {}
  local page, pages = tonumber(meta.page) or 1, tonumber(meta.total_pages) or 1
  if pages <= 1 then return nil end
  local btn = "px-3 py-1.5 min-h-11 border border-[var(--border)] rounded-[var(--radius)] disabled:opacity-40"
  return dom.nav({ ["aria-label"] = "Sayfalama", class = "flex items-center justify-center gap-4 mt-4" },
    dom.button({
      type = "button", class = btn, disabled = page <= 1 and "disabled" or nil,
      ["aria-label"] = "Önceki sayfa",
      onclick = function() on_page(math.max(page - 1, 1)) end,
    }, "‹ Önceki"),
    dom.span({ class = "text-sm text-[var(--fg-muted)]", ["aria-current"] = "page" },
      "Sayfa " .. page .. " / " .. pages),
    dom.button({
      type = "button", class = btn, disabled = page >= pages and "disabled" or nil,
      ["aria-label"] = "Sonraki sayfa",
      onclick = function() on_page(page + 1) end,
    }, "Sonraki ›"))
end

-- Sıralanabilir sütun başlığı: sort = "field" | "-field"; aria-sort ekran okuyucuya bildirir
function layout.sort_th(label, field, sort, on_sort, class)
  local dir = "none"
  if sort == field then dir = "ascending" elseif sort == "-" .. field then dir = "descending" end
  local next_sort = dir == "ascending" and ("-" .. field) or field
  return dom.th({ scope = "col", class = class or "py-2 pr-3", ["aria-sort"] = dir },
    dom.button({
      type = "button", class = "inline-flex items-center gap-1 font-inherit hover:underline",
      onclick = function() on_sort(next_sort) end,
    }, label, dom.span({ ["aria-hidden"] = "true" },
      dir == "ascending" and "▲" or (dir == "descending" and "▼" or "↕"))))
end

return layout
