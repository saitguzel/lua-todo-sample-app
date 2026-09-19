-- F16: Modal bileşeni. Native <dialog> + showModal(): focus trap, inert arka plan ve Esc tarayıcıdan gelir.
-- Esc (cancel olayı) varsayılanı engellenir, kapanış Lua state'i üzerinden olur; odak dialog DOM'dan
-- kalkınca tetikleyen öğeye döner (glue.js returnFocus). modal.confirm coroutine ile cevabı bekler.

local dom = require("dom")
local app = require("app")

local modal = {}

local open_modals = {} -- { id, title, render_fn, co }
local root = { h = nil, tree = nil }

local function changed() app.dispatch({ type = "MODAL_CHANGED" }) end

-- Açık bileşen dialog'unu kapatır; confirm ise bekleyen coroutine'i cevapla sürdürür
local function finish(id, answer)
  local m
  for i, x in ipairs(open_modals) do
    if x.id == id then m = table.remove(open_modals, i) break end
  end
  if not m then return end
  changed()
  if m.co then
    local ok, err = coroutine.resume(m.co, answer)
    if not ok then js.log("error", "modal coroutine hatası: " .. tostring(err)) end
  end
end

-- Genel dialog vnode'u: view'lar form modalları için doğrudan kullanır.
-- on_close: Esc veya kapat düğmesi. opts.class ile boyut/konum (ör. yan çekmece) değiştirilebilir.
function modal.dialog(id, title, content, on_close, opts)
  opts = opts or {}
  return dom.dialog({
    key = id,
    id = id,
    ["data-modal"] = "1",
    ["aria-labelledby"] = id .. "-title",
    ["aria-describedby"] = opts.describedby,
    class = opts.class or "modal bg-[var(--bg-elev)] text-[var(--fg)] border border-[var(--border)] " ..
      "rounded-[var(--radius)] p-6 w-full max-w-lg",
    oncancel = function() if on_close then on_close() end end,
  },
    dom.div({ class = "flex items-start justify-between gap-4 mb-4" },
      dom.h2({ id = id .. "-title", class = "text-lg font-semibold" }, title),
      on_close and dom.button({
        type = "button", class = "px-2 -mt-1 text-[var(--fg-muted)] hover:text-[var(--fg)]",
        ["aria-label"] = "Kapat", onclick = on_close,
      }, "✕")),
    content)
end

-- Coroutine confirm: kullanıcı cevabına kadar yield; İptal/Esc → false, onay → true
function modal.confirm(opts)
  opts = opts or {}
  local co, is_main = coroutine.running()
  assert(not is_main, "modal.confirm bir coroutine içinde çağrılmalı (app.spawn kullanın)")
  local id = "confirm-" .. tostring(#open_modals + 1)
  open_modals[#open_modals + 1] = {
    id = id,
    title = opts.title or "Onay",
    co = co,
    describedby = id .. "-desc",
    render_fn = function()
      return dom.div({ class = "space-y-4" },
        dom.p({ id = id .. "-desc", class = "text-sm" }, opts.message or ""),
        dom.div({ class = "flex justify-end gap-2" },
          dom.button({
            type = "button",
            class = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)]",
            autofocus = "autofocus", -- yıkıcı işlemlerde güvenli varsayılan: İptal
            onclick = function() finish(id, false) end,
          }, opts.cancel_label or "İptal"),
          dom.button({
            type = "button",
            class = opts.danger
              and "px-4 py-2 rounded-[var(--radius)] bg-[var(--danger)] text-white"
              or "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]",
            onclick = function() finish(id, true) end,
          }, opts.confirm_label or "Tamam")))
    end,
  }
  changed()
  return coroutine.yield() == true
end

-- "?" kısayolu: kayıtlı kısayolların listesi
function modal.help()
  for _, m in ipairs(open_modals) do
    if m.id == "shortcut-help" then return end
  end
  open_modals[#open_modals + 1] = {
    id = "shortcut-help",
    title = "Klavye kısayolları",
    render_fn = function()
      local rows = {}
      for _, s in ipairs(require("shortcuts").list()) do
        rows[#rows + 1] = dom.tr({},
          dom.td({ class = "py-1 pr-4" },
            dom.kbd({ class = "px-2 py-0.5 border border-[var(--border)] rounded text-sm" },
              s.key == "Escape" and "Esc" or s.key)),
          dom.td({ class = "py-1 text-[var(--fg-muted)]" }, s.description))
      end
      rows[#rows + 1] = dom.tr({},
        dom.td({ class = "py-1 pr-4" },
          dom.kbd({ class = "px-2 py-0.5 border border-[var(--border)] rounded text-sm" }, "Esc")),
        dom.td({ class = "py-1 text-[var(--fg-muted)]" }, "Pencereyi kapat"))
      return dom.table({ class = "text-sm" },
        dom.caption({ class = "sr-only" }, "Kısayollar"),
        dom.tbody({}, rows))
    end,
  }
  changed()
end

function modal.is_open() return #open_modals > 0 end

-- app.render_now her render'da çağırır: bileşen dialog'larını #modal-root'a patch eder
function modal.render(_state)
  if not root.h then
    root.h = js.dom.byId("modal-root")
    if not root.h then return end
  end
  local children = {}
  for _, m in ipairs(open_modals) do
    children[#children + 1] = modal.dialog(m.id, m.title, m.render_fn(),
      function() finish(m.id, false) end, { describedby = m.describedby })
  end
  root.tree = dom.patch(root.h, root.tree, dom.div({}, children))
end

return modal
