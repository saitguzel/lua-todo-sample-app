-- Auth akışı entegrasyon testleri (F11 §6.2): login, me, refresh, logout, forgot/reset, rate limit, audit
local h = require("helpers.init")

describe("auth flow (integration)", function()
  local admin

  setup(function()
    h.reset_db()
    admin = h.login_admin()
  end)

  it("başarılı login: token çifti, user, 9 anahtarlı permissions, password_hash yok", function()
    local res = h.request("POST", "/auth/login", h.ADMIN)
    assert.equal(200, res.status)
    local d = res.body.data
    assert.is_string(d.access_token)
    assert.is_string(d.refresh_token)
    assert.equal(h.ADMIN.email, d.user.email)
    assert.is_nil(res.raw:find("password_hash"))
    local n = 0
    for _ in pairs(d.permissions) do n = n + 1 end
    assert.equal(9, n)
  end)

  it("yanlış parola ve olmayan e-posta aynı 401 INVALID_CREDENTIALS + aynı mesaj", function()
    local a = h.request("POST", "/auth/login", { email = h.ADMIN.email, password = "Yanlis123!" })
    local b = h.request("POST", "/auth/login", { email = h.unique_email("yok"), password = "Yanlis123!" })
    assert.equal(401, a.status)
    assert.equal(401, b.status)
    assert.equal("INVALID_CREDENTIALS", h.code(a))
    assert.equal("INVALID_CREDENTIALS", h.code(b))
    assert.equal(a.body.error.message, b.body.error.message)
  end)

  it("geçersiz login gövdesi → 422 VALIDATION_FAILED", function()
    local res = h.request("POST", "/auth/login", { email = "bozuk" })
    assert.equal(422, res.status)
    assert.equal("VALIDATION_FAILED", h.code(res))
    assert.truthy(res.body.error.details.password)
  end)

  it("pasif kullanıcı → 403 ACCOUNT_DISABLED", function()
    local u = h.create_user(admin.access_token)
    assert.equal(200, h.request("PUT", "/users/" .. u.id, { is_active = false }, admin.access_token).status)
    local res = h.request("POST", "/auth/login", { email = u.email, password = u.password })
    assert.equal(403, res.status)
    assert.equal("ACCOUNT_DISABLED", h.code(res))
  end)

  it("6. başarısız deneme → 429 RATE_LIMITED + Retry-After", function()
    local email = h.unique_email("rl")
    for _ = 1, 5 do
      assert.equal(401, h.request("POST", "/auth/login", { email = email, password = "Yanlis123!" }).status)
    end
    local res = h.request("POST", "/auth/login", { email = email, password = "Yanlis123!" })
    assert.equal(429, res.status)
    assert.equal("RATE_LIMITED", h.code(res))
    assert.truthy(tonumber(res.headers["retry-after"]))
  end)

  it("/auth/me: token ile 200, tokensız ve bozuk token 401 UNAUTHORIZED", function()
    local me = h.request("GET", "/auth/me", nil, admin.access_token)
    assert.equal(200, me.status)
    assert.equal(h.ADMIN.email, me.body.data.user.email)
    assert.is_table(me.body.data.permissions)
    local none = h.request("GET", "/auth/me")
    assert.equal(401, none.status)
    assert.equal("UNAUTHORIZED", h.code(none))
    assert.equal("UNAUTHORIZED", h.code(h.request("GET", "/auth/me", nil, "bozuk.token.x")))
  end)

  it("refresh rotasyonu; eski refresh token → 401 TOKEN_REVOKED", function()
    local s = h.login_admin()
    local r1 = h.request("POST", "/auth/refresh", { refresh_token = s.refresh_token })
    assert.equal(200, r1.status)
    assert.is_string(r1.body.data.access_token)
    assert.not_equal(s.refresh_token, r1.body.data.refresh_token)
    local r2 = h.request("POST", "/auth/refresh", { refresh_token = s.refresh_token })
    assert.equal(401, r2.status)
    assert.equal("TOKEN_REVOKED", h.code(r2))
  end)

  it("access token ile refresh denemesi → 401", function()
    local s = h.login_admin()
    assert.equal(401, h.request("POST", "/auth/refresh", { refresh_token = s.access_token }).status)
  end)

  it("logout 204 (gövdesiz); sonra access ve refresh reddedilir", function()
    local s = h.login_admin()
    local lo = h.request("POST", "/auth/logout", nil, s.access_token)
    assert.equal(204, lo.status)
    local me = h.request("GET", "/auth/me", nil, s.access_token)
    assert.equal(401, me.status)
    assert.equal("TOKEN_REVOKED", h.code(me))
  end)

  it("logout refresh token'ı da iptal eder", function()
    local s = h.login_admin()
    assert.equal(204, h.request("POST", "/auth/logout", { refresh_token = s.refresh_token }, s.access_token).status)
    assert.equal(401, h.request("POST", "/auth/refresh", { refresh_token = s.refresh_token }).status)
  end)

  describe("forgot / reset password", function()
    local u, token

    setup(function()
      u = h.create_user(admin.access_token)
    end)

    it("var olan e-posta → 202 ve MailHog'da reset linki", function()
      local res = h.request("POST", "/auth/forgot-password", { email = u.email })
      assert.equal(202, res.status)
      local body
      token, body = h.reset_token_from_mail(u.email)
      assert.is_string(token, "mail gelmedi veya link yok: " .. tostring(body))
      assert.equal(64, #token)
      assert.truthy(body:find("#/reset%-password%?token="))
    end)

    it("olmayan e-posta → aynı 202, mail yok", function()
      local email = h.unique_email("yok")
      local res = h.request("POST", "/auth/forgot-password", { email = email })
      assert.equal(202, res.status)
      assert.equal(0, h.mail_count(email))
    end)

    it("reset → 204; eski parola 401, yeni parola 200", function()
      local res = h.request("POST", "/auth/reset-password", { token = token, new_password = "Yeni1234!" })
      assert.equal(204, res.status)
      assert.equal(401, h.request("POST", "/auth/login", { email = u.email, password = u.password }).status)
      assert.is_not_nil(h.login(u.email, "Yeni1234!"))
    end)

    it("aynı token ikinci kez → 400 RESET_TOKEN_INVALID", function()
      local res = h.request("POST", "/auth/reset-password", { token = token, new_password = "Baska1234!" })
      assert.equal(400, res.status)
      assert.equal("RESET_TOKEN_INVALID", h.code(res))
    end)

    it("süresi dolmuş token → 400", function()
      assert.equal(202, h.request("POST", "/auth/forgot-password", { email = u.email }).status)
      h.sql("UPDATE password_reset_tokens SET expires_at = now() - interval '1 minute' WHERE used_at IS NULL")
      local raw = h.sql("SELECT count(*)::int AS n FROM password_reset_tokens WHERE user_id = $1::uuid", u.id)
      assert.truthy(raw[1].n >= 1)
      -- ham token yalnızca mailde: ikinci mail gelene kadar bekle, en yenisini al
      local deadline = h.now() + 2
      while h.mail_count(u.email) < 2 and h.now() < deadline do require("socket").sleep(0.1) end
      local fresh = h.reset_token_from_mail(u.email)
      local res = h.request("POST", "/auth/reset-password", { token = fresh, new_password = "Baska1234!" })
      assert.equal(400, res.status)
      assert.equal("RESET_TOKEN_INVALID", h.code(res))
    end)

    it("DB'de ham token saklanmaz", function()
      local rows = h.sql("SELECT token_hash FROM password_reset_tokens WHERE token_hash = $1", token)
      assert.equal(0, #rows)
    end)
  end)

  it("login sonrası last_login_at dolu", function()
    h.login_admin()
    local rows = h.sql("SELECT last_login_at FROM users WHERE email = $1", h.ADMIN.email)
    assert.is_string(rows[1].last_login_at)
  end)

  it("auth.* audit olayları yazıldı", function()
    local seen = {}
    for _, row in ipairs(h.audit(admin.access_token, "action=auth.*")) do seen[row.action] = true end
    for _, a in ipairs({ "auth.login.success", "auth.login.failure", "auth.logout", "auth.token.refresh",
                         "auth.password.reset.request", "auth.password.reset.success" }) do
      assert.is_true(seen[a] == true, "audit yok: " .. a)
    end
  end)
end)
