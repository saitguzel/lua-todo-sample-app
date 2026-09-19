# ═══ FAZ 5 — AUTH ENDPOINT'LERİ ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — error kodları (§5), env değişkenleri (§6),
> audit olayları (§8), shared dict'ler (§9), ngx.ctx (§10), teknik düzeltmeler #3, #4, #9.

## Amaç

Kimlik doğrulama akışının uçtan uca çalışır hale gelmesi: e-posta + parola ile giriş, access/refresh
JWT çifti üretimi, refresh token rotasyonu, logout ile token iptali (denylist), parola sıfırlama
(e-posta ile tek kullanımlık token) ve `GET /auth/me`. Bu fazın sonunda seed kullanıcıları
(`admin@todoapp.local`, `user@todoapp.local`) ile `curl` üzerinden login olunabilir, dönen token ile
korumalı bir endpoint çağrılabilir ve tüm auth olayları `audit_logs` tablosuna yazılır.

## Önkoşullar

| Faz | Neden |
|---|---|
| F1 | `validation` DSL, `protocol` error kodları, `types.ROLES` |
| F2 | `users`, `password_reset_tokens`, `audit_logs` tabloları + seed |
| F3 | `config`, `db/query.lua`, `router.lua` (`chain`), `error_handler` (`errors.new/respond`), `logger` (`req_id`) |
| F4 | `security/jwt.lua`, `security/password.lua`, `security/random.lua`, `models/user.lua`, `models/audit.lua` |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `api/src/services/auth_service.lua` | login / logout / refresh / forgot / reset / me iş kuralları, rate limit, token üretimi |
| `api/src/middleware/auth.lua` | Bearer token doğrulama → `ngx.ctx.identity` |
| `api/src/handlers/auth.lua` | 6 endpoint: body parse + validation + service çağrısı + yanıt zarfı |
| `api/src/mail/smtp.lua` | `lua-resty-mail` sarmalayıcısı; reset e-postası gönderimi |
| `api/src/services/audit_service.lua` | **Minimal sürüm**: `record(action, opts)` → doğrudan INSERT (F8'de genişletilir) |
| `api/src/repositories/user_repo.lua` | **Minimal sürüm**: auth'un ihtiyaç duyduğu sorgular (F7'de tamamlanır) |
| `api/src/router.lua` | (güncelleme) `/auth/*` route'larının kaydı |
| `api/spec/integration/auth_flow_spec.lua` | (iskelet) smoke test; F11'de genişletilir |

> Not: Ağaçta ayrı bir `password_reset_repo` yok. Reset token sorguları `user_repo.lua` içinde
> `reset_token_*` önekiyle tutulur (tek tabloya bağlı, 4 sorgu — ayrı dosya gereksiz).

---

## Endpoint Özeti

| Metot | Yol | Middleware | Başarı | Olası hatalar |
|---|---|---|---|---|
| POST | `/api/v1/auth/login` | cors, logger, audit_context | 200 | 422, 401 `INVALID_CREDENTIALS`, 403 `ACCOUNT_DISABLED`, 429 `RATE_LIMITED` |
| POST | `/api/v1/auth/logout` | + auth | 204 | 401 |
| POST | `/api/v1/auth/refresh` | cors, logger, audit_context | 200 | 422, 401 `UNAUTHORIZED` / `TOKEN_EXPIRED` / `TOKEN_REVOKED`, 403 `ACCOUNT_DISABLED` |
| POST | `/api/v1/auth/forgot-password` | cors, logger, audit_context | 202 (her zaman) | 422, 429 |
| POST | `/api/v1/auth/reset-password` | cors, logger, audit_context | 204 | 422, 400 `RESET_TOKEN_INVALID` |
| GET | `/api/v1/auth/me` | + auth | 200 | 401, 404 `USER_NOT_FOUND` |

`/auth/*` RBAC (authorization) dışındadır (bkz. 00 §7).

---

## Dosya Bazlı Tasarım

### 1. `api/src/handlers/auth.lua`

**Sorumluluk:** HTTP ↔ service çevirisi. SQL yok, iş kuralı yok.

