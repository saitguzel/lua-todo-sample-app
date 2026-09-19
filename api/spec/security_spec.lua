-- Security birim testleri (resty altında): random, password, jwt, audit.mask, user.serialize
-- ngx ve resty.* gerçek; yalnızca config modülü sahte tabloyla değiştirilir.
local cjson = require("cjson.safe")

local SECRET = "test-secret-32-byte-long-!!!!!!!"
local CFG = {
  argon2 = { t_cost = 3, m_cost = 12, parallelism = 1 },
  jwt = { secret = SECRET, issuer = "todo-api", access_ttl = 900, refresh_ttl = 604800 },
}
package.loaded["config"] = { get = function() return CFG end, current = CFG }
for _, m in ipairs({ "security.random", "security.password", "security.jwt" }) do package.loaded[m] = nil end

local random = require("security.random")
local password = require("security.password")
local jwt = require("security.jwt")
local resty_jwt = require("resty.jwt")

local USER = { id = "0b6b3c3e-1111-4222-8333-444455556666", email = "a@b.co", role = "admin" }

-- base64url (padding'siz) — sahte header'lı token üretmek için
local function b64url(s)
  return (ngx.encode_base64(s):gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

describe("random", function()
  it("uuid4 v4 deseni", function()
    local id = random.uuid4()
    assert.equal(36, #id)
    assert.truthy(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"))
  end)

  it("10.000 üretimde çakışma yok", function()
    local seen = {}
    for _ = 1, 10000 do
      local id = random.uuid4()
      assert.is_nil(seen[id])
      seen[id] = true
    end
  end)

  it("token 64 hex ve her çağrı farklı", function()
    local t1, t2 = random.token(), random.token()
    assert.equal(64, #t1)
    assert.truthy(t1:match("^%x+$"))
    assert.not_equal(t1, t2)
  end)
end)

describe("password", function()
  local h

  setup(function() h = assert(password.hash("Admin123!")) end)

  it("argon2id m=4096,t=3,p=1 öneki", function()
    assert.equal("$argon2id$v=19$m=4096,t=3,p=1$", h:sub(1, 30))
    assert.is_nil(h:find("%z"), "hash NUL byte içermemeli")
  end)

  it("aynı parola iki kez farklı hash (salt)", function()
    assert.not_equal(h, password.hash("Admin123!"))
  end)

  it("verify doğru/yanlış", function()
    assert.is_true(password.verify(h, "Admin123!"))
    assert.is_false(password.verify(h, "admin123!"))
  end)

  it("bozuk hash panik yapmaz", function()
    assert.is_false(password.verify("$argon2id$bozuk", "Admin123!"))
    assert.is_false(password.verify(nil, "Admin123!"))
  end)

  it("boş, nil ve 1025 byte parola reddedilir", function()
    assert.is_nil(password.hash(""))
    assert.is_nil(password.hash(nil))
    assert.is_nil(password.hash(string.rep("a", 1025)))
  end)

  it("needs_rehash maliyet artınca true", function()
    assert.is_false(password.needs_rehash(h))
    CFG.argon2.m_cost = 13
    assert.is_true(password.needs_rehash(h))
    CFG.argon2.m_cost = 12
  end)
end)

describe("jwt", function()
  it("access payload alanları ve TTL", function()
    local token = jwt.sign_access(USER)
    local p = assert(jwt.verify(token, "access"))
    for _, k in ipairs({ "sub", "user_id", "email", "role", "iat", "exp", "jti", "typ", "iss" }) do
      assert.is_not_nil(p[k], "eksik alan: " .. k)
    end
    assert.equal("access", p.typ)
    assert.equal(USER.id, p.sub)
    assert.equal(900, p.exp - p.iat)
  end)

  it("refresh typ ve TTL", function()
    local p = assert(jwt.verify(jwt.sign_refresh(USER), "refresh"))
    assert.equal("refresh", p.typ)
    assert.equal(604800, p.exp - p.iat)
  end)

  it("refresh token access olarak reddedilir", function()
    local p, err = jwt.verify(jwt.sign_refresh(USER), "access")
    assert.is_nil(p)
    assert.equal("UNAUTHORIZED", err)
  end)

  it("imzada 1 byte değişince UNAUTHORIZED", function()
    local token = jwt.sign_access(USER)
    local bad = token:sub(1, -2) .. (token:sub(-1) == "A" and "B" or "A")
    local p, err = jwt.verify(bad, "access")
    assert.is_nil(p)
    assert.equal("UNAUTHORIZED", err)
  end)

  it("alg none reddedilir", function()
    local now = ngx.time()
    local payload = { sub = USER.id, user_id = USER.id, iat = now, exp = now + 60, jti = "x", typ = "access",
                      iss = "todo-api" }
    local token = b64url('{"alg":"none","typ":"JWT"}') .. "." .. b64url(cjson.encode(payload)) .. "."
    assert.is_nil(jwt.verify(token, "access"))
  end)

  it("HS512 reddedilir (algoritma sabit)", function()
    local now = ngx.time()
    local token = resty_jwt:sign(SECRET, { header = { typ = "JWT", alg = "HS512" }, payload = {
      sub = USER.id, user_id = USER.id, iat = now, exp = now + 60, jti = "x", typ = "access", iss = "todo-api" } })
    assert.is_nil(jwt.verify(token, "access"))
  end)

  it("farklı secret reddedilir", function()
    local now = ngx.time()
    local token = resty_jwt:sign("baska-secret-32-byte-long-!!!!!!", { header = { typ = "JWT", alg = "HS256" },
      payload = { sub = USER.id, user_id = USER.id, iat = now, exp = now + 60, jti = "x", typ = "access",
                  iss = "todo-api" } })
    assert.is_nil(jwt.verify(token, "access"))
  end)

  it("farklı iss reddedilir", function()
    local now = ngx.time()
    local token = resty_jwt:sign(SECRET, { header = { typ = "JWT", alg = "HS256" }, payload = {
      sub = USER.id, user_id = USER.id, iat = now, exp = now + 60, jti = "x", typ = "access", iss = "kotu" } })
    assert.is_nil(jwt.verify(token, "access"))
  end)

  it("süresi geçmiş token TOKEN_EXPIRED", function()
    local now = ngx.time()
    local token = resty_jwt:sign(SECRET, { header = { typ = "JWT", alg = "HS256" }, payload = {
      sub = USER.id, user_id = USER.id, iat = now - 1000, exp = now - 100, jti = "x", typ = "access",
      iss = "todo-api" } })
    local p, err = jwt.verify(token, "access")
    assert.is_nil(p)
    assert.equal("TOKEN_EXPIRED", err)
  end)

  it("sha256_hex bilinen vektör", function()
    assert.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", jwt.sha256_hex("abc"))
  end)
end)

describe("audit.mask", function()
  local audit = require("models.audit")

  it("hassas alanlar recursive maskelenir, girdi değişmez", function()
    local input = { user = { password_hash = "s", email = "a@b.c" }, list = { { token = "t", refresh_token = "r" } },
                    new_password = "n", secret = "x", token_hash = "h", access_token = "a", password = "p" }
    local m = audit.mask(input)
    assert.equal("***", m.user.password_hash)
    assert.equal("a@b.c", m.user.email)
    assert.equal("***", m.list[1].token)
    assert.equal("***", m.list[1].refresh_token)
    for _, k in ipairs({ "new_password", "secret", "token_hash", "access_token", "password" }) do
      assert.equal("***", m[k], k)
    end
    assert.equal("s", input.user.password_hash)
  end)

  it("büyük/küçük harf duyarsız", function()
    assert.equal("***", audit.mask({ PASSWORD = "x" }).PASSWORD)
  end)

  it("döngüsel tabloda sonlanır", function()
    local t = { a = 1 }
    t.self = t
    assert.truthy(audit.mask(t))
  end)
end)

describe("user.serialize", function()
  local user_model = require("models.user")

  it("password_hash çıkmaz, nil alanlar cjson.null", function()
    local s = user_model.serialize({ id = "1", email = "a@b.c", password_hash = "hash", role = "admin",
                                     is_active = true, created_at = "2026-09-18 10:00:00+00" })
    assert.is_nil(s.password_hash)
    assert.equal(cjson.null, s.full_name)
    assert.equal(cjson.null, s.last_login_at)
    assert.is_nil(cjson.encode(s):find("password_hash"))
  end)
end)
