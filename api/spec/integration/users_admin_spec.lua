-- Users + RBAC entegrasyon testleri (F11 §6.4): admin CRUD, self/son admin koruması, RBAC matrisi
local h = require("helpers.init")

describe("users admin (integration)", function()
  local admin, user

  setup(function()
    h.reset_db()
    admin = h.login_admin()
    user = h.login_user()
  end)

  -- Test sonunda matris her durumda varsayılana döner (API üzerinden → cache de invalidate)
  local function set_cell(role, page, value)
    return h.request("PATCH", "/rbac/matrix/" .. role .. "/" .. page, { can_access = value }, admin.access_token)
  end

  it("todouser GET /users → 403 FORBIDDEN + access.denied audit", function()
    local res = h.request("GET", "/users", nil, user.access_token)
    assert.equal(403, res.status)
    assert.equal("FORBIDDEN", h.code(res))
    local rows = h.audit(admin.access_token, "action=access.denied")
    assert.truthy(#rows >= 1)
    assert.equal("users.list", rows[1].entity_id)
  end)

  it("admin POST /users → 201, password_hash yanıtta yok, DB'de argon2id", function()
    local email = h.unique_email("yeni")
    local res = h.request("POST", "/users", { email = email, password = "Test1234!", role = "todouser" },
      admin.access_token)
    assert.equal(201, res.status)
    assert.is_nil(res.raw:find("password_hash"))
    local row = h.sql("SELECT password_hash FROM users WHERE email = $1", email)[1]
    assert.equal("$argon2id$", row.password_hash:sub(1, 10))
  end)

  it("aynı email (büyük/küçük harf farklı) → 409 EMAIL_TAKEN", function()
    local u = h.create_user(admin.access_token)
    local res = h.request("POST", "/users", { email = u.email:upper(), password = "Test1234!", role = "todouser" },
      admin.access_token)
    assert.equal(409, res.status)
    assert.equal("EMAIL_TAKEN", h.code(res))
  end)

  it("geçersiz gövde → 422, olmayan kullanıcı → 404 USER_NOT_FOUND", function()
    assert.equal(422, h.request("POST", "/users", { email = "x" }, admin.access_token).status)
    local res = h.request("GET", "/users/00000000-0000-4000-8000-000000000000", nil, admin.access_token)
    assert.equal(404, res.status)
    assert.equal("USER_NOT_FOUND", h.code(res))
  end)

  it("PUT rol değişimi; is_active=false → login olamaz", function()
    local u = h.create_user(admin.access_token)
    local r = h.request("PUT", "/users/" .. u.id, { role = "admin" }, admin.access_token)
    assert.equal(200, r.status)
    assert.equal("admin", r.body.data.role)
    assert.equal(200, h.request("PUT", "/users/" .. u.id, { is_active = false }, admin.access_token).status)
    assert.equal(403, h.request("POST", "/auth/login", { email = u.email, password = u.password }).status)
  end)

  it("admin kendini silemez / rolünü düşüremez → 409 SELF_ACTION_FORBIDDEN", function()
    local d = h.request("DELETE", "/users/" .. admin.user.id, nil, admin.access_token)
    assert.equal(409, d.status)
    assert.equal("SELF_ACTION_FORBIDDEN", h.code(d))
    local p = h.request("PUT", "/users/" .. admin.user.id, { role = "todouser" }, admin.access_token)
    assert.equal(409, p.status)
    assert.equal("SELF_ACTION_FORBIDDEN", h.code(p))
  end)

  it("son aktif admin silinemez/düşürülemez → 409 LAST_ADMIN", function()
    -- diğer adminleri pasifleştir; todouser'a users.* yetkisi ver, son admin'i o hedeflesin
    h.sql("UPDATE users SET is_active = false WHERE role = 'admin' AND email <> $1", h.ADMIN.email)
    assert.equal(200, set_cell("todouser", "users.list", true).status)
    assert.equal(200, set_cell("todouser", "users.create", true).status)
    local ok, err = pcall(function()
      local u = h.create_user(admin.access_token)
      local s = assert(h.login(u.email, u.password))
      local d = h.request("DELETE", "/users/" .. admin.user.id, nil, s.access_token)
      assert.equal(409, d.status)
      assert.equal("LAST_ADMIN", h.code(d))
      local p = h.request("PUT", "/users/" .. admin.user.id, { role = "todouser" }, s.access_token)
      assert.equal("LAST_ADMIN", h.code(p))
    end)
    set_cell("todouser", "users.list", false)
    set_cell("todouser", "users.create", false)
    assert(ok, err)
  end)

  it("kullanıcı silinince todo'ları CASCADE silinir; audit user_email korunur", function()
    local u = h.create_user(admin.access_token)
    local s = assert(h.login(u.email, u.password))
    assert.equal(201, h.request("POST", "/todos", { title = "Silinecek" }, s.access_token).status)
    assert.equal(204, h.request("DELETE", "/users/" .. u.id, nil, admin.access_token).status)
    assert.equal(0, h.sql("SELECT count(*)::int AS n FROM todos WHERE user_id = $1::uuid", u.id)[1].n)
    local rows = h.sql("SELECT user_id, user_email FROM audit_logs WHERE user_email = $1", u.email)
    assert.truthy(#rows > 0)
    for _, r in ipairs(rows) do assert.is_nil(r.user_id) end
    assert.equal(404, h.request("DELETE", "/users/" .. u.id, nil, admin.access_token).status)
  end)

  it("GET /users filtreleri (q, role, is_active, sayfa)", function()
    local b = h.request("GET", "/users?q=user&role=todouser&is_active=true&page=1", nil, admin.access_token)
    assert.equal(200, b.status)
    assert.is_number(b.body.meta.total)
    for _, u in ipairs(b.body.data) do assert.equal("todouser", u.role) end
  end)

  it("RBAC: todouser'a users.list açılınca beklemeden 200", function()
    assert.equal(403, h.request("GET", "/users", nil, user.access_token).status)
    assert.equal(200, set_cell("todouser", "users.list", true).status)
    local res = h.request("GET", "/users", nil, user.access_token)
    set_cell("todouser", "users.list", false)
    assert.equal(200, res.status)
  end)

  it("admin rbac.matrix kapatılamaz → 409 CONFLICT; bilinmeyen sayfa 404", function()
    local res = set_cell("admin", "rbac.matrix", false)
    assert.equal(409, res.status)
    assert.equal("CONFLICT", h.code(res))
    assert.equal(404, set_cell("admin", "yok.sayfa", true).status)
  end)

  it("PUT /rbac/matrix permissions dizisi ile toplu güncelleme", function()
    local res = h.request("PUT", "/rbac/matrix", { permissions = {
      { role = "todouser", page_key = "settings", can_access = true } } }, admin.access_token)
    assert.equal(200, res.status)
    assert.is_true(res.body.data.matrix.todouser.settings)
    set_cell("todouser", "settings", false)
  end)

  it("GET /rbac/pages 9 sayfa; GET /rbac/matrix 2×9", function()
    local pages = h.request("GET", "/rbac/pages", nil, admin.access_token)
    assert.equal(200, pages.status)
    assert.equal(9, #pages.body.data)
    local m = h.request("GET", "/rbac/matrix", nil, admin.access_token).body.data.matrix
    for _, role in ipairs({ "admin", "todouser" }) do
      local n = 0
      for _ in pairs(m[role]) do n = n + 1 end
      assert.equal(9, n)
    end
  end)
end)