**Validation şemaları** (F1 DSL; frontend ile paylaşılanlar `shared/src/validation.lua` →
`validation.schemas` altında, yoksa bu fazda eklenir):

| Şema | Alanlar |
|---|---|
| `login` | `email`: email, zorunlu, max 255 · `password`: string, zorunlu, 1–128 |
| `refresh` | `refresh_token`: string, zorunlu, max 2048 |
| `logout` | `refresh_token`: string, opsiyonel |
| `forgot_password` | `email`: email, zorunlu |
| `reset_password` | `token`: string, zorunlu, 64 hex · `new_password`: parola politikası (min 8, max 128, en az 1 büyük, 1 küçük, 1 rakam) |

Login şemasında parola politikası **uygulanmaz** (eski/farklı parolalar da `INVALID_CREDENTIALS`
dönmeli, politikayı sızdırmamalı); politika yalnızca `reset_password` ve F7 `users` şemalarında.

**İskelet:**

```lua
-- Auth HTTP handler'ları: girdi doğrular, auth_service'e delege eder, yanıt zarfını kurar.
local validation   = require("todo_shared.validation")
local errors       = require("middleware.error_handler")
local auth_service = require("services.auth_service")
local _M = {}

function _M.login(self)
  -- F3: errors.read_json_body() → BAD_REQUEST / PAYLOAD_TOO_LARGE
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end

  -- F1: validate → clean | nil, field_errors
  local clean, field_errors = validation.validate(validation.schemas.login, input)
  if not clean then
    return errors.respond(errors.validation(field_errors))
  end

  local result, serr = auth_service.login(clean.email, clean.password)
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result } }
end

-- logout, refresh, forgot_password, reset_password, me aynı kalıpla yazılır
return _M
```

> Gövde okuma F3'teki `errors.read_json_body()` (middleware/error_handler.lua) ile yapılır; ayrı `util/` dosyası yoktur.

**Yanıt şekilleri:**

```json
// POST /auth/login ve /auth/refresh → 200
{
  "data": {
    "access_token": "eyJhbGciOiJIUzI1NiIs...",
    "refresh_token": "eyJhbGciOiJIUzI1NiIs...",
    "token_type": "Bearer",
    "expires_in": 900,
    "refresh_expires_in": 604800,
    "user": {
      "id": "0b9c...", "email": "admin@todoapp.local", "full_name": "Sistem Yöneticisi",
      "role": "admin", "is_active": true, "last_login_at": "2026-09-18T10:12:00Z",
      "created_at": "...", "updated_at": "..."
    },
    "permissions": {
      "dashboard": true, "todos.list": true, "todos.create": true, "todos.edit": true,
      "users.list": true, "users.create": true, "rbac.matrix": true, "audit.logs": true, "settings": true
    }
  }
}

// POST /auth/forgot-password → 202
{ "data": { "message": "Eğer bu e-posta kayıtlıysa sıfırlama bağlantısı gönderildi." } }

// GET /auth/me → 200
{ "data": {
    "user": { "id": "...", "email": "...", "full_name": "...", "role": "todouser", ... },
    "permissions": { "dashboard": true, "todos.list": true, "todos.create": true, "todos.edit": true,
                     "users.list": false, "users.create": false, "rbac.matrix": false,
                     "audit.logs": false, "settings": false } } }
```

`user` alanı her zaman `models/user.lua` → `serialize()` çıktısıdır; `password_hash` asla dönmez.

**`permissions`** (login, refresh ve `/auth/me` yanıtlarında): `{ [page_key] = bool }` nesnesi, 9 anahtarın hepsi
mevcut (00 §7 sırası), kaynağı `rbac_service.permissions_for(role)` (F7, 60 sn cache). Frontend router guard'ı ve
menü görünürlüğü bunu kullanır (F13); todouser `/rbac/*`'a erişemediği için tek kaynak budur. F5 aşamasında
`rbac_service` henüz yoksa `types.default_permission` ile doldurulur; F7'de gerçek kaynağa geçilir (şekil değişmez).

---

### 2. `api/src/services/auth_service.lua`

**Public API:**

