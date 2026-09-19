-- F14: Todo listesi — CRUD + filtre + optimistic UI (snapshot rollback).
-- Filtreler ve düzenleme durumu URL'dedir (#/todos?status=..., #/todos/new, #/todos/:id): geri tuşu çalışır.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local shortcuts = require("shortcuts")
local types = require("todo_shared.types")
local validation = require("todo_shared.validation")
local protocol = require("todo_shared.protocol")

local _M = {}
_M.title = "Todo'lar"
_M.layout = true

local PRIORITY_LABEL = { high = "Yüksek", medium = "Orta", low = "Düşük" }
local STATUS_LABEL = { pending = "Bekliyor", in_progress = "Devam ediyor", completed = "Tamamlandı" }
local DEFAULT_SORT = "-created_at"
local FILTER_KEYS = { "status", "priority", "q", "tag", "sort", "page" }

local temp_seq = 0
local debounce_id = nil

-- --- URL ↔ filtre ------------------------------------------------------------------

-- Saf: route query → API filtreleri (F17 views_spec gidiş-dönüş testi)
function _M.filters_from_query(q)
  q = q or {}
  return {
    status = q.status, priority = q.priority, q = q.q, tag = q.tag,
    sort = q.sort or DEFAULT_SORT,
    page = tonumber(q.page) or 1, per_page = 20,
  }
end

-- Saf: filtreler → URL query (varsayılanlar yazılmaz)
function _M.query_from_filters(f)
  local q = {}
  for _, k in ipairs(FILTER_KEYS) do
    local v = f[k]
    if v ~= nil and v ~= "" then q[k] = tostring(v) end
  end
  if q.sort == DEFAULT_SORT then q.sort = nil end
  if q.page == "1" then q.page = nil end
  return q
end

local function same_filters(a, b)
  if not a or not b then return false end
  for _, k in ipairs(FILTER_KEYS) do
    if tostring(a[k] or "") ~= tostring(b[k] or "") then return false end
  end
  return true
end

local function list_hash()
  local st = app.get_state().todos
  return "#/todos" .. router.encode_query(_M.query_from_filters(st.filters or {}))
end

-- --- veri yükleme ---------------------------------------------------------------

local function load_todos(filters)
  app.dispatch({ type = "TODOS_REQUESTED", filters = filters })
  local q = {}
  for k, v in pairs(filters or {}) do
    if v ~= nil and v ~= "" then q[k] = v end
  end
  local data, err = api.get("/todos", q)
  if err then
    app.dispatch({ type = "TODOS_FAILED", error = err })
    app.toast("error", protocol.message(err.code))
    return
  end
  app.dispatch({ type = "TODOS_LOADED", items = data.items, meta = data.meta })
end

function _M.enter(route)
  local st = app.get_state().todos
  local filters = _M.filters_from_query(route.name == "todos" and route.query or nil)
  if route.name ~= "todos" then filters = st.status ~= "idle" and st.filters or filters end
  if st.status == "idle" or st.status == "error" or not same_filters(filters, st.filters) then
    load_todos(filters)
  end

  if route.name == "todos_new" then
    app.dispatch({ type = "TODO_EDIT_OPENED", id = "new" })
  elseif route.name == "todo_edit" then
    local id = route.params.id
    local cur = app.get_state().todos
    local idx = cur.by_id[id]
    local item = idx and cur.items[idx] or nil
    if not item then
      local data, err = api.get("/todos/" .. router.urlencode(id))
      if err then
        -- başkasına ait ya da olmayan todo aynı mesajı verir (00 §5 TODO_NOT_FOUND)
        app.toast("error", err.code == "TODO_NOT_FOUND" and "Todo bulunamadı" or protocol.message(err.code))
        router.navigate(list_hash(), { replace = true })
        return
      end
      item = data
    end
    app.dispatch({ type = "TODO_EDIT_OPENED", id = id, item = item })
  else
    app.dispatch({ type = "TODO_EDIT_CLOSED" })
  end
end

-- filtre değişimi: URL'ye yazılır (history kaydı) → hashchange → enter yeniden yükler
local function set_filters(patch)
  local f = app._assign(app.get_state().todos.filters or {}, patch)
  if patch.page == nil then f.page = 1 end
  router.navigate("#/todos" .. router.encode_query(_M.query_from_filters(f)))
end

local function open_new()
  if app.can("todos.create") then router.navigate("#/todos/new") end
end

local function open_edit(id)
  if id and app.can("todos.edit") then router.navigate("#/todos/" .. router.urlencode(id)) end
end

local function close_editor()
  router.navigate(list_hash())
end

