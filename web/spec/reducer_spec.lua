-- F17: reducer birim testleri — saf fonksiyonlar; js mock'u helper.lua'da.
require("helper")
local app = require("app")

local function run(action)
  return app.root_reducer(app.initial_state, action)
end

describe("root_reducer", function()
  it("bilinmeyen action state referansını korur", function()
    local next_state = run({ type = "UNKNOWN_ACTION" })
    assert.equal(app.initial_state, next_state)
  end)
end)

describe("auth reducer", function()
  it("LOGIN_SUCCEEDED authenticated yapar", function()
    local s = run({ type = "LOGIN_SUCCEEDED",
      user = { id = "u1", email = "a@b.c", role = "admin" },
      permissions = { ["users.list"] = true } })
    assert.equal("authenticated", s.auth.status)
    assert.equal("a@b.c", s.auth.user.email)
    assert.is_true(s.auth.permissions["users.list"])
  end)

  it("LOGGED_OUT kullanıcı dilimlerini sıfırlar", function()
    local s = run({ type = "LOGIN_SUCCEEDED", user = { id = "u1" }, permissions = {} })
    s = app.root_reducer(s, { type = "TODO_OPTIMISTIC_CREATE", todo = { id = "t1", title = "x" } })
    s = app.root_reducer(s, { type = "LOGGED_OUT" })
    assert.equal("anonymous", s.auth.status)
    assert.equal(0, #s.todos.items)
    assert.is_nil(s.todos.pending["t1"])
  end)

  it("PERMISSIONS_LOADED izinleri günceller", function()
    local s = run({ type = "LOGIN_SUCCEEDED", user = { id = "u1" }, permissions = {} })
    s = app.root_reducer(s, { type = "PERMISSIONS_LOADED", permissions = { ["audit.logs"] = true } })
    assert.is_true(s.auth.permissions["audit.logs"])
    assert.equal("authenticated", s.auth.status) -- kullanıcı bilgisi korunur
  end)
end)

describe("todos optimistic reducer", function()
  it("OPTIMISTIC_CREATE başa ekler ve pending koyar", function()
    local s = run({ type = "TODO_OPTIMISTIC_CREATE", todo = { id = "tmp-1", title = "Yeni" } })
    assert.equal(1, #s.todos.items)
    assert.equal("tmp-1", s.todos.items[1].id)
    assert.is_true(s.todos.items[1]._pending)
    assert.equals("create", s.todos.pending["tmp-1"].op)
  end)

  it("CREATE_CONFIRMED temp id'yi gerçek id ile değiştirir", function()
    local s = run({ type = "TODO_OPTIMISTIC_CREATE", todo = { id = "tmp-1", title = "Yeni" } })
    s = app.root_reducer(s, { type = "TODO_CREATE_CONFIRMED", temp_id = "tmp-1",
      todo = { id = "real-1", title = "Yeni" } })
    assert.equal(1, #s.todos.items)
    assert.equal("real-1", s.todos.items[1].id)
    assert.equal(1, s.todos.by_id["real-1"])
    assert.is_nil(s.todos.by_id["tmp-1"])
    assert.is_nil(s.todos.pending["tmp-1"])
  end)

  it("create rollback satırı kaldırır", function()
    local s = run({ type = "TODO_OPTIMISTIC_CREATE", todo = { id = "tmp-1", title = "Yeni" } })
    s = app.root_reducer(s, { type = "TODO_ROLLBACK", id = "tmp-1" })
    assert.equal(0, #s.todos.items)
    assert.is_nil(s.todos.pending["tmp-1"])
  end)

  it("update rollback snapshot'ı birebir geri getirir", function()
    local s = run({ type = "TODOS_LOADED", items = { { id = "t1", title = "Eski", status = "pending" } },
      meta = { total = 1 } })
    local before = s.todos.items[1]
    s = app.root_reducer(s, { type = "TODO_OPTIMISTIC_UPDATE", id = "t1", patch = { status = "completed" } })
    assert.equal("completed", s.todos.items[1].status)
    s = app.root_reducer(s, { type = "TODO_ROLLBACK", id = "t1" })
    assert.equal("Eski", s.todos.items[1].title)
    assert.equal("pending", s.todos.items[1].status)
    assert.is_nil(s.todos.items[1]._pending)
    assert.same(before, s.todos.items[1])
  end)

  it("delete rollback satırı ESKİ İNDEKSİNE geri koyar", function()
    local s = run({ type = "TODOS_LOADED",
      items = { { id = "t1", title = "A" }, { id = "t2", title = "B" }, { id = "t3", title = "C" } },
      meta = { total = 3 } })
    s = app.root_reducer(s, { type = "TODO_OPTIMISTIC_DELETE", id = "t1" })
    assert.equal(2, #s.todos.items)
    assert.equal("B", s.todos.items[1].title)
    s = app.root_reducer(s, { type = "TODO_ROLLBACK", id = "t1" })
    assert.equal(3, #s.todos.items)
    assert.equal("A", s.todos.items[1].title) -- indeks 1'e döndü
    assert.equal("B", s.todos.items[2].title)
    assert.equal("C", s.todos.items[3].title)
  end)

  it("bilinmeyen id ile rollback hata fırlatmaz ve state'i korur", function()
    local s = run({ type = "TODOS_LOADED", items = { { id = "t1", title = "A" } }, meta = {} })
    local before = s.todos
    s = app.root_reducer(s, { type = "TODO_ROLLBACK", id = "yok" })
    assert.equal(before, s.todos)
  end)
end)

describe("rbac reducer", function()
  local matrix = { admin = { ["rbac.matrix"] = true }, todouser = { ["users.list"] = false } }

  it("CELL_TOGGLED optimistic uygular + snapshot saklar", function()
    local s = run({ type = "RBAC_LOADED", matrix = matrix, cache_ttl = 60 })
    s = app.root_reducer(s, { type = "RBAC_CELL_TOGGLED", role = "todouser", page_key = "users.list", can_access = true })
    assert.is_true(s.rbac.matrix.todouser["users.list"])
    assert.equals(false, s.rbac.pending["todouser:users.list"].old)
  end)

  it("CELL_ROLLBACK eski değere döner", function()
    local s = run({ type = "RBAC_LOADED", matrix = matrix, cache_ttl = 60 })
    s = app.root_reducer(s, { type = "RBAC_CELL_TOGGLED", role = "todouser", page_key = "users.list", can_access = true })
    s = app.root_reducer(s, { type = "RBAC_CELL_ROLLBACK", role = "todouser", page_key = "users.list" })
    assert.is_false(s.rbac.matrix.todouser["users.list"])
    assert.is_nil(s.rbac.pending["todouser:users.list"])
  end)
end)

describe("route/ui reducer", function()
  it("TODO_EDIT_CLOSED editing alanını gerçekten siler", function()
    local s = run({ type = "TODO_EDIT_OPENED", id = "new" })
    assert.equal("new", s.todos.editing)
    s = app.root_reducer(s, { type = "TODO_EDIT_CLOSED" })
    assert.is_nil(s.todos.editing)
  end)

  it("ROUTE_CHANGED forbidden bayrağını taşır; FORBIDDEN işaretler", function()
    local s = run({ type = "ROUTE_CHANGED", name = "users", forbidden = true })
    assert.is_true(s.route.forbidden)
    s = app.root_reducer(s, { type = "ROUTE_CHANGED", name = "todos" })
    assert.is_false(s.route.forbidden)
    s = app.root_reducer(s, { type = "FORBIDDEN" })
    assert.is_true(s.route.forbidden)
  end)

  it("SIDEBAR_SET aynı değerde referansı korur", function()
    local s = run({ type = "SIDEBAR_SET", sidebar_open = false })
    assert.equal(app.initial_state, s)
    s = app.root_reducer(s, { type = "SIDEBAR_SET", sidebar_open = true })
    assert.is_true(s.ui.sidebar_open)
  end)

  it("LOGIN_REQUESTED ui.busy.login'i açar; FORGOT_SENT/RESET_DONE bayrak koyar", function()
    local s = run({ type = "LOGIN_REQUESTED" })
    assert.is_true(s.ui.busy.login)
    assert.is_true(app.root_reducer(s, { type = "FORGOT_SENT" }).ui.forgot_sent)
    assert.is_true(app.root_reducer(s, { type = "RESET_DONE" }).ui.reset_done)
  end)

  it("ROUTE_CHANGED form hatalarını ve tek seferlik bayrakları temizler", function()
    local s = run({ type = "FORM_ERRORS_SET", form = "login", errors = { email = { "x" } } })
    s = app.root_reducer(s, { type = "FORGOT_SENT" })
    s = app.root_reducer(s, { type = "ROUTE_CHANGED", name = "login" })
    assert.is_falsy(s.ui.form_errors)
    assert.is_falsy(s.ui.forgot_sent)
  end)

  it("AUDIT_DESELECTED seçimi ve detayı siler", function()
    local s = run({ type = "AUDIT_SELECTED", id = 5 })
    s = app.root_reducer(s, { type = "AUDIT_DETAIL_LOADED", log = { id = 5 } })
    s = app.root_reducer(s, { type = "AUDIT_DESELECTED" })
    assert.is_nil(s.audit.selected)
    assert.is_nil(s.audit.detail)
  end)

  it("USER_LOADED kullanıcı ve izinleri günceller", function()
    local s = run({ type = "LOGIN_SUCCEEDED", user = { id = "u1", email = "a" }, permissions = {} })
    s = app.root_reducer(s, { type = "USER_LOADED", user = { id = "u1", email = "b" }, permissions = { dashboard = true } })
    assert.equal("b", s.auth.user.email)
    assert.is_true(s.auth.permissions.dashboard)
  end)
end)

describe("ui reducer (toast)", function()
  it("en fazla 5 toast; fazlası en eskisini düşürür", function()
    local s = app.initial_state
    for i = 1, 6 do
      s = app.root_reducer(s, { type = "TOAST_PUSHED", toast = { id = "t" .. i, kind = "info", message = "m" .. i } })
    end
    assert.equal(5, #s.ui.toasts)
    assert.equal("t2", s.ui.toasts[1].id) -- t1 düştü
    assert.equal("t6", s.ui.toasts[5].id)
  end)

  it("aynı mesaj tekrar gelirse sayacı artar", function()
    local s = run({ type = "TOAST_PUSHED", toast = { id = "t1", kind = "info", message = "aynı" } })
    s = app.root_reducer(s, { type = "TOAST_PUSHED", toast = { id = "t2", kind = "info", message = "aynı" } })
    assert.equal(1, #s.ui.toasts)
    assert.equal(2, s.ui.toasts[1].count)
  end)

  it("TOAST_DISMISSED ilgili toast'ı kaldırır", function()
    local s = run({ type = "TOAST_PUSHED", toast = { id = "t1", kind = "info", message = "m" } })
    s = app.root_reducer(s, { type = "TOAST_DISMISSED", id = "t1" })
    assert.equal(0, #s.ui.toasts)
  end)
end)