```lua
auth_service.login(email, password)                 --> { access_token, refresh_token, ..., user } | nil, err
auth_service.refresh(refresh_token)                 --> aynı şekil | nil, err
auth_service.logout(identity, refresh_token_or_nil) --> true
auth_service.forgot_password(email)                 --> true   (her zaman; hata sızdırmaz)
auth_service.reset_password(token, new_password)    --> true | nil, err
auth_service.me(identity)                           --> user | nil, err
auth_service.issue_tokens(user)                     --> token çifti (iç kullanım + test)
auth_service.revoke_jti(jti, exp)                   --> denylist'e ekler
auth_service.is_revoked(jti)                        --> bool
```

#### 2.1 Login akışı

```
login(email, password)
  │
  ├─ email_n = lower(trim(email))
  ├─ rate_limit anahtarı: "login:" .. ip .. ":" .. email_n   (ip = ngx.ctx.audit.ip)
  │     cnt = rate_limit:incr(key, 1, 0, 60)                 (init=0, init_ttl=60)
  │     cnt > LOGIN_RATE_LIMIT ?
  │        → audit auth.login.failure {email, reason="rate_limited"} status=failure
  │        → nil, RATE_LIMITED (details.retry_after = rate_limit:ttl(key))
  │
  ├─ user = user_repo.find_by_email(email_n)
  ├─ hash = user and user.password_hash or DUMMY_HASH       ← zamanlama saldırısı önlemi
  ├─ ok   = password.verify(hash, password)
  │
  ├─ not user or not ok
  │     → audit auth.login.failure {email, reason="invalid_credentials"}
  │     → nil, INVALID_CREDENTIALS ("E-posta veya parola hatalı")
  │
  ├─ not user.is_active
  │     → audit auth.login.failure {email, reason="disabled"}
  │     → nil, ACCOUNT_DISABLED
  │
  ├─ user_repo.touch_last_login(user.id)
  ├─ rate_limit:delete(key)                                  ← başarılı girişte sayaç sıfırlanır
  ├─ tokens = issue_tokens(user)
  ├─ audit auth.login.success {email}   (user_id = user.id)
  └─ return tokens
```

- `DUMMY_HASH`: modül yüklenirken `password.hash(random.hex(16))` ile **bir kez** üretilir
  (`init_by_lua` sırasında değil, ilk kullanımda lazy — argon2 init aşamasında gecikme yaratmasın).
- `ACCOUNT_DISABLED` kontrolü parola doğrulandıktan **sonra** yapılır; yanlış parola ile hesabın
  pasif olup olmadığı öğrenilemez.
- Rate limit sayacı parola doğru olsa bile limit aşıldıysa reddeder (brute-force'un son denemesi
  doğru bile olsa kabul edilmez).

#### 2.2 Token üretimi

```lua
function _M.issue_tokens(user)
  local now = ngx.time()
  local base = { sub = user.id, user_id = user.id, email = user.email, role = user.role,
                 iss = config.JWT_ISSUER, iat = now }

  local access = jwt.sign(tbl_merge(base, {
    typ = "access",  jti = random.uuid4(), exp = now + config.JWT_ACCESS_TTL }))
  local refresh = jwt.sign(tbl_merge(base, {
    typ = "refresh", jti = random.uuid4(), exp = now + config.JWT_REFRESH_TTL }))

  return {
    access_token = access, refresh_token = refresh, token_type = "Bearer",
    expires_in = config.JWT_ACCESS_TTL, refresh_expires_in = config.JWT_REFRESH_TTL,
    user = user_model.serialize(user),
  }
end
```

Payload tam olarak 00 §11 #9'daki alanlardır; ek alan eklenmez.

#### 2.3 Refresh akışı (rotasyon)

```
refresh(refresh_token)
  ├─ claims, err = jwt.verify(refresh_token)       → hata: UNAUTHORIZED / TOKEN_EXPIRED
  ├─ claims.typ ~= "refresh"                       → UNAUTHORIZED
  ├─ is_revoked(claims.jti)                        → TOKEN_REVOKED
  │      (tekrar kullanım = olası token hırsızlığı → warn logu, req_id + user_id ile)
  ├─ user = user_repo.find_by_id(claims.user_id)   → yoksa UNAUTHORIZED
  ├─ not user.is_active                            → ACCOUNT_DISABLED
  ├─ revoke_jti(claims.jti, claims.exp)            ← eski refresh token tek kullanımlık
  ├─ tokens = issue_tokens(user)                   ← rol/e-posta DB'den güncel okunur
  ├─ audit auth.token.refresh
  └─ return tokens
```

