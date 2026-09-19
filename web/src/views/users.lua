-- F15: Kullanıcı yönetimi. Optimistic YOK (LAST_ADMIN/EMAIL_TAKEN olası) — kaydet + spinner.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local shortcuts = require("shortcuts")
local validation = require("todo_shared.validation")
local protocol = require("todo_shared.protocol")

local _M = {}
_M.title = "Kullanıcılar"
_M.layout = true

local debounce_id = nil

local function load_users(filters)
  app.dispatch({ type = "USERS_REQUESTED", filters = filters })
  local q = {}
  for k, v in pairs(filters or {}) do
    if v ~= nil and v ~= "" then q[k] = v end
  end
  local data, err = api.get("/users", q)
  if err then
    app.dispatch({ type = "USERS_FAILED", error = err })
    return
  end
  app.dispatch({ type = "USERS_LOADED", items = data.items, meta = data.meta })
end

-- Filtreler URL'dedir (#/users?role=admin&page=2); enter her hash değişiminde yeniden yükler
function _M.enter(route)
  local q = route.query or {}
  load_users({
    q = q.q, role = q.role, is_active = q.is_active,
    sort = q.sort or "email", page = tonumber(q.page) or 1, per_page = 20,
  })
end

local function set_filters(patch)
  if patch.page == nil then patch.page = "" end -- filtre değişince 1. sayfaya dön
  router.replace_query(patch)
end

local function reload()
  app.spawn(load_users, app.get_state().users.filters)
end

local function close_form()
  app.dispatch({ type = "USER_EDIT_CLOSED" })
end

shortcuts.register("users", "n", function()
  if app.can("users.create") then app.dispatch({ type = "USER_EDIT_OPENED", id = "new" }) return true end
end, "Yeni kullanıcı")
shortcuts.register("users", "/", function() dom.focus("user-search"); return true end, "Ara")

