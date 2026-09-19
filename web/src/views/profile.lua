-- F14: Profil — /auth/me bilgileri, tema tercihi (Açık/Koyu/Sistem), kısayollar, çıkış.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local theme_toggle = require("components.theme_toggle")
local shortcuts = require("shortcuts")

local _M = {}
_M.title = "Profil"
_M.layout = true

-- Sunucudaki güncel bilgi (son giriş, rol değişikliği) için /auth/me tazelenir
function _M.enter()
  local data, err = api.get("/auth/me")
  if data and data.user then
    app.dispatch({ type = "USER_LOADED", user = data.user, permissions = data.permissions })
  elseif err then
    app.toast("error", "Profil bilgisi alınamadı")
  end
end

local SHORTCUTS = {
  { "n", "Yeni todo" }, { "e", "Seçili todo'yu düzenle" }, { "d", "Seçili todo'yu sil" },
  { "/", "Ara" }, { "Esc", "Pencereyi kapat" }, { "?", "Kısayol yardımı" },
}

local function card(title_id, title, ...)
  return dom.section({ class = "bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] p-6 mb-6",
    ["aria-labelledby"] = title_id },
    dom.h2({ id = title_id, class = "font-semibold mb-3" }, title), ...)
end

function _M.render(state, dispatch)
  local user = state.auth.user or {}

  local shortcut_rows = {}
  for _, s in ipairs(SHORTCUTS) do
    shortcut_rows[#shortcut_rows + 1] = dom.tr({},
      dom.td({ class = "py-1 pr-4" }, dom.kbd({ class = "px-2 py-0.5 border border-[var(--border)] rounded text-sm" },
        s[1])),
      dom.td({ class = "py-1 text-[var(--fg-muted)]" }, s[2]))
  end

  return dom.section({ class = "max-w-2xl", ["aria-labelledby"] = "profile-title" },
    dom.h1({ id = "profile-title", class = "text-2xl font-bold mb-4", tabindex = "-1" }, "Profil"),
    card("profile-account", "Hesap",
      dom.dl({ class = "grid grid-cols-[10rem_1fr] gap-y-2" },
        dom.dt({ class = "text-[var(--fg-muted)]" }, "Ad"),
        dom.dd({}, user.full_name or "—"),
        dom.dt({ class = "text-[var(--fg-muted)]" }, "E-posta"),
        dom.dd({}, user.email or "—"),
        dom.dt({ class = "text-[var(--fg-muted)]" }, "Rol"),
        dom.dd({}, dom.span({ class = "badge badge-role-" .. (user.role or "todouser") }, user.role or "—")),
        dom.dt({ class = "text-[var(--fg-muted)]" }, "Son giriş"),
        dom.dd({}, type(user.last_login_at) == "string" and js.format_date(user.last_login_at) or "—"))),
    card("profile-theme", "Görünüm", theme_toggle.render(state, dispatch)),
    card("profile-keys", "Klavye kısayolları",
      dom.div({ class = "flex items-center gap-2 mb-3" },
        dom.input({
          id = "shortcuts-enabled", type = "checkbox", class = "w-5 h-5",
          checked = shortcuts.enabled() and "checked" or nil,
          onchange = function(e)
            shortcuts.set_enabled(e.checked == true)
            local msg = e.checked and "Tek tuş kısayolları açık" or "Tek tuş kısayolları kapalı"
            app.toast("info", msg, { timeout = 2000 })
          end,
        }),
        dom.label({ ["for"] = "shortcuts-enabled" }, "Tek tuş kısayollarını kullan")),
      dom.table({ class = "text-sm" },
        dom.caption({ class = "sr-only" }, "Klavye kısayolları"),
        dom.thead({ class = "sr-only" }, dom.tr({},
          dom.th({ scope = "col" }, "Tuş"), dom.th({ scope = "col" }, "İşlev"))),
        dom.tbody({}, shortcut_rows))),
    dom.button({
      type = "button",
      class = "px-4 py-2 rounded-[var(--radius)] border border-[var(--danger)] text-[var(--danger)] " ..
        "hover:bg-[var(--bg-elev)]",
      onclick = function() app.logout() end,
    }, "Çıkış yap"))
end

return _M