Rol değişikliği (F7) en geç bir sonraki refresh'te (≤ 15 dk) token'a yansır.

#### 2.4 Logout akışı

```
logout(identity, refresh_token?)
  ├─ revoke_jti(identity.jti, identity.exp)                       ← mevcut access token
  ├─ refresh_token verilmişse:
  │     claims = jwt.verify(refresh_token)
  │     claims.typ == "refresh" and claims.user_id == identity.user_id
  │        → revoke_jti(claims.jti, claims.exp)
  │     (geçersizse sessizce yok say — logout her zaman başarılı)
  ├─ audit auth.logout
  └─ return true   → handler 204
```

#### 2.5 Denylist

```lua
local denylist = ngx.shared.jwt_denylist

function _M.revoke_jti(jti, exp)
  local ttl = exp - ngx.time()
  if ttl <= 0 then return true end              -- zaten süresi dolmuş
  local ok, err, forcible = denylist:set("jti:" .. jti, 1, ttl)
  if not ok then ngx.log(ngx.ERR, "denylist set başarısız: ", err) end
  if forcible then ngx.log(ngx.WARN, "jwt_denylist dolu, eski kayıtlar atıldı") end
  return ok
end

function _M.is_revoked(jti)
  return denylist:get("jti:" .. jti) ~= nil
end
```

