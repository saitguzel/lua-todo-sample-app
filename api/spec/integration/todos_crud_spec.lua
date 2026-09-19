-- Todos CRUD entegrasyon testleri (F11 §6.3): CRUD, sahiplik, filtre/sayfalama/sıralama, stats, güvenlik
local h = require("helpers.init")

describe("todos crud (integration)", function()
  local admin, user

  local function create(token, body)
    local res = h.request("POST", "/todos", body, token)
    assert(res.status == 201, "create: " .. tostring(res.status) .. " " .. res.raw)
    return res.body.data
  end

  setup(function()
    h.reset_db()
    admin = h.login_admin()
    user = h.login_user()
  end)

  it("user POST → 201 kendi id'siyle; başkasının user_id'si → 403 (F6 §sahiplik)", function()
    local res = h.request("POST", "/todos", { title = "Süt al", user_id = admin.user.id }, user.access_token)
    assert.equal(403, res.status)
    assert.equal("FORBIDDEN", h.code(res))
    local t = create(user.access_token, { title = "Süt al" })
    assert.equal(user.user.id, t.user_id)
    assert.equal("pending", t.status)
    assert.equal("medium", t.priority)
  end)

  it("kendi todo'su 200; başkasınınki 404 TODO_NOT_FOUND", function()
    local mine = create(user.access_token, { title = "Benim" })
    local theirs = create(admin.access_token, { title = "Admin'in" })
    assert.equal(200, h.request("GET", "/todos/" .. mine.id, nil, user.access_token).status)
    local res = h.request("GET", "/todos/" .. theirs.id, nil, user.access_token)
    assert.equal(404, res.status)
    assert.equal("TODO_NOT_FOUND", h.code(res))
  end)

  it("admin herkesinkini, user yalnızca kendisininkini görür", function()
    local all = h.request("GET", "/todos?per_page=100", nil, admin.access_token).body
    local own = h.request("GET", "/todos?per_page=100", nil, user.access_token).body
    assert.truthy(all.meta.total > own.meta.total)
    for _, t in ipairs(own.data) do assert.equal(user.user.id, t.user_id) end
  end)

  describe("filtre, sayfalama, sıralama", function()
    setup(function()
      h.sql("DELETE FROM todos")
      for i = 1, 45 do
        create(user.access_token, {
          title = (i == 1) and "süt ve ekmek" or ("iş " .. i),
          status = (i % 3 == 0) and "completed" or "pending",
          priority = (i % 5 == 0) and "high" or "low",
          tags = (i % 2 == 0) and { "work" } or { "home" },
          due_date = string.format("2026-10-%02dT09:00:00Z", (i % 28) + 1),
        })
      end
    end)

    it("?per_page=20&page=3 → 5 eleman, total 45, total_pages 3", function()
      local b = h.request("GET", "/todos?per_page=20&page=3", nil, user.access_token).body
      assert.equal(5, #b.data)
      assert.equal(45, b.meta.total)
      assert.equal(3, b.meta.total_pages)
    end)

    it("status, priority, tag, q, due_before filtreleri", function()
      local function total(qs) return h.request("GET", "/todos?" .. qs, nil, user.access_token).body.meta.total end
      assert.equal(15, total("status=completed"))
      assert.equal(9, total("priority=high"))
      assert.equal(22, total("tag=work"))
      assert.equal(1, total("q=s%C3%BCt"))
      assert.truthy(total("due_before=2026-10-05T00:00:00Z") > 0)
    end)

    it("per_page=101 → 422", function()
      assert.equal(422, h.request("GET", "/todos?per_page=101", nil, user.access_token).status)
    end)

    it("sort=-due_date azalan; whitelist dışı sort → 422", function()
      local d = h.request("GET", "/todos?sort=-due_date&per_page=5", nil, user.access_token).body.data
      assert.truthy(d[1].due_date >= d[2].due_date)
      local res = h.request("GET", "/todos?sort=password_hash", nil, user.access_token)
      assert.equal(422, res.status)
      assert.equal("VALIDATION_FAILED", h.code(res))
    end)

    it("SQL injection denemeleri 422 veya boş sonuç; tablo sağlam", function()
      local r1 = h.request("GET", "/todos?q=%27%3B%20DROP%20TABLE%20todos%3B%20--", nil, user.access_token)
      assert.truthy(r1.status == 422 or (r1.status == 200 and r1.body.meta.total == 0))
      local r2 = h.request("GET", "/todos?status=pending%27%20OR%20%271%27%3D%271", nil, user.access_token)
      assert.equal(422, r2.status)
      assert.equal(45, h.request("GET", "/todos", nil, user.access_token).body.meta.total)
    end)
  end)

  it("PUT zorunlu alan (title) eksik 422; PATCH tek alan 200 ve diğerleri değişmez", function()
    -- F6: todo_replace = todo_create şeması (user_id hariç) → yalnızca title zorunlu
    local t = create(user.access_token, { title = "Put", priority = "high", description = "d" })
    assert.equal(422, h.request("PUT", "/todos/" .. t.id, { status = "pending" }, user.access_token).status)
    local p = h.request("PATCH", "/todos/" .. t.id, { title = "Yeni" }, user.access_token)
    assert.equal(200, p.status)
    assert.equal("Yeni", p.body.data.title)
    assert.equal("high", p.body.data.priority)
    assert.equal("d", p.body.data.description)
    local put = h.request("PUT", "/todos/" .. t.id,
      { title = "Tam", status = "in_progress", priority = "low", description = h.null }, user.access_token)
    assert.equal(200, put.status)
    assert.equal("in_progress", put.body.data.status)
  end)

  it("completed → completed_at dolu; pending'e dönünce null", function()
    local t = create(user.access_token, { title = "Tamamla" })
    local c = h.request("PATCH", "/todos/" .. t.id, { status = "completed" }, user.access_token).body.data
    assert.is_string(c.completed_at)
    local p = h.request("PATCH", "/todos/" .. t.id, { status = "pending" }, user.access_token)
    assert.equal(p.raw:match('"completed_at":null') ~= nil, true)
  end)

  it("updated_at trigger: PATCH sonrası updated_at > created_at", function()
    local t = create(user.access_token, { title = "Zaman" })
    require("socket").sleep(0.02)
    h.request("PATCH", "/todos/" .. t.id, { title = "Zaman 2" }, user.access_token)
    local row = h.sql("SELECT (updated_at > created_at) AS ok FROM todos WHERE id = $1::uuid", t.id)[1]
    assert.is_true(row.ok)
  end)

  it("DELETE 204; tekrar GET 404; başkasınınkini silme 404", function()
    local t = create(user.access_token, { title = "Sil" })
    local other = create(admin.access_token, { title = "Admin sil" })
    assert.equal(204, h.request("DELETE", "/todos/" .. t.id, nil, user.access_token).status)
    assert.equal(404, h.request("GET", "/todos/" .. t.id, nil, user.access_token).status)
    assert.equal(404, h.request("DELETE", "/todos/" .. other.id, nil, user.access_token).status)
  end)

  it("geçersiz UUID → 404 (500 değil)", function()
    local res = h.request("GET", "/todos/abc", nil, user.access_token)
    assert.equal(404, res.status)
    assert.equal("TODO_NOT_FOUND", h.code(res))
  end)

  it("stats: status/priority anahtarları her zaman var, user yalnız kendi verisi", function()
    local s = h.request("GET", "/todos/stats", nil, user.access_token)
    assert.equal(200, s.status)
    local d = s.body.data
    for _, k in ipairs({ "pending", "in_progress", "completed" }) do assert.is_number(d.by_status[k], k) end
    for _, k in ipairs({ "low", "medium", "high" }) do assert.is_number(d.by_priority[k], k) end
    assert.is_number(d.total)
    assert.is_number(d.overdue)
    local mine = h.request("GET", "/todos?per_page=1", nil, user.access_token).body.meta.total
    assert.equal(mine, d.total)
  end)

  it("1 MiB üstü gövde → 413 PAYLOAD_TOO_LARGE", function()
    local big = '{"title":"' .. string.rep("a", 1024 * 1024 + 10) .. '"}'
    local res = h.request("POST", "/todos", big, user.access_token)
    assert.equal(413, res.status)
    assert.equal("PAYLOAD_TOO_LARGE", h.code(res))
  end)

  it("bozuk JSON → 400 BAD_REQUEST", function()
    local res = h.request("POST", "/todos", "{bozuk", user.access_token)
    assert.equal(400, res.status)
    assert.equal("BAD_REQUEST", h.code(res))
  end)

  it("bilinmeyen route → 404 NOT_FOUND", function()
    local res = h.request("GET", "/yok-boyle-bir-sey", nil, user.access_token)
    assert.equal(404, res.status)
    assert.equal("NOT_FOUND", h.code(res))
  end)
end)