-- form modalı
local function user_form(state)
  local errors = (state.ui.form_errors or {}).user or {}
  local editing = state.users.editing
  local user = nil
  if editing and editing ~= "new" then
    local idx = state.users.by_id[editing]
    user = idx and state.users.items[idx] or nil
  end
  local is_edit = user ~= nil
  local me = state.auth.user or {}

  local role_opts = {}
  for _, r in ipairs(require("todo_shared.types").ROLES) do
    role_opts[#role_opts + 1] = dom.option({
      value = r,
      selected = ((user and user.role or "todouser") == r) and "selected" or nil,
      -- kendi rolünü düşürme UI'da da engellenir (API SELF_ACTION_FORBIDDEN döner)
      disabled = (is_edit and user.id == me.id and r ~= me.role) and "disabled" or nil,
    }, r)
  end

  return dom.form({
    class = "space-y-3",
    novalidate = "novalidate",
    onsubmit = function()
      local input = {
        email = dom.value("user-email") or "",
        full_name = dom.value("user-fullname") or "",
        role = dom.value("user-role"),
        is_active = dom.checked("user-active"),
      }
      if input.full_name == "" then input.full_name = nil end
      -- kendi hesabında rol select'i disabled: değeri gönderilmez
      if is_edit and user.id == me.id then input.role = nil end
      local pw = dom.value("user-password") or ""
      if pw ~= "" then input.password = pw end
      app.spawn(function()
        local clean, errs = validation.validate(
          is_edit and validation.schemas.user_update or validation.schemas.user_create, input)
        if not clean then
          app.dispatch({ type = "FORM_ERRORS_SET", form = "user", errors = errs })
          js.timer.after(0, function()
            dom.focus(errs.email and "user-email" or (errs.password and "user-password" or "user-fullname"))
          end)
          return
        end
        app.dispatch({ type = "USER_SAVE_REQUESTED" })
        local _, err
        if is_edit then
          _, err = api.put("/users/" .. user.id, clean)
        else
          _, err = api.post("/users", clean)
        end
        if err then
          app.dispatch({ type = "USER_SAVE_FAILED" })
          if err.code == "EMAIL_TAKEN" then
            app.dispatch({ type = "FORM_ERRORS_SET", form = "user", errors = { email = { "Bu e-posta zaten kullanılıyor" } } })
            js.timer.after(0, function() dom.focus("user-email") end)
          elseif err.code == "VALIDATION_FAILED" then
            app.dispatch({ type = "FORM_ERRORS_SET", form = "user", errors = err.details or {} })
          elseif err.code == "LAST_ADMIN" then
            app.dispatch({ type = "FORM_ERRORS_SET", form = "user",
              errors = { _ = { "Sistemdeki son aktif admin silinemez veya düşürülemez" } } })
          elseif err.code == "SELF_ACTION_FORBIDDEN" then
            app.dispatch({ type = "FORM_ERRORS_SET", form = "user",
              errors = { _ = { "Kendi hesabınızı silemez veya rolünüzü düşüremezsiniz" } } })
          else
            app.dispatch({ type = "FORM_ERRORS_SET", form = "user",
              errors = { _ = { protocol.message(err.code) } } })
          end
          return
        end
        app.dispatch({ type = "USER_SAVED" })
        app.dispatch({ type = "USER_EDIT_CLOSED" })
        app.toast("success", is_edit and "Kullanıcı güncellendi" or "Kullanıcı oluşturuldu")
        -- kendi hesabı değiştiyse üst bardaki bilgi tazelensin
        if is_edit and user.id == me.id then app.refresh_permissions() end
        reload()
      end)
      return false
    end,
  },
    dom.div({ role = "alert", class = errors._ and "field-error mb-2" or "" }, errors._ and errors._[1] or nil),
    dom.div({},
      dom.label({ ["for"] = "user-email", class = "block text-sm font-medium mb-1" }, "E-posta"),
      dom.input({
        id = "user-email", type = "email", required = "required",
        class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
        value = user and user.email or nil,
        ["aria-invalid"] = errors.email and "true" or nil,
        ["aria-describedby"] = errors.email and "user-email-err" or nil,
      }),
      errors.email and dom.p({ id = "user-email-err", class = "field-error" }, errors.email[1]) or nil),
    dom.div({},
      dom.label({ ["for"] = "user-fullname", class = "block text-sm font-medium mb-1" }, "Ad Soyad"),
      dom.input({
        id = "user-fullname", type = "text", maxlength = "255",
        class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
        value = user and user.full_name or nil,
      })),
    dom.div({},
      dom.label({ ["for"] = "user-password", class = "block text-sm font-medium mb-1" },
        is_edit and "Yeni parola (boş = değişmez)" or "Parola"),
      dom.div({ class = "flex gap-2" },
        dom.input({
          id = "user-password", type = "text", minlength = "8", autocomplete = "new-password",
          required = (not is_edit) and "required" or nil,
          ["aria-invalid"] = errors.password and "true" or nil,
          ["aria-describedby"] = errors.password and "user-password-err" or nil,
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
        }),
        dom.button({
          type = "button",
          class = "px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] text-sm whitespace-nowrap",
          onclick = function()
            local pw = js.random_password(16)
            dom.set_value("user-password", pw)
            js.clipboard(pw) -- panoya kopyalanır, başka hiçbir yerde saklanmaz
            app.toast("info", "Parola oluşturuldu ve panoya kopyalandı")
          end,
        }, "Oluştur")),
      errors.password and dom.p({ id = "user-password-err", class = "field-error" }, errors.password[1]) or nil),
    dom.div({ class = "grid grid-cols-2 gap-3" },
      dom.div({},
        dom.label({ ["for"] = "user-role", class = "block text-sm font-medium mb-1" }, "Rol"),
        dom.select({
          id = "user-role",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          disabled = is_edit and user.id == me.id and "disabled" or nil,
        }, dom.list(role_opts))),
      dom.div({ class = "flex items-end gap-2 pb-2" },
        dom.input({ id = "user-active", type = "checkbox",
          checked = (not user or user.is_active) and "checked" or nil }),
        dom.label({ ["for"] = "user-active" }, "Aktif"))),
    dom.div({ class = "flex justify-end gap-2 pt-2" },
      dom.button({ type = "button", class = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)]",
        onclick = close_form }, "İptal"),
      dom.button({
        type = "submit", ["aria-busy"] = tostring(state.users.saving),
        disabled = state.users.saving and "disabled" or nil,
        class = "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] disabled:opacity-50",
      }, state.users.saving and "Kaydediliyor…" or "Kaydet")))