-- --- optimistic işlemler -----------------------------------------------------------

local function create_todo(input)
  temp_seq = temp_seq + 1
  local temp_id = "tmp-" .. temp_seq
  local optimistic = app._assign(input, { id = temp_id, status = input.status or "pending",
    priority = input.priority or "medium" })
  app.dispatch({ type = "TODO_OPTIMISTIC_CREATE", todo = optimistic })
  close_editor()

  local data, err = api.post("/todos", input)
  if err then
    app.dispatch({ type = "TODO_ROLLBACK", id = temp_id })
    app.toast("error", err.code == "VALIDATION_FAILED" and "Todo kaydedilemedi: girdi geçersiz"
      or protocol.message(err.code))
    return
  end
  app.dispatch({ type = "TODO_CREATE_CONFIRMED", temp_id = temp_id, todo = data })
  app.toast("success", "Todo eklendi")
end

local function patch_todo(id, patch)
  app.dispatch({ type = "TODO_OPTIMISTIC_UPDATE", id = id, patch = patch })
  local data, err = api.patch("/todos/" .. id, patch)
  if err then
    app.dispatch({ type = "TODO_ROLLBACK", id = id })
    app.toast("error", err.code == "TODO_NOT_FOUND" and "Bu todo artık mevcut değil" or protocol.message(err.code))
    return
  end
  app.dispatch({ type = "TODO_UPDATE_CONFIRMED", todo = data })
  if data.status == "completed" then
    -- F16: onaydan sonra (rollback olursa kutlama yanıltıcı olurdu); hepsi bittiyse büyük patlama
    local all_done = true
    for _, t in ipairs(app.get_state().todos.items) do
      if t.status ~= "completed" then all_done = false break end
    end
    js.confetti(all_done and '{"particleCount":200,"spread":120}' or nil)
  end
end

local function delete_todo(id)
  app.dispatch({ type = "TODO_OPTIMISTIC_DELETE", id = id })
  local _, err = api.delete("/todos/" .. id)
  if err then
    app.dispatch({ type = "TODO_ROLLBACK", id = id })
    app.toast("error", protocol.message(err.code))
    return
  end
  app.dispatch({ type = "TODO_DELETE_CONFIRMED", id = id })
  app.toast("success", "Todo silindi")
end

local function confirm_delete(t)
  app.spawn(function()
    if require("components.modal").confirm({ title = "Silinsin mi?",
      message = "'" .. (t.title or "") .. "' kalıcı olarak silinecek.",
      confirm_label = "Sil", danger = true }) then
      delete_todo(t.id)
    end
  end)
end

-- --- kısayollar (F16) ----------------------------------------------------------------

local function selected_todo()
  local id = js.dom.activeDataId()
  local st = app.get_state().todos
  local idx = id and st.by_id[id]
  return idx and st.items[idx] or nil
end

shortcuts.register("todos", "n", function() open_new(); return true end, "Yeni todo")
shortcuts.register("todos", "e", function()
  local t = selected_todo()
  if t then open_edit(t.id); return true end
end, "Seçili todo'yu düzenle")
shortcuts.register("todos", "d", function()
  local t = selected_todo()
  if t and app.can("todos.edit") then confirm_delete(t); return true end
end, "Seçili todo'yu sil")
shortcuts.register("todos", "/", function() dom.focus("todo-search"); return true end, "Ara")

-- --- form (modal içerik) -------------------------------------------------------------

local function field_class(invalid)
  return "w-full px-3 py-2 border rounded-[var(--radius)] bg-[var(--bg)] "
    .. (invalid and "border-[var(--danger)]" or "border-[var(--border)]")
end

-- İlk hatalı alana odak (a11y)
local FIELD_IDS = { title = "todo-title", description = "todo-desc", status = "todo-status",
  priority = "todo-priority", due_date = "todo-due", tags = "todo-tags" }
local function focus_first_error(errs)
  for _, k in ipairs({ "title", "description", "status", "priority", "due_date", "tags" }) do
    if errs[k] then return dom.focus(FIELD_IDS[k]) end
  end
end