- 10 MiB dict ≈ 80–100 bin jti. `forcible = true` uyarısı izlenir (F18 monitoring).
- **Bilinen sınır:** shared dict instance-local'dır; çok instance'lı dağıtımda logout diğer
  instance'larda access token'ın kalan ≤15 dk'sı boyunca geçerli kalır. Yükseltme yolu: Redis
  denylist (F18 "ölçekleme" notu). Aynı sınır refresh rotasyonu için de geçerlidir (iptal edilen
  refresh token başka instance'da bir kez daha kullanılabilir); README'de belgelenir.

#### 2.6 Forgot password akışı

```
forgot_password(email)
  ├─ email_n = lower(trim(email))
  ├─ rate limit: "forgot:" .. ip  (aynı rate_limit dict, LOGIN_RATE_LIMIT/dk)  → RATE_LIMITED
  ├─ user = user_repo.find_by_email(email_n)
  ├─ user and user.is_active ise:
  │     raw   = random.hex(32)                        (64 hex karakter, 256 bit)
  │     hash  = sha256_hex(raw)                       (resty.sha256 + resty.string.to_hex)
  │     tx:
  │       user_repo.reset_token_invalidate_all(user.id)  ← önceki kullanılmamış token'lar used_at=now()
  │       user_repo.reset_token_create(user.id, hash, PASSWORD_RESET_TTL)
  │     link = WEB_BASE_URL .. "/#/reset-password?token=" .. raw
  │     ngx.timer.at(0, send_reset_mail, user.email, user.full_name, link)
  ├─ audit auth.password.reset.request {email}   (user yoksa user_id=nil, status=success)
  └─ return true   → handler HER ZAMAN 202
```

- E-posta **timer içinde** gönderilir: yanıt süresi kullanıcının var olup olmamasından bağımsız
  kalır (kullanıcı numaralandırma + zamanlama önlemi) ve SMTP yavaşlığı isteği bekletmez.
- Timer içinde `ngx.ctx` yoktur; gereken tüm değerler argüman olarak geçilir.
- SMTP hatası → `MAIL_FAILED` yalnızca `ngx.log(ngx.ERR, ...)` ile loglanır (00 §5).
- Ham token DB'ye **asla** yazılmaz; yalnızca SHA-256 hash'i. (Argon2 değil: token 256 bit
  entropili rastgele değer, yavaş hash gereksiz; `token_hash UNIQUE` ile doğrudan arama yapılır.)

#### 2.7 Reset password akışı

```
reset_password(token, new_password)
  ├─ hash     = sha256_hex(token)
  ├─ new_hash = password.hash(new_password)          ← argon2 tx DIŞINDA (satır kilidi uzamasın)
  ├─ with_transaction:
  │     row = user_repo.reset_token_find_valid_for_update(hash)
  │           -- used_at IS NULL AND expires_at > now()  FOR UPDATE
  │     not row → RESET_TOKEN_INVALID
  │     user_repo.update_password(row.user_id, new_hash)
  │     user_repo.reset_token_mark_used(row.id)
  │     user_repo.reset_token_invalidate_all(row.user_id)
  ├─ audit auth.password.reset.success (user_id = row.user_id)
  └─ return true → 204
```

- `FOR UPDATE` aynı token'ın iki paralel istekle iki kez kullanılmasını engeller.
- Argon2 hash'i transaction'dan **önce** hesaplanır: geçersiz token'da ~20 ms boşa CPU harcanır
  ama satır kilidi ve açık transaction süresi kısa kalır.

#### 2.8 Me

`user_repo.find_by_id(identity.user_id)` → yoksa `USER_NOT_FOUND` (kullanıcı token geçerliyken
silinmiş olabilir) → `user_model.serialize(user)`.

---

### 3. `api/src/middleware/auth.lua`

**Public API:**

```lua
auth.required(self)   --> nil (devam) | response tablosu (erken dönüş)
auth.optional(self)   --> token varsa identity'yi doldurur, yoksa devam eder (şimdilik kullanılmıyor → YAGNI, yazılmaz)
```

**Akış:**

```lua
-- Bearer token'ı doğrular ve ngx.ctx.identity'yi doldurur.
local jwt          = require("security.jwt")
local errors       = require("middleware.error_handler")
local auth_service = require("services.auth_service")

local _M = {}

function _M.required(self)
  local header = ngx.var.http_authorization
  local token = header and header:match("^[Bb]earer%s+([%w%-_%.]+)$")
  if not token then
    return errors.respond(errors.new("UNAUTHORIZED", "Kimlik doğrulama gerekli"))
  end

  local claims, err = jwt.verify(token)            -- imza, iss, exp kontrolü F4'te
  if not claims then
    local code = (err == "expired") and "TOKEN_EXPIRED" or "UNAUTHORIZED"
    return errors.respond(errors.new(code, "Geçersiz veya süresi dolmuş token"))
  end
  if claims.typ ~= "access" then
    return errors.respond(errors.new("UNAUTHORIZED", "Geçersiz token türü"))
  end
  if auth_service.is_revoked(claims.jti) then
    return errors.respond(errors.new("TOKEN_REVOKED", "Token iptal edilmiş"))
  end

  ngx.ctx.identity = {
    user_id = claims.user_id, email = claims.email, role = claims.role,
    jti = claims.jti, exp = claims.exp,
  }
end

return _M
```

- DB'ye gidilmez (her istekte `is_active` kontrolü yok). **Bilinen sınır:** pasifleştirilen
  kullanıcının access token'ı ≤15 dk geçerli kalır; refresh reddedilir (2.3). F7'de kullanıcı
  pasifleştirme/silme sırasında mevcut token'lar iptal edilemez (jti bilinmez) → belgelenir.
- `401` yanıtlarına `WWW-Authenticate: Bearer error="invalid_token"` header'ı eklenir (RFC 6750).

---

### 4. `api/src/repositories/user_repo.lua` (minimal)

Tüm sorgular `db/query.lua` → `query.query(sql, ...)` ile, `$n` parametreli.

| Fonksiyon | SQL |
|---|---|
| `find_by_email(email)` | `SELECT * FROM users WHERE email = $1 LIMIT 1` |
| `find_by_id(id)` | `SELECT * FROM users WHERE id = $1 LIMIT 1` |
| `touch_last_login(id)` | `UPDATE users SET last_login_at = now() WHERE id = $1` |
| `update_password(id, hash)` | `UPDATE users SET password_hash = $2 WHERE id = $1` |
| `reset_token_create(user_id, hash, ttl)` | `INSERT INTO password_reset_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, now() + make_interval(secs => $3))` |
| `reset_token_find_valid_for_update(hash)` | `SELECT id, user_id FROM password_reset_tokens WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now() FOR UPDATE` |
| `reset_token_mark_used(id)` | `UPDATE password_reset_tokens SET used_at = now() WHERE id = $1` |
| `reset_token_invalidate_all(user_id)` | `UPDATE password_reset_tokens SET used_at = now() WHERE user_id = $1 AND used_at IS NULL` |

Email her zaman servis katmanında `lower(trim())` ile normalize edilir; F2 seed'leri de küçük harf yazar.

---

### 5. `api/src/mail/smtp.lua`

**Bağımlılık:** `lua-resty-mail` (00 §11 #3).

**Public API:**

```lua
smtp.send({ to = "a@b.c", subject = "...", text = "...", html = "..." })  --> true | nil, err
smtp.render_reset_mail(full_name, link)  --> { subject, text, html }
```

**Tasarım:**

```lua
-- SMTP gönderimi: lua-resty-mail üzerinden, config'ten bağlantı ayarlarıyla.
local mail   = require("resty.mail")
local config = require("config")

local _M = {}

function _M.send(msg)
  local mailer, err = mail.new({
    host = config.SMTP_HOST, port = config.SMTP_PORT,
    starttls = config.SMTP_TLS,
    username = config.SMTP_USER ~= "" and config.SMTP_USER or nil,
    password = config.SMTP_PASSWORD ~= "" and config.SMTP_PASSWORD or nil,
    timeout_connect = 5000, timeout_send = 5000, timeout_read = 5000,
  })
  if not mailer then return nil, "MAIL_FAILED: " .. tostring(err) end

  local ok, serr = mailer:send({
    from = config.SMTP_FROM, to = { msg.to }, subject = msg.subject,
    text = msg.text, html = msg.html,
  })
  if not ok then return nil, "MAIL_FAILED: " .. tostring(serr) end
  return true
end

return _M
```

- Şablon: düz metin + basit HTML, Türkçe; `full_name` ve `link` HTML-escape edilir.
- Geliştirmede `mailhog` (docker-compose, F0) SMTP 1025 / UI 8025 portunda.
- Retry yok (YAGNI): kullanıcı "tekrar gönder" ile yeniden deneyebilir.

---

### 6. `api/src/services/audit_service.lua` (minimal sürüm)

F8'de `audit_repo` + maskeleme genişletilir; bu fazda şu sözleşme **sabitlenir** (F8 imzayı değiştirmez):

```lua
audit_service.record(action, opts)  --> true | nil, err  (asla error fırlatmaz)
-- opts = {
--   entity_type = "user", entity_id = "...",
--   old_value = tbl|nil, new_value = tbl|nil,
--   status = "success"|"failure", error_message = "...",
--   user_id = "...", user_email = "...",   -- verilmezse ngx.ctx.identity'den
-- }
```

- `ip_address`, `user_agent` → `ngx.ctx.audit` (F8'deki audit_context; bu fazda F3 logger yanında
  basit hali yoksa `ngx.var.remote_addr` / `ngx.var.http_user_agent` fallback).
- Yazım `pcall` ile sarılır; audit hatası ana isteği **başarısız kılmaz**, `ngx.ERR` loglanır.
- Audit, iş transaction'ı **commit edildikten sonra** ayrı sorgu ile yazılır (rollback'te
  failure kaydı kaybolmasın diye).
- Maskeleme bu fazda da uygulanır (F4 `models/audit.lua` → `mask()`).

---

### 7. `api/src/router.lua` güncellemesi

```lua
local public  = { cors.handle, logger.handle, audit_context.handle }
local private = { cors.handle, logger.handle, audit_context.handle, auth.required }

app:post("/api/v1/auth/login",           chain(public,  auth_h.login))
app:post("/api/v1/auth/logout",          chain(private, auth_h.logout))
app:post("/api/v1/auth/refresh",         chain(public,  auth_h.refresh))
app:post("/api/v1/auth/forgot-password", chain(public,  auth_h.forgot_password))
app:post("/api/v1/auth/reset-password",  chain(public,  auth_h.reset_password))
app:get ("/api/v1/auth/me",              chain(private, auth_h.me))
```

`public` / `private` zincir tabloları modül seviyesinde **bir kez** oluşturulur (her istekte yeni tablo yok).

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Stateless JWT + jti denylist (shared dict) | Her istekte DB sorgusu yok; logout/rotasyon yine mümkün (00 §11 #9) |
| Refresh token rotasyonu (tek kullanımlık) | Çalınan refresh token'ın ömrünü kısaltır; tekrar kullanım loglanır |
| Refresh'te kullanıcı DB'den okunur | Rol/aktiflik değişiklikleri ≤15 dk'da yansır |
| DUMMY_HASH ile sabit süreli login | Kullanıcı varlığını yanıt süresinden sızdırmaz |
| Forgot her zaman 202 + mail timer'da | E-posta numaralandırmasını engeller |
| Reset token = 256-bit random, DB'de SHA-256 | Ham token sızdırmaz; hızlı hash yeterli (yüksek entropi) |
| Rate limit: `ngx.shared.rate_limit:incr` (init_ttl) | Ek bağımlılık yok (lua-resty-limit-traffic gereksiz); sabit pencere yeterli |
| Password reset repo ayrı dosya değil | Ağaçta yok; 4 sorgu `user_repo`'da |
| Token'lar body'de döner, cookie değil | Frontend WASM + `Authorization` header (F13 fetch.lua); CSRF yüzeyi yok. XSS riski F12 CSP ile azaltılır |

## Kabul kriterleri (DoD)

- [ ] Seed admin ile `POST /auth/login` 200 döner; `access_token`, `refresh_token`, `user` alanları var, `password_hash` yok.
- [ ] Yanlış parola ve olmayan e-posta **aynı** yanıtı (`401 INVALID_CREDENTIALS`) ve benzer süreyi (±%20) verir.
- [ ] Pasif kullanıcı doğru parolayla `403 ACCOUNT_DISABLED` alır; yanlış parolayla `401`.
- [ ] Aynı IP+e-posta ile 6. deneme `429 RATE_LIMITED` + `Retry-After` header döner; 60 sn sonra açılır.
- [ ] Access token ile `GET /auth/me` 200; token'sız 401 `UNAUTHORIZED`; süresi dolmuşla 401 `TOKEN_EXPIRED`.
- [ ] Refresh token `Authorization` header'ında kullanılırsa 401 (`typ` kontrolü).
- [ ] `POST /auth/refresh` yeni çift döner; **aynı** refresh token ikinci kez kullanıldığında 401 `TOKEN_REVOKED`.
- [ ] `POST /auth/logout` sonrası aynı access token ile `/auth/me` 401 `TOKEN_REVOKED`.
- [ ] `forgot-password` kayıtlı ve kayıtsız e-posta için aynı 202 gövdesini döner; kayıtlıda MailHog'a e-posta düşer.
- [ ] E-postadaki token ile `reset-password` 204; aynı token ikinci kez 400 `RESET_TOKEN_INVALID`; yeni parola ile login olur, eskisiyle olmaz.
- [ ] Süresi dolmuş token (`PASSWORD_RESET_TTL` sonrası) 400 döner.
- [ ] `password_reset_tokens.token_hash` alanında ham token bulunmaz.
- [ ] `audit_logs`'ta 00 §8'deki `auth.*` olaylarının her biri oluşur; `new_value` içinde parola/token alanı yok ya da `"***"`.
- [ ] Audit INSERT'i başarısız olduğunda (tablo geçici kilitli vb.) login yine başarılı döner, hata loglanır.
- [ ] Login, refresh ve `/auth/me` yanıtlarında `permissions` nesnesi 9 page key'in hepsini boolean olarak içerir; `/auth/me` şekli `{ data: { user, permissions } }`.
- [ ] `luacheck api/src` temiz.

## Doğrulama

```bash
make up && make db.migrate && SEED_DEFAULTS=true make db.seed

# 1) Login
curl -s -X POST localhost:28080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@todoapp.local","password":"Admin123!"}' | jq .
# Beklenen: .data.access_token, .data.user.role == "admin"

ACCESS=$(curl -s -X POST localhost:28080/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"admin@todoapp.local","password":"Admin123!"}' | jq -r .data.access_token)
REFRESH=$(curl -s -X POST localhost:28080/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"admin@todoapp.local","password":"Admin123!"}' | jq -r .data.refresh_token)

# 2) Me
curl -s localhost:28080/api/v1/auth/me -H "Authorization: Bearer $ACCESS" | jq .data.email
# Beklenen: "admin@todoapp.local"

# 3) Yanlış parola
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:28080/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"email":"admin@todoapp.local","password":"x"}'
# Beklenen: 401

# 4) Rate limit (6 deneme)
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -w '%{http_code} ' -X POST localhost:28080/api/v1/auth/login \
    -H 'Content-Type: application/json' -d '{"email":"rl@test.local","password":"x"}'
done; echo
# Beklenen: 401 401 401 401 401 429

# 5) Refresh rotasyonu
curl -s -X POST localhost:28080/api/v1/auth/refresh -H 'Content-Type: application/json' \
  -d "{\"refresh_token\":\"$REFRESH\"}" | jq -r .data.token_type      # Bearer
curl -s -X POST localhost:28080/api/v1/auth/refresh -H 'Content-Type: application/json' \
  -d "{\"refresh_token\":\"$REFRESH\"}" | jq -r .error.code           # TOKEN_REVOKED

# 6) Logout
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:28080/api/v1/auth/logout \
  -H "Authorization: Bearer $ACCESS"                                    # 204
curl -s localhost:28080/api/v1/auth/me -H "Authorization: Bearer $ACCESS" | jq -r .error.code
# Beklenen: TOKEN_REVOKED

# 7) Forgot + reset
curl -s -X POST localhost:28080/api/v1/auth/forgot-password -H 'Content-Type: application/json' \
  -d '{"email":"user@todoapp.local"}' -w '\n%{http_code}\n'            # 202
# MailHog UI: http://localhost:28025 → linkteki token'ı al
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:28080/api/v1/auth/reset-password \
  -H 'Content-Type: application/json' -d '{"token":"<TOKEN>","new_password":"NewPass123!"}'  # 204

# 8) Audit kontrolü
docker compose exec postgres psql -U todo -c \
  "SELECT action, status, user_email FROM audit_logs ORDER BY id DESC LIMIT 10;"

# 9) Smoke spec
make test.integration SPEC=api/spec/integration/auth_flow_spec.lua
```

## Riskler / Dikkat Noktaları

| Risk | Etki | Önlem |
|---|---|---|
| Argon2 CPU-bloklayıcı; login yükü worker'ı kilitler | Diğer isteklerde gecikme | Rate limit; `worker_processes auto`; F11 wrk ile login p99 ölçümü |
| Denylist instance-local | Çok instance'da logout ≤15 dk gecikmeli etkili | Belgelenir; yükseltme: Redis |
| `jwt_denylist` dolması (`forcible`) | İptal edilmiş token'lar tekrar geçerli olabilir | Boyut 10m; `forcible` WARN logu + F18 alarmı |
| Parola sıfırlama sonrası eski refresh token'lar geçerli | Ele geçirilmiş oturum 7 güne kadar sürebilir | **Bilinen sınır**; yükseltme: `users.token_version` kolonu (şema değişikliği gerektirir, bu fazda yapılmaz) |
| `X-Forwarded-For` sahteciliği rate limit'i atlatır | Brute-force | IP yalnızca `TRUSTED_PROXIES` üzerinden (F8 audit_context) |
| SMTP timeout timer'ı uzun tutar | Timer havuzu dolması | 5 sn timeout'lar; `lua_max_pending_timers` default yeterli |
| Token'ların localStorage'da tutulması (F13) | XSS ile çalınma | F12 CSP + F16'da `textContent` kullanımı (innerHTML yok) |

## Tahmini Efor

**L** (2–3 gün): auth_service + middleware 1 gün, forgot/reset + SMTP 0.5 gün, audit minimal + testler 1 gün.