end

local function delete_user(u)
  app.spawn(function()
    if not require("components.modal").confirm({ title = "Silinsin mi?",
      message = (u.email or "") .. " kalıcı olarak silinecek.", confirm_label = "Sil", danger = true }) then
      return
    end
    local _, err = api.delete("/users/" .. u.id)
    if err then
      local msg = ({ LAST_ADMIN = "Sistemdeki son aktif admin silinemez",
        SELF_ACTION_FORBIDDEN = "Kendi hesabınızı silemezsiniz" })[err.code] or protocol.message(err.code)
      app.toast("error", msg)
      if err.code == "USER_NOT_FOUND" then app.dispatch({ type = "USER_REMOVED", id = u.id }) end
      return
    end
    app.dispatch({ type = "USER_REMOVED", id = u.id })
    app.toast("success", "Kullanıcı silindi")
  end)
end

local function fmt(ts)
  return type(ts) == "string" and js.format_date(ts) or "—"
end

function _M.render(state, dispatch)
  local st = state.users
  local meta = st.meta or {}
  local me = state.auth.user or {}
  local f = st.filters or {}
  local layout = require("views.layout")
  local can_manage = app.can("users.create")
  local function on_sort(v) set_filters({ sort = v }) end

  local body
  if st.status == "loading" and #st.items == 0 then
    body = require("components.skeleton").rows(5, 7)
  else
    local rows = {}
    for _, u in ipairs(st.items) do
      local is_self = me.id == u.id
      rows[#rows + 1] = dom.tr({ key = u.id, ["data-id"] = u.id, class = "border-b border-[var(--border)]" },
        dom.th({ scope = "row", class = "py-2 pr-3 font-normal text-left", ["data-label"] = "E-posta" }, u.email or ""),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Ad" }, type(u.full_name) == "string" and u.full_name or "—"),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Rol" },
          dom.span({ class = "badge badge-role-" .. (u.role or "todouser") }, u.role or "")),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Durum" },
          dom.span({ class = "dot", ["aria-hidden"] = "true" }, u.is_active and "● " or "○ "),
          u.is_active and "Aktif" or "Pasif"),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Son giriş" }, fmt(u.last_login_at)),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Oluşturulma" }, fmt(u.created_at)),
        dom.td({ class = "py-2 pr-3 text-right", ["data-label"] = "İşlemler" },
          can_manage and dom.button({
            type = "button", class = "px-2 py-1 min-w-11 min-h-11 text-sm rounded hover:bg-[var(--bg-elev)] mr-1",
            ["aria-label"] = (u.email or "") .. " düzenle",
            onclick = function() app.dispatch({ type = "USER_EDIT_OPENED", id = u.id }) end,
          }, "✎"),
          can_manage and dom.button({
            type = "button", class = "px-2 py-1 min-w-11 min-h-11 text-sm rounded text-[var(--danger)] hover:bg-[var(--bg-elev)] disabled:opacity-40",
            ["aria-label"] = (u.email or "") .. " sil",
            disabled = is_self and "disabled" or nil,
            title = is_self and "Kendi hesabınızı silemezsiniz" or nil,
            onclick = function() if not is_self then delete_user(u) end end,
          }, "🗑")))
    end
    body = dom.tbody({ ["aria-busy"] = tostring(st.status == "loading") }, rows)
  end

  local table_or_empty
  if st.status ~= "loading" and #st.items == 0 then
    table_or_empty = layout.empty_state({ icon = "👥", title = "Kullanıcı bulunamadı",
      text = (f.q or f.role or f.is_active) and "Bu filtrelerle eşleşen kullanıcı yok" or "",
      action_label = (f.q or f.role or f.is_active) and "Filtreleri temizle" or nil,
      on_action = function() router.navigate("#/users") end })
  else
    table_or_empty = dom.div({ class = "overflow-x-auto" },
      dom.table({ class = "w-full text-sm responsive-table" },
        dom.caption({ class = "sr-only" }, "Kullanıcı listesi, " .. (meta.total or 0) .. " kayıt"),
        dom.thead({},
          dom.tr({ class = "text-left text-[var(--fg-muted)]" },
            layout.sort_th("E-posta", "email", f.sort, on_sort),
            layout.sort_th("Ad", "full_name", f.sort, on_sort),
            layout.sort_th("Rol", "role", f.sort, on_sort),
            dom.th({ scope = "col", class = "py-2 pr-3" }, "Durum"),
            layout.sort_th("Son giriş", "last_login_at", f.sort, on_sort),
            layout.sort_th("Oluşturulma", "created_at", f.sort, on_sort),
            dom.th({ scope = "col", class = "py-2 pr-3 text-right" }, "İşlemler"))),
        body))
  end

  local modal = nil
  if st.editing then
    modal = require("components.modal").dialog("user-edit",
      st.editing == "new" and "Yeni kullanıcı" or "Kullanıcı düzenle", user_form(state), close_form)
  end

  local select_cls = "px-3 py-2 min-h-11 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm text-[var(--fg)]"
  return dom.section({ ["aria-labelledby"] = "users-title" },
    dom.header({ class = "flex items-center justify-between gap-2 mb-4" },
      dom.h1({ id = "users-title", class = "text-2xl font-bold", tabindex = "-1" },
        "Kullanıcılar" .. ((tonumber(meta.total) or 0) > 0 and (" (" .. meta.total .. ")") or "")),
      can_manage and dom.button({
        type = "button",
        class = "px-4 py-2 min-h-11 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]",
        ["aria-keyshortcuts"] = "n",
        onclick = function() app.dispatch({ type = "USER_EDIT_OPENED", id = "new" }) end,
      }, "+ Kullanıcı ekle")),
    dom.form({ role = "search", ["aria-label"] = "Kullanıcı filtreleri", class = "flex flex-wrap items-end gap-2 mb-4" },
      dom.label({ class = "flex flex-col text-xs text-[var(--fg-muted)] flex-1 min-w-40" }, "Ara",
        dom.input({
          type = "search", id = "user-search", placeholder = "E-posta veya ad… (/)", ["aria-keyshortcuts"] = "/",
          class = select_cls, value = f.q or "",
          oninput = function(e)
            if debounce_id then js.timer.cancel(debounce_id) end
            local v = e.value or ""
            debounce_id = js.timer.after(300, function() set_filters({ q = v }) end)
          end,
        })),
      dom.div({ class = "flex flex-col" },
        dom.label({ ["for"] = "user-filter-1", class = "text-xs text-[var(--fg-muted)]" }, "Rol"),
        dom.select({ id = "user-filter-1", class = select_cls, onchange = function(e) set_filters({ role = e.value or "" }) end },
          dom.option({ value = "" }, "Tüm roller"),
          dom.option({ value = "admin", selected = f.role == "admin" and "selected" or nil }, "admin"),
          dom.option({ value = "todouser", selected = f.role == "todouser" and "selected" or nil }, "todouser"))),
      dom.div({ class = "flex flex-col" },
        dom.label({ ["for"] = "user-filter-2", class = "text-xs text-[var(--fg-muted)]" }, "Durum"),
        dom.select({ id = "user-filter-2", class = select_cls, onchange = function(e) set_filters({ is_active = e.value or "" }) end },
          dom.option({ value = "" }, "Tümü"),
          dom.option({ value = "true", selected = f.is_active == "true" and "selected" or nil }, "Aktif"),
          dom.option({ value = "false", selected = f.is_active == "false" and "selected" or nil }, "Pasif")))),
    table_or_empty,
    layout.pagination(meta, function(p) set_filters({ page = tostring(p) }) end),
    modal)
end

return _M