local function todo_form(state)
  local errors = (state.ui.form_errors or {}).todo or {}
  local st = state.todos
  local todo = nil
  if st.editing and st.editing ~= "new" then
    local idx = st.by_id[st.editing]
    todo = idx and st.items[idx] or st.editing_item
  end
  local is_edit = todo ~= nil

  local status_opts, prio_opts = {}, {}
  for _, s in ipairs(types.TODO_STATUS) do
    status_opts[#status_opts + 1] = dom.option({ value = s,
      selected = ((todo and todo.status or "pending") == s) and "selected" or nil }, STATUS_LABEL[s])
  end
  for _, p in ipairs(types.TODO_PRIORITY) do
    prio_opts[#prio_opts + 1] = dom.option({ value = p,
      selected = ((todo and todo.priority or "medium") == p) and "selected" or nil }, PRIORITY_LABEL[p])
  end

  local function err_p(field, id)
    return errors[field] and dom.p({ id = id .. "-err", class = "field-error" }, errors[field][1])
  end

  return dom.form({
    class = "space-y-3",
    ["aria-label"] = is_edit and "Todo düzenle" or "Yeni todo",
    novalidate = "novalidate", -- doğrulama shared şema ile (tarayıcı balonları yerine erişilebilir mesajlar)
    onsubmit = function()
      local input = {
        title = dom.value("todo-title") or "",
        description = dom.value("todo-desc") or "",
        status = dom.value("todo-status"),
        priority = dom.value("todo-priority"),
      }
      if input.description == "" then input.description = nil end
      local due = dom.value("todo-due")
      if due and due ~= "" then input.due_date = js.to_iso_utc(due) end -- datetime-local → UTC ISO
      local tags_raw = dom.value("todo-tags") or ""
      if tags_raw ~= "" then
        input.tags = {}
        for tag in tags_raw:gmatch("[^,]+") do
          tag = tag:match("^%s*(.-)%s*$")
          if tag ~= "" then input.tags[#input.tags + 1] = tag end
        end
      end
      app.spawn(function()
        local clean, errs = validation.validate(
          is_edit and validation.schemas.todo_update or validation.schemas.todo_create, input)
        if not clean then
          app.dispatch({ type = "FORM_ERRORS_SET", form = "todo", errors = errs })
          js.timer.after(0, function() focus_first_error(errs) end)
          return
        end
        if not is_edit then return create_todo(clean) end
        app.dispatch({ type = "TODO_OPTIMISTIC_UPDATE", id = todo.id, patch = clean })
        local data, err = api.put("/todos/" .. todo.id, clean)
        if err then
          app.dispatch({ type = "TODO_ROLLBACK", id = todo.id })
          app.dispatch({ type = "FORM_ERRORS_SET", form = "todo", errors = err.details or {} })
          app.toast("error", err.code == "TODO_NOT_FOUND" and "Bu todo artık mevcut değil" or protocol.message(err.code))
          return
        end
        app.dispatch({ type = "TODO_UPDATE_CONFIRMED", todo = data })
        app.toast("success", "Todo güncellendi")
        close_editor()
      end)
    end,
  },
    dom.div({},
      dom.label({ ["for"] = "todo-title", class = "block text-sm font-medium mb-1" }, "Başlık"),
      dom.input({
        id = "todo-title", type = "text", required = "required", maxlength = "255", autofocus = "autofocus",
        class = field_class(errors.title), value = todo and todo.title or nil,
        ["aria-invalid"] = errors.title and "true" or nil,
        ["aria-describedby"] = errors.title and "todo-title-err" or nil,
      }),
      err_p("title", "todo-title")),
    dom.div({},
      dom.label({ ["for"] = "todo-desc", class = "block text-sm font-medium mb-1" }, "Açıklama"),
      dom.textarea({
        id = "todo-desc", rows = "3", maxlength = "10000", class = field_class(errors.description),
        value = todo and todo.description or nil,
      })),
    dom.div({ class = "grid grid-cols-2 gap-3" },
      dom.div({},
        dom.label({ ["for"] = "todo-status", class = "block text-sm font-medium mb-1" }, "Durum"),
        dom.select({ id = "todo-status", class = field_class(errors.status) }, status_opts)),
      dom.div({},
        dom.label({ ["for"] = "todo-priority", class = "block text-sm font-medium mb-1" }, "Öncelik"),
        dom.select({ id = "todo-priority", class = field_class(errors.priority) }, prio_opts))),
    dom.div({},
      dom.label({ ["for"] = "todo-due", class = "block text-sm font-medium mb-1" }, "Son tarih"),
      dom.input({
        id = "todo-due", type = "datetime-local", class = field_class(errors.due_date),
        value = todo and todo.due_date and js.to_local_input(todo.due_date) or nil,
        ["aria-invalid"] = errors.due_date and "true" or nil,
        ["aria-describedby"] = errors.due_date and "todo-due-err" or nil,
      }),
      err_p("due_date", "todo-due")),
    dom.div({},
      dom.label({ ["for"] = "todo-tags", class = "block text-sm font-medium mb-1" }, "Etiketler (virgülle)"),
      dom.input({
        id = "todo-tags", type = "text", class = field_class(errors.tags),
        value = todo and type(todo.tags) == "table" and table.concat(todo.tags, ", ") or nil,
        ["aria-invalid"] = errors.tags and "true" or nil,
        ["aria-describedby"] = errors.tags and "todo-tags-err" or nil,
      }),
      err_p("tags", "todo-tags")),
    dom.div({ class = "flex justify-end gap-2 pt-2" },
      dom.button({ type = "button", class = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)]",
        onclick = close_editor }, "İptal"),
      dom.button({ type = "submit", class = "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]" },
        is_edit and "Kaydet" or "Ekle")))
