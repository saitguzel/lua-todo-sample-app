-- F15: Rol × sayfa yetki matrisi. Tek hücre PATCH optimistic; hata → rollback.
-- Admin'in rbac.matrix hücresi kilitli (kendini kilitleme önlemi, 00 §7).
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local types = require("todo_shared.types")
local protocol = require("todo_shared.protocol")

local _M = {}
_M.title = "Yetki Matrisi"
_M.layout = true

-- API zarfı: { data = { pages, matrix = { role = { page_key = bool } }, roles }, meta = { cache_ttl } }
local function matrix_of(data)
  if type(data) ~= "table" then return nil end
  return data.matrix or data
end

function _M.enter()
  app.dispatch({ type = "RBAC_REQUESTED" })
  local pages = api.get("/rbac/pages") -- etiketler; hata olursa shared PAGE_META kullanılır
  local data, merr, meta = api.get("/rbac/matrix")
  if merr then
    app.dispatch({ type = "RBAC_FAILED" })
    app.toast("error", protocol.message(merr.code))
    return
  end
  app.dispatch({
    type = "RBAC_LOADED",
    pages = type(pages) == "table" and pages.items or pages,
    matrix = matrix_of(data),
    cache_ttl = meta and meta.cache_ttl or nil,
  })
end

-- optimistic tek hücre değişimi
local function toggle_cell(role, page_key, checked)
  app.dispatch({ type = "RBAC_CELL_TOGGLED", role = role, page_key = page_key, can_access = checked })
  local _, err = api.patch("/rbac/matrix/" .. role .. "/" .. page_key, { can_access = checked })
  if err then
    app.dispatch({ type = "RBAC_CELL_ROLLBACK", role = role, page_key = page_key })
    if err.code == "CONFLICT" then
      app.toast("error", "Bu izin kilitli")
    else
      app.toast("error", protocol.message(err.code))
    end
    return
  end
  app.dispatch({ type = "RBAC_CELL_CONFIRMED", role = role, page_key = page_key })
  app.toast("info", role .. " → " .. page_key .. ": " .. (checked and "açık" or "kapalı"), { timeout = 2000 })
  -- admin kendi rolünün iznini değiştirdiyse izinleri tazele
  local me = app.get_state().auth.user
  if me and me.role == role then
    app.refresh_permissions()
  end
end

function _M.render(state, dispatch)
  local st = state.rbac
  local matrix = st.matrix

  if st.status == "error" or (st.status ~= "loading" and st.status ~= "idle" and not matrix) then
    return dom.section({},
      dom.h1({ class = "text-2xl font-bold mb-4", tabindex = "-1" }, "Yetki Matrisi"),
      dom.p({ class = "text-[var(--danger)]", role = "alert" }, "Matris yüklenemedi. Sayfayı yenileyin."))
  end
  if not matrix then
    return dom.section({},
      dom.h1({ class = "text-2xl font-bold mb-4", tabindex = "-1" }, "Yetki Matrisi"),
      require("components.skeleton").lines(9))
  end

  -- API etiketleri (varsa) shared PAGE_META'nın önüne geçer
  local labels = {}
  for _, p in ipairs(type(st.pages) == "table" and st.pages or {}) do
    if type(p) == "table" and p.key then labels[p.key] = p.label end
  end

  local ttl_text = st.cache_ttl and ("Değişiklikler anında kaydedilir. Önbellek nedeniyle diğer oturumlara "
    .. st.cache_ttl .. " sn içinde yansır.") or
    "Değişiklikler anında kaydedilir. Önbellek nedeniyle diğer oturumlara kısa süre içinde yansır."

  local rows = {}
  for _, page in ipairs(types.PAGES) do
    local label = labels[page] or (types.PAGE_META[page] or {}).label or ""
    local cells = {}
    for _, role in ipairs(types.ROLES) do
      local locked = types.is_locked(role, page)
      local cell_pending = st.pending and st.pending[role .. ":" .. page]
      local value = matrix[role] and matrix[role][page] == true
      cells[#cells + 1] = dom.td({ class = "py-2 pr-6" },
        dom.input({
          type = "checkbox",
          checked = value and "checked" or nil,
          disabled = (locked or cell_pending) and "disabled" or nil,
          ["aria-label"] = role .. " rolü için " .. page .. " erişimi",
          ["aria-describedby"] = locked and "lock-note" or nil,
          onchange = function(e)
            toggle_cell(role, page, e.checked == true)
          end,
        }),
        locked and " 🔒" or nil)
    end
    rows[#rows + 1] = dom.tr({ key = page, class = "border-b border-[var(--border)]" },
      dom.th({ scope = "row", class = "py-2 pr-4 text-left font-medium" },
        label, dom.br({}),
        dom.small({ class = "text-[var(--fg-muted)] font-normal" }, dom.code({}, page))),
      cells)
  end

  return dom.section({ class = "max-w-2xl", ["aria-labelledby"] = "rbac-title" },
    dom.h1({ id = "rbac-title", class = "text-2xl font-bold mb-2", tabindex = "-1" }, "Rol – Sayfa Yetkileri"),
    dom.p({ id = "rbac-help", class = "text-sm text-[var(--fg-muted)] mb-4" }, ttl_text),
    dom.table({ ["aria-describedby"] = "rbac-help", class = "w-full text-sm" },
      dom.caption({ class = "sr-only" }, "Rollerin sayfa erişim izinleri"),
      dom.thead({},
        dom.tr({ class = "text-left text-[var(--fg-muted)]" },
          dom.th({ scope = "col", class = "py-2" }, "Sayfa"),
          dom.th({ scope = "col", class = "py-2" }, types.ROLES[1]),
          dom.th({ scope = "col", class = "py-2" }, types.ROLES[2]))),
      dom.tbody({ ["aria-busy"] = tostring(st.status == "loading") }, rows)),
    dom.p({ id = "lock-note", class = "text-xs text-[var(--fg-muted)] mt-2" },
      "Admin'in yetki matrisi erişimi kilitlidir (kendini kilitleme önlemi)."),
    dom.footer({ class = "mt-6" },
      dom.button({
        type = "button",
        class = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)]",
        onclick = function()
          app.spawn(function()
            if not require("components.modal").confirm({ title = "Varsayılana sıfırlansın mı?",
              message = "Tüm izinler fabrika ayarlarına dönecek.", confirm_label = "Sıfırla" }) then
              return
            end
            local data, err = api.put("/rbac/matrix", types.default_matrix())
            if err then
              app.toast("error", protocol.message(err.code))
              return
            end
            app.dispatch({ type = "RBAC_MATRIX_REPLACED", matrix = matrix_of(data) })
            app.toast("success", "Matris varsayılana sıfırlandı")
            app.refresh_permissions()
          end)
        end,
      }, "Varsayılana sıfırla")))
end

return _M
