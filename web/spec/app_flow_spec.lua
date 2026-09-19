-- F17: Uygulama akışı — app.start + router + guard + view enter/render, sahte köprü üzerinden uçtan uca.
-- Her sayfanın render'ı hatasız olmalı (fake.errors boş).
local fake = require("helper")
local json = require("json")

local MODULES = { "^app$", "^router$", "^fetch$", "^dom$", "^storage$", "^shortcuts$", "^views%.", "^components%." }

-- Modül durumu (store, router kaydı) her testte sıfırdan
local function fresh()
  for name in pairs(package.loaded) do
    for _, pat in ipairs(MODULES) do
      if name:find(pat) then package.loaded[name] = nil end
    end
  end
  fake.reset()
  return require("app"), require("router")
end

local ALL = {}
for _, k in ipairs(require("todo_shared.types").PAGES) do ALL[k] = true end
local USER_PERMS = { dashboard = true, ["todos.list"] = true, ["todos.create"] = true, ["todos.edit"] = true }

local function me(role, perms)
  return json.encode({ data = { user = { id = "u1", email = role .. "@t.local", role = role }, permissions = perms } })
end
local function list(items, total)
  return json.encode({ data = items, meta = { page = 1, per_page = 20, total = total or #items, total_pages = 1 } })
end
local function logged_in(role, perms)
  fake.storage.set("todo.auth", json.encode({ access_token = "a", refresh_token = "r" }))
  fake.queue_response(200, me(role, perms))
end
local function urls()
  local out = {}
  for _, c in ipairs(fake.calls) do
    out[#out + 1] = (c.method or "") .. " " .. (c.url or ""):gsub("^https?://[^/]+", ""):gsub("^/api/v1", "")
  end
  return out
end
local function has_call(prefix)
  for _, u in ipairs(urls()) do if u:sub(1, #prefix) == prefix then return true end end
  return false
end

describe("app akışı", function()
  it("oturumsuz korumalı sayfa → login?next (replace), login ekranı render edilir", function()
    local app = fresh()
    fake._hash = "#/todos"
    app.start({})
    local st = app.get_state()
    assert.equal("anonymous", st.auth.status)
    assert.equal("login", st.route.name)
    assert.equal("#/login?next=%23%2Ftodos", fake._hash)
    assert.equal("Giriş · Todo", fake.title)
    assert.same({}, fake.errors)
  end)

  it("geçerli token → /auth/me → dashboard enter istatistikleri yükler", function()
    local app = fresh()
    logged_in("todouser", USER_PERMS)
    fake.queue_response(200, json.encode({ data = { total = 3, by_status = { pending = 1, completed = 2 },
      by_priority = { high = 1 }, overdue = 0 } }))
    fake.queue_response(200, list({ { id = "t1", title = "a", status = "pending" } }))
    fake._hash = "#/"
    app.start({})
    local st = app.get_state()
    assert.equal("authenticated", st.auth.status)
    assert.equal("ready", st.stats.status)
    assert.equal(1, #st.stats.recent)
    assert.is_false(has_call("GET /audit/stats")) -- izin yok → admin kartı isteği yok
    assert.same({}, fake.errors)
  end)

  it("girişliyken #/login → #/ yönlendirilir", function()
    local app = fresh()
    logged_in("todouser", USER_PERMS)
    fake._hash = "#/login"
    app.start({})
    assert.equal("dashboard", app.get_state().route.name)
    assert.equal("#/", fake._hash)
  end)

  it("izin yoksa 403 içeriği; view enter (API) ve admin bundle çalışmaz", function()
    local app = fresh()
    logged_in("todouser", USER_PERMS)
    fake._hash = "#/rbac"
    app.start({})
    local st = app.get_state()
    assert.equal("rbac", st.route.name)
    assert.is_true(st.route.forbidden)
    assert.is_false(has_call("GET /rbac"))
    assert.same({}, fake.loaded_bundles)
    assert.equal("Erişim yok · Todo", fake.title)
    assert.same({}, fake.errors)
  end)

  it("admin: admin bundle yüklenir, users sayfası listeyi getirir ve render edilir", function()
    local app = fresh()
    logged_in("admin", ALL)
    fake.queue_response(200, list({ { id = "u2", email = "x@t.local", role = "todouser", is_active = true } }))
    fake._hash = "#/users"
    app.start({})
    assert.same({ "admin" }, fake.loaded_bundles)
    assert.equal(1, #app.get_state().users.items)
    assert.is_true(has_call("GET /users"))
    assert.same({}, fake.errors)
  end)

  it("todos: liste yüklenir; #/todos/new düzenleyiciyi açar; filtre değişimi URL'ye yazılır", function()
    local app, router = fresh()
    logged_in("todouser", USER_PERMS)
    fake.queue_response(200, list({ { id = "t1", title = "a", status = "pending", priority = "low", tags = { "x" } } }))
    fake._hash = "#/todos"
    app.start({})
    assert.equal(1, #app.get_state().todos.items)
    router.navigate("#/todos/new")
    assert.equal("new", app.get_state().todos.editing)
    router.navigate("#/todos")
    assert.is_nil(app.get_state().todos.editing)
    fake.queue_response(200, list({}))
    router.replace_query({ status = "completed" })
    assert.equal("#/todos?status=completed", fake._hash)
    assert.equal("completed", app.get_state().todos.filters.status)
    assert.same({}, fake.errors)
  end)

  it("olmayan todo id'si → toast + listeye dönüş", function()
    local app = fresh()
    logged_in("todouser", USER_PERMS)
    fake.queue_response(200, list({}))
    fake.queue_response(404, json.encode({ error = { code = "TODO_NOT_FOUND" } }))
    fake._hash = "#/todos/yok"
    app.start({})
    assert.equal("todos", app.get_state().route.name)
    assert.equal("#/todos", fake._hash)
  end)

  it("profil /auth/me ile tazelenir; rbac ve audit sayfaları render edilir", function()
    local app, router = fresh()
    logged_in("admin", ALL)
    fake.queue_response(200, me("admin", ALL)) -- profil enter: /auth/me tazeleme
    fake._hash = "#/profile"
    app.start({})
    assert.equal(2, #fake.calls)
    fake.queue_response(200, json.encode({ data = { { key = "dashboard", label = "Pano" } } })) -- /rbac/pages
    fake.queue_response(200, json.encode({ data = { pages = {}, matrix = { admin = ALL, todouser = USER_PERMS } },
      meta = { cache_ttl = 60 } }))
    router.navigate("#/rbac")
    assert.equal(60, app.get_state().rbac.cache_ttl)
    router.navigate("#/audit-logs") -- tarih yoksa varsayılan 7 gün replace edilir
    assert.matches("from=", fake._hash)
    assert.same({}, fake.errors)
  end)

  it("logout: sunucuya bildirilir, durum sıfırlanır, login'e gidilir", function()
    local app = fresh()
    logged_in("todouser", USER_PERMS)
    fake._hash = "#/profile"
    app.start({})
    fake.queue_response(204, "")
    app.logout()
    assert.is_true(has_call("POST /auth/logout"))
    assert.equal("anonymous", app.get_state().auth.status)
    assert.is_nil(fake.storage.get("todo.auth"))
    assert.equal("login", app.get_state().route.name)
  end)

  it("403 yanıtı izinleri /auth/me ile tazeler", function()
    local app = fresh()
    logged_in("admin", ALL)
    fake._hash = "#/profile"
    app.start({})
    local before = #fake.calls
    fake.queue_response(403, json.encode({ error = { code = "FORBIDDEN" } }))
    fake.queue_response(200, me("admin", USER_PERMS))
    app.spawn(function() require("fetch").get("/users") end)
    assert.is_true(#fake.calls >= before + 2)
    assert.is_nil(app.get_state().auth.permissions["users.list"])
  end)

  it("bilinmeyen route → 404 içeriği", function()
    local app = fresh()
    logged_in("todouser", USER_PERMS)
    fake._hash = "#/yok-boyle-sayfa"
    app.start({})
    assert.equal("not_found", app.get_state().route.name)
    assert.equal("Sayfa bulunamadı · Todo", fake.title)
  end)

  it("geçersiz token ile açılış → anonim + login", function()
    local app = fresh()
    fake.storage.set("todo.auth", json.encode({ access_token = "a" }))
    fake.queue_response(401, json.encode({ error = { code = "UNAUTHORIZED" } }))
    fake._hash = "#/todos"
    app.start({})
    assert.equal("anonymous", app.get_state().auth.status)
    assert.is_nil(fake.storage.get("todo.auth"))
    assert.equal("login", app.get_state().route.name)
  end)

  it("oturum ortasında refresh başarısız → LOGGED_OUT + login?next", function()
    local app, router = fresh()
    logged_in("todouser", USER_PERMS)
    fake._hash = "#/profile"
    fake.queue_response(200, me("todouser", USER_PERMS)) -- profil enter
    app.start({})
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_EXPIRED" } }))
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_REVOKED" } })) -- refresh reddi
    app.spawn(function() require("fetch").get("/todos/stats") end)
    assert.equal("anonymous", app.get_state().auth.status)
    assert.matches("^#/login%?next=", fake._hash)
    assert.is_nil(router.current().route.page_key)
  end)

  it("admin bundle yüklenemezse hata toast'u; sayfa iskelette kalır", function()
    local app = fresh()
    logged_in("admin", ALL)
    fake.loadBundle = function(_, cb) cb("ağ hatası") end
    fake._hash = "#/users"
    app.start({})
    fake.loadBundle = function(name, cb) fake.loaded_bundles[#fake.loaded_bundles + 1] = name; cb(nil) end
    assert.matches("bundle yüklenemedi", fake.errors[#fake.errors])
    assert.same({}, app.get_state().users.items) -- enter çalışmadı
  end)

  it("effect hatası yakalanır, loglanır ve kullanıcıya genel mesaj gösterilir", function()
    local app = fresh()
    app.start({})
    app.spawn(function() error("patladı") end)
    assert.matches("effect hatası", fake.errors[#fake.errors])
  end)

  it("tema: 'system' OS tercihini uygular ve saklanır", function()
    local app = fresh()
    fake.prefers_dark = true
    app.start({})
    app.dispatch({ type = "THEME_SET", theme = "system" })
    assert.equal("dark", fake.root_attrs["data-theme"])
    assert.equal("system", fake.storage.get("todo.theme"))
    app.dispatch({ type = "THEME_SET", theme = "light" })
    assert.equal("light", fake.root_attrs["data-theme"])
  end)
end)