end

-- --- liste render -----------------------------------------------------------------

local function todo_item(state, t)
  local pending = state.todos.pending[t.id] ~= nil or t._pending
  local overdue = type(t.due_date) == "string" and t.status ~= "completed"
    and t.due_date < os.date("!%Y-%m-%dT%H:%M:%SZ")
  local can_edit = app.can("todos.edit") and not pending
  local title = t.title or ""

  local tags = {}
  for _, tag in ipairs(type(t.tags) == "table" and t.tags or {}) do
    tags[#tags + 1] = dom.button({
      type = "button", class = "badge badge-pending mr-1",
      ["aria-label"] = "'" .. tag .. "' etiketine göre filtrele",
      onclick = function() set_filters({ tag = tag }) end,
    }, "#" .. tag)
  end

  return dom.li({
    key = t.id,
    class = "todo-item flex items-start gap-3 py-3 px-2 border-b border-[var(--border)] focus:bg-[var(--bg-elev)]"
      .. (pending and " opacity-50" or ""),
    ["data-id"] = t.id,
    tabindex = "0",
    ["aria-label"] = title,
  },
    dom.input({
      type = "checkbox", class = "mt-1 w-5 h-5",
      ["aria-label"] = "'" .. title .. "' tamamlandı olarak işaretle",
      checked = t.status == "completed" and "checked" or nil,
      disabled = (not can_edit) and "disabled" or nil,
      onchange = function()
        app.spawn(patch_todo, t.id, { status = t.status == "completed" and "pending" or "completed" })
      end,
    }),
    dom.div({ class = "flex-1 min-w-0" },
      dom.div({ class = t.status == "completed" and "line-through text-[var(--fg-muted)]" or "font-medium" }, title),
      type(t.description) == "string" and t.description ~= ""
        and dom.p({ class = "text-sm text-[var(--fg-muted)] truncate" }, t.description:sub(1, 120)),
      dom.div({ class = "flex items-center gap-2 mt-1 flex-wrap" },
        dom.span({ class = "badge badge-" .. (t.priority or "medium") }, PRIORITY_LABEL[t.priority or "medium"]),
        dom.span({ class = "badge badge-" .. (t.status or "pending") }, STATUS_LABEL[t.status or "pending"]),
        type(t.due_date) == "string" and dom.span({
          class = overdue and "text-xs text-[var(--danger)] font-medium" or "text-xs text-[var(--fg-muted)]" },
          (overdue and "Gecikti · " or "Son: ") .. (js.format_date(t.due_date, "date") or "")),
        tags)),
    can_edit and dom.div({ class = "flex gap-1" },
      dom.button({
        type = "button", class = "px-2 py-1 min-w-11 min-h-11 text-sm rounded-[var(--radius)] hover:bg-[var(--bg-elev)]",
        ["aria-label"] = "'" .. title .. "' düzenle", ["aria-keyshortcuts"] = "e",
        onclick = function() open_edit(t.id) end,
      }, "✎"),
      dom.button({
        type = "button", class = "px-2 py-1 min-w-11 min-h-11 text-sm rounded-[var(--radius)] text-[var(--danger)] hover:bg-[var(--bg-elev)]",
        ["aria-label"] = "'" .. title .. "' sil", ["aria-keyshortcuts"] = "d",
        onclick = function() confirm_delete(t) end,
      }, "🗑")))
end

