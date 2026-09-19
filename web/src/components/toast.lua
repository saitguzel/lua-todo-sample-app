-- F16: Bildirim bileşeni. İki ayrı bölge: hata assertive (#toast-assertive), diğerleri polite (#toast-polite).
-- Bölgeler index.html'de boş olarak baştan vardır (sonradan eklenen live region duyurulmaz).
-- Üzerine gelinince / odaklanınca otomatik kapanma durur.

local dom = require("dom")
local app = require("app")

local toast = {}

local roots = {}  -- bölge adı → { h = handle, tree = vnode }

local ICON = { error = "⚠", success = "✓", info = "ℹ", warning = "!" }

local function render_toast(t)
  local function pause() app.pause_toast(t.id, true) end
  local function resume() app.pause_toast(t.id, false) end
  return dom.div({
    key = t.id,
    class = "toast toast-" .. t.kind
      .. " bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] shadow-[var(--shadow)]"
      .. " p-3 mb-2 flex items-center gap-2 min-w-64",
    ["data-toast-id"] = t.id,
    onmouseenter = pause, onmouseleave = resume, onfocusin = pause, onfocusout = resume,
  },
    dom.span({ class = "icon", ["aria-hidden"] = "true" }, ICON[t.kind] or "ℹ"),
    dom.p({ class = "flex-1 text-sm" },
      t.message .. (t.count and t.count > 1 and (" (×" .. t.count .. ")") or "")),
    t.action and dom.button({
      class = "text-sm text-[var(--primary)] underline",
      onclick = function()
        t.action.fn()
        app.dispatch({ type = "TOAST_DISMISSED", id = t.id })
      end,
    }, t.action.label),
    dom.button({
      class = "text-[var(--fg-muted)] hover:text-[var(--fg)] px-1",
      ["aria-label"] = "Bildirimi kapat",
      onclick = function() app.dispatch({ type = "TOAST_DISMISSED", id = t.id }) end,
    }, "×"))
end

local function patch_region(name, items)
  local r = roots[name]
  if not r then
    local h = js.dom.byId(name)
    if not h then return end
    r = { h = h }
    roots[name] = r
  end
  r.tree = dom.patch(r.h, r.tree, dom.div({}, items))
end

-- app.render_now her render'da çağırır
function toast.render(state)
  local polite, assertive = {}, {}
  for _, t in ipairs(state.ui.toasts or {}) do
    local list = t.kind == "error" and assertive or polite
    list[#list + 1] = render_toast(t)
  end
  patch_region("toast-polite", polite)
  patch_region("toast-assertive", assertive)
end

function toast.success(msg, opts) return app.toast("success", msg, opts) end
function toast.error(msg, opts) return app.toast("error", msg, opts) end
function toast.info(msg, opts) return app.toast("info", msg, opts) end
function toast.dismiss(id) app.dispatch({ type = "TOAST_DISMISSED", id = id }) end

return toast
