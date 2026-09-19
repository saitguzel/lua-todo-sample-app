-- F16: İskelet bileşenleri. Kapsayıcı aria-busy="true" + sr-only duyuru;
-- iskelet öğeleri aria-hidden. Shimmer CSS'te (styles.css), prefers-reduced-motion'da statik.
-- .skeleton-delayed: 200 ms'den kısa yüklemelerde hiç görünmez (CSS animation-delay, JS zamanlayıcı yok).

local dom = require("dom")

local skeleton = {}

local function announce()
  return dom.span({ class = "sr-only" }, "Yükleniyor…")
end

-- dashboard stat kartları
function skeleton.cards(n)
  local items = {}
  for i = 1, (n or 5) do
    items[i] = dom.li({ class = "bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] p-4" },
      dom.div({ class = "skeleton h-4 w-20 mb-2", ["aria-hidden"] = "true" }),
      dom.div({ class = "skeleton h-8 w-12", ["aria-hidden"] = "true" }))
  end
  return dom.ul({ role = "list", ["aria-busy"] = "true",
    class = "skeleton-delayed grid grid-cols-2 lg:grid-cols-5 gap-3" },
    dom.li({ class = "sr-only" }, announce()), items)
end

-- tablo satırları (users, audit)
function skeleton.rows(n, cols)
  local rows = {}
  for i = 1, (n or 5) do
    local cells = {}
    for j = 1, (cols or 5) do
      cells[j] = dom.td({ class = "py-2 pr-3" },
        dom.div({ class = "skeleton h-4", style = "width:" .. (60 + (i * 7 + j * 5) % 40) .. "%",
          ["aria-hidden"] = "true" }))
    end
    rows[i] = dom.tr({}, dom.list(cells))
  end
  return dom.tbody({ ["aria-busy"] = "true", class = "skeleton-delayed" },
    dom.tr({}, dom.td({ colspan = tostring(cols or 5) }, announce())), rows)
end

-- metin satırları (son satır %60 genişlik)
function skeleton.lines(n)
  local items = {}
  for i = 1, (n or 3) do
    local w = i == n and "60%" or "100%"
    items[i] = dom.div({ class = "skeleton h-4 mb-2", style = "width:" .. w, ["aria-hidden"] = "true" })
  end
  return dom.div({ ["aria-busy"] = "true", class = "skeleton-delayed" }, announce(), items)
end

-- todo listesi satırları
function skeleton.todo_items(n)
  local items = {}
  for i = 1, (n or 5) do
    items[i] = dom.li({ class = "py-3 border-b border-[var(--border)] flex items-center gap-3" },
      dom.div({ class = "skeleton h-5 w-5 rounded", ["aria-hidden"] = "true" }),
      dom.div({ class = "flex-1" },
        dom.div({ class = "skeleton h-5 w-2/3 mb-1", ["aria-hidden"] = "true" }),
        dom.div({ class = "skeleton h-3 w-1/3", ["aria-hidden"] = "true" })))
  end
  return dom.ul({ role = "list", ["aria-busy"] = "true", class = "skeleton-delayed" },
    dom.li({ class = "sr-only" }, announce()), items)
end

return skeleton