local function select_filter(label, key, current, options)
  local opts = { dom.option({ value = "" }, "Tümü") }
  for _, o in ipairs(options) do
    opts[#opts + 1] = dom.option({ value = o[1], selected = current == o[1] and "selected" or nil }, o[2])
  end
  local id = "todo-filter-" .. key
  return dom.div({ class = "flex flex-col" },
    dom.label({ ["for"] = id, class = "text-xs text-[var(--fg-muted)]" }, label),
    dom.select({
      id = id,
      class = "px-3 py-2 min-h-11 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm text-[var(--fg)]",
      onchange = function(e) set_filters({ [key] = e.value or "" }) end,
    }, opts))
end

function _M.render(state)
  local st = state.todos
  local meta = st.meta or {}
  local f = st.filters or {}

  local filter_form = dom.form({
    role = "search", ["aria-label"] = "Todo filtreleri",
    class = "flex flex-wrap items-end gap-2 mb-4",
  },
    dom.div({ class = "flex flex-col flex-1 min-w-40" },
      dom.label({ ["for"] = "todo-search", class = "text-xs text-[var(--fg-muted)]" }, "Ara"),
      dom.input({
        type = "search", id = "todo-search", placeholder = "Başlık veya açıklama… (/)",
        ["aria-keyshortcuts"] = "/",
        class = "px-3 py-2 min-h-11 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm text-[var(--fg)]",
        value = f.q or "",
        oninput = function(e)
          -- 300 ms debounce
          if debounce_id then js.timer.cancel(debounce_id) end
          local v = e.value or ""
          debounce_id = js.timer.after(300, function() set_filters({ q = v }) end)
        end,
      })),
    select_filter("Durum", "status", f.status,
      { { "pending", "Bekliyor" }, { "in_progress", "Devam ediyor" }, { "completed", "Tamamlandı" } }),
    select_filter("Öncelik", "priority", f.priority, { { "high", "Yüksek" }, { "medium", "Orta" }, { "low", "Düşük" } }),
    dom.div({ class = "flex flex-col" },
      dom.label({ ["for"] = "todo-sort", class = "text-xs text-[var(--fg-muted)]" }, "Sıralama"),
      dom.select({
        id = "todo-sort",
        class = "px-3 py-2 min-h-11 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm text-[var(--fg)]",
        onchange = function(e) set_filters({ sort = e.value }) end,
      },
        dom.option({ value = "-created_at", selected = f.sort == "-created_at" and "selected" or nil }, "En yeni"),
        dom.option({ value = "created_at", selected = f.sort == "created_at" and "selected" or nil }, "En eski"),
        dom.option({ value = "due_date", selected = f.sort == "due_date" and "selected" or nil }, "Son tarih"),
        dom.option({ value = "priority", selected = f.sort == "priority" and "selected" or nil }, "Öncelik"))),
    f.tag and f.tag ~= "" and dom.button({
      type = "button", class = "badge badge-in_progress min-h-11",
      ["aria-label"] = "Etiket filtresini kaldır: " .. f.tag,
      onclick = function() set_filters({ tag = "" }) end,
    }, "#" .. f.tag .. " ✕"))

  local list_content
  if st.status == "loading" and #st.items == 0 then
    list_content = require("components.skeleton").todo_items(5)
  elseif #st.items == 0 then
    local layout = require("views.layout")
    if (f.q or "") ~= "" or f.status or f.priority or f.tag then
      list_content = layout.empty_state({
        icon = "🔍", title = "Sonuç yok", text = "Bu filtrelerle eşleşen todo yok",
        action_label = "Filtreleri temizle",
        on_action = function() router.navigate("#/todos") end,
      })
    else
      list_content = layout.empty_state({
        icon = "✅", title = "Henüz todo yok", text = "İlk todo'nuzu ekleyin",
        action_label = app.can("todos.create") and "+ İlk todo'yu ekle" or nil,
        on_action = open_new,
      })
    end
  else
    local items = {}
    for i, t in ipairs(st.items) do items[i] = todo_item(state, t) end
    list_content = dom.ul({ role = "list", ["aria-busy"] = tostring(st.status == "loading"),
      class = "todo-list", ["aria-label"] = "Todo listesi" }, items)
  end

  local modal = nil
  if st.editing then
    local is_new = st.editing == "new"
    modal = require("components.modal").dialog("todo-edit", is_new and "Yeni todo" or "Todo düzenle",
      todo_form(state), close_editor)
  end

  return dom.section({ ["aria-labelledby"] = "todos-title" },
    dom.header({ class = "flex items-center justify-between gap-2 mb-4" },
      dom.h1({ id = "todos-title", class = "text-2xl font-bold", tabindex = "-1" },
        "Todo'lar" .. ((tonumber(meta.total) or 0) > 0 and (" (" .. meta.total .. ")") or "")),
      app.can("todos.create") and dom.button({
        type = "button",
        class = "px-4 py-2 min-h-11 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]",
        ["aria-keyshortcuts"] = "n",
        onclick = open_new,
      }, "+ Yeni todo")),
    filter_form,
    list_content,
    require("views.layout").pagination(meta, function(p) set_filters({ page = p }) end),
    modal)
end

return _M
