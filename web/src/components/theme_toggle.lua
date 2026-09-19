-- F16: Tema tercihi: "light" | "dark" | "system". data-theme attribute'u tüm UI'ı çevirir;
-- "system" seçiliyken OS teması değişirse anında uygulanır (app.start media dinleyicisi).

local dom = require("dom")

local theme_toggle = {}

-- header'daki kompakt sürüm: tek buton, döngüsel geçiş
function theme_toggle.render_compact(state, dispatch)
  local order = { "light", "dark", "system" }
  local next_pref = "system"
  for i, p in ipairs(order) do
    if p == state.ui.theme then next_pref = order[(i % #order) + 1] break end
  end
  local icon = state.ui.theme == "dark" and "☾" or (state.ui.theme == "system" and "🖥" or "☀")
  local label = ({ light = "Açık", dark = "Koyu", system = "Sistem" })[state.ui.theme] or state.ui.theme
  return dom.button({
    class = "px-2 py-1 rounded-[var(--radius)] border border-[var(--border)]",
    ["aria-label"] = "Tema: " .. label .. ". Değiştir",
    onclick = function() dispatch({ type = "THEME_SET", theme = next_pref }) end,
  }, icon)
end

-- profil sayfasındaki radiogroup sürümü
function theme_toggle.render(state, dispatch)
  local current = state.ui.theme
  local options = {
    { pref = "light", icon = "☀", label = "Açık" },
    { pref = "dark", icon = "☾", label = "Koyu" },
    { pref = "system", icon = "🖥", label = "Sistem" },
  }
  local buttons = {}
  for _, o in ipairs(options) do
    buttons[#buttons + 1] = dom.button({
      role = "radio",
      ["aria-checked"] = tostring(current == o.pref),
      class = "px-3 py-1.5 rounded-[var(--radius)] border "
        .. (current == o.pref and "border-[var(--primary)] text-[var(--primary)]" or "border-[var(--border)]"),
      onclick = function() dispatch({ type = "THEME_SET", theme = o.pref }) end,
    }, o.icon .. " " .. o.label)
  end
  return dom.div({ role = "radiogroup", ["aria-label"] = "Tema", class = "flex gap-2" }, dom.list(buttons))
end

return theme_toggle
