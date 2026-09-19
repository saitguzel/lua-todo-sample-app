-- Audit entegrasyon testleri (F11 §6.5): olay yazımı, maskeleme, liste/detay/stats/CSV, 00 §8 kapsamı
local h = require("helpers.init")

describe("audit (integration)", function()
  local admin, user, todo_id, new_user

  setup(function()
    h.reset_db()
    admin = h.login_admin()
    user = h.login_user()
    -- olay üreten işlemler
    -- user_agent CSV'de kendi hücresi: formül enjeksiyonu kaçışını onunla doğrula
    local t = h.request("POST", "/todos", { title = "virgül, \"tırnak\"" }, admin.access_token,
      { ["User-Agent"] = "=HYPERLINK(\"http://x\")" })
    assert(t.status == 201, t.raw)
    todo_id = t.body.data.id
    assert(h.request("PATCH", "/todos/" .. todo_id, { status = "completed" }, admin.access_token).status == 200)
    assert(h.request("DELETE", "/todos/" .. todo_id, nil, admin.access_token).status == 204)
    new_user = h.create_user(admin.access_token)
    assert(h.request("PUT", "/users/" .. new_user.id, { full_name = "Değişti" }, admin.access_token).status == 200)
    assert(h.request("DELETE", "/users/" .. new_user.id, nil, admin.access_token).status == 204)
    h.request("PATCH", "/rbac/matrix/todouser/settings", { can_access = true }, admin.access_token)
    h.request("PATCH", "/rbac/matrix/todouser/settings", { can_access = false }, admin.access_token)
    h.request("GET", "/audit/logs", nil, user.access_token) -- access.denied
  end)

  it("todo create/update/delete → 3 kayıt, old/new değerleri doğru", function()
    local rows = h.audit(admin.access_token, "entity_type=todo")
    local by = {}
    for _, r in ipairs(rows) do by[r.action] = r end
    for _, a in ipairs({ "todo.create", "todo.update", "todo.delete" }) do assert.is_table(by[a], a) end
    local upd = h.request("GET", "/audit/logs/" .. by["todo.update"].id, nil, admin.access_token).body.data
    assert.equal("pending", upd.old_value.status)
    assert.equal("completed", upd.new_value.status)
    local del = h.request("GET", "/audit/logs/" .. by["todo.delete"].id, nil, admin.access_token).body.data
    assert.equal(todo_id, del.old_value.id)
  end)

  it("user.create kaydında password_hash maskeli", function()
    local rows = h.audit(admin.access_token, "action=user.create")
    local d = h.request("GET", "/audit/logs/" .. rows[1].id, nil, admin.access_token).body.data
    assert.equal("***", d.new_value.password_hash)
  end)

  it("ip_address ve user_agent dolu", function()
    local r = h.audit(admin.access_token, "action=todo.update")[1]
    assert.is_string(r.ip_address)
    assert.equal("busted-it", r.user_agent)
  end)

  it("filtreler: action, status, user_id, from/to; >90 gün → 422", function()
    h.request("POST", "/auth/login", { email = h.ADMIN.email, password = "Yanlis123!" })
    for _, r in ipairs(h.audit(admin.access_token, "action=auth.login.failure")) do
      assert.equal("auth.login.failure", r.action)
    end
    for _, r in ipairs(h.audit(admin.access_token, "status=failure")) do assert.equal("failure", r.status) end
    for _, r in ipairs(h.audit(admin.access_token, "user_id=" .. admin.user.id)) do
      assert.equal(admin.user.id, r.user_id)
    end
    assert.equal(0, #h.audit(admin.access_token, "from=2020-01-01T00:00:00Z&to=2020-01-02T00:00:00Z"))
    local res = h.request("GET", "/audit/logs?from=2020-01-01T00:00:00Z", nil, admin.access_token)
    assert.equal(422, res.status)
  end)

  it("detay: olmayan id → 404", function()
    assert.equal(404, h.request("GET", "/audit/logs/999999999", nil, admin.access_token).status)
  end)

  it("stats: toplam, by_status, by_action, by_day", function()
    local res = h.request("GET", "/audit/stats", nil, admin.access_token)
    assert.equal(200, res.status)
    local d = res.body.data
    assert.truthy(d.total > 0)
    assert.is_table(d.by_status)
    assert.is_table(d.by_action)
    assert.is_table(d.by_day)
    assert.is_number(d.failed_logins_24h)
  end)

  it("export: text/csv, attachment, BOM, başlık, CSV injection kaçışı", function()
    local res = h.request("GET", "/audit/export?action=todo.create", nil, admin.access_token)
    assert.equal(200, res.status)
    assert.truthy(res.headers["content-type"]:find("text/csv"))
    assert.truthy(res.headers["content-disposition"]:find("attachment"))
    assert.equal("\239\187\191", res.raw:sub(1, 3))
    assert.truthy(res.raw:sub(4, 200):find("action"))
    assert.truthy(res.raw:find("'=HYPERLINK", 1, true))
  end)

  it("todouser /audit/* → 403", function()
    for _, p in ipairs({ "/audit/logs", "/audit/stats", "/audit/export" }) do
      assert.equal(403, h.request("GET", p, nil, user.access_token).status, p)
    end
  end)

  it("00 §8: todo/user/rbac/access olaylarının hepsi kayıtlı", function()
    local seen = {}
    for _, r in ipairs(h.audit(admin.access_token)) do seen[r.action] = true end
    for _, a in ipairs({ "todo.create", "todo.update", "todo.delete", "user.create", "user.update",
                         "user.delete", "rbac.matrix.update", "access.denied", "auth.login.success" }) do
      assert.is_true(seen[a] == true, "audit yok: " .. a)
    end
  end)
end)
