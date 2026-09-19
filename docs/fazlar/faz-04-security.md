# ═══ FAZ 4 — SECURITY ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — env (§6: `JWT_*`, `ARGON2_*`), maskelenen alanlar (§8), shared dict `jwt_denylist` (§9), teknik düzeltmeler #4 (argon2), #9 (JWT payload).

## Amaç

Kimlik doğrulama ve denetimin dayandığı kriptografik primitifleri ve iki temel modeli yazmak: CSPRNG tabanlı rastgelelik (UUID v4, token), Argon2id parola hash'leme, HS256 JWT üretme/doğrulama, `User` ve `AuditLog` modelleri (serileştirme + hassas alan maskeleme). Bu fazın sonunda tüm primitifler birim testleriyle kanıtlanmış, `SEED_DEFAULTS=true make db.seed` gerçek Argon2id hash'li kullanıcılar oluşturuyor.

## Önkoşullar

- FAZ 1 (`todo_shared.types`).
- FAZ 2 (`seeds/default_users.lua` bu fazın `password.hash`'ini bekliyor).
- FAZ 3 (`config.lua`, `security/random.lua` minimal sürüm).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/security/random.lua` | `bytes`, `hex`, `uuid4`, `token` (F3 minimal sürümün tamamlanması) |
| `api/src/security/password.lua` | Argon2id `hash`, `verify`, `needs_rehash`, zamanlama-sabit sahte doğrulama |
| `api/src/security/jwt.lua` | `sign_access`, `sign_refresh`, `verify`, `sha256_hex` yardımcı |
| `api/src/models/user.lua` | `from_row`, `serialize` (public), `serialize_for_audit` (maskeli) |
| `api/src/models/audit.lua` | `mask(value)`, `from_row`, `serialize`, `SENSITIVE_KEYS` |
| `api/spec/security_spec.lua` | Bu fazın birim testleri (F11'de genişletilir) |

## Dosya Bazlı Tasarım

### `api/src/security/random.lua`

```lua
-- Kriptografik rastgelelik: resty.random (OpenSSL RAND_bytes, strong = true).
-- math.random ASLA güvenlik amaçlı kullanılmaz.
local resty_random = require("resty.random")
local resty_string = require("resty.string")
local _M = {}

-- n byte ham rastgele veri; OpenSSL başarısız olursa error (sessizce zayıf veri üretmez)
function _M.bytes(n)
  local b = resty_random.bytes(n, true)
  if not b then error("CSPRNG başarısız", 0) end
  return b
end

-- n byte → 2n karakter hex
function _M.hex(n) return resty_string.to_hex(_M.bytes(n)) end

-- RFC 4122 sürüm 4 UUID: 16 byte, byte[6] = 0100xxxx, byte[8] = 10xxxxxx
function _M.uuid4()
  local b = { string.byte(_M.bytes(16), 1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local h = resty_string.to_hex(string.char(unpack(b)))
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

-- Opak token (reset token): 32 byte = 256 bit entropi → 64 hex karakter
function _M.token() return _M.hex(32) end

return _M
```

LuaJIT `bit` kütüphanesi kullanılır (backend; 5.1 uyumluluğu yalnızca shared için geçerli).

### `api/src/security/password.lua`

```lua
-- Argon2id parola hash'leme (LuaRocks: argon2 — thibaultcha/lua-argon2).
-- Encoded format: $argon2id$v=19$m=4096,t=3,p=1$<salt_b64>$<hash_b64>
local argon2 = require("argon2")
local config = require("config")
local random = require("security.random")
local _M = {}

local SALT_BYTES = 16

local function options()
  local c = config.get().argon2
  return {
    variant     = argon2.variants.argon2_id,
    t_cost      = c.t_cost,               -- 3
    m_cost      = 2 ^ c.m_cost,           -- KiB: 2^12 = 4096 KiB = 4 MiB
    parallelism = c.parallelism,          -- 1
    hash_len    = 32,
  }
end

-- @return encoded_hash | nil, err
function _M.hash(plain)
  if type(plain) ~= "string" or #plain == 0 or #plain > 1024 then
    return nil, "geçersiz parola girdisi"
  end
  local encoded, err = argon2.hash_encoded(plain, random.bytes(SALT_BYTES), options())
  if not encoded then return nil, err end
  return encoded
end

-- @return true | false  (hata durumunda false; hata loglanır)
function _M.verify(encoded, plain)
  local ok, err = argon2.verify(encoded, plain)
  if err then ngx.log(ngx.WARN, "argon2 verify hatası: ", err) end
  return ok == true
end

-- Kayıtlı hash'in parametreleri mevcut config'ten zayıfsa true (login sonrası sessizce yeniden hash'lenir)
function _M.needs_rehash(encoded) end
--  encoded'dan m=, t=, p= parse et; m < 2^m_cost veya t < t_cost veya p ~= parallelism → true

-- Kullanıcı bulunamadığında zamanlama farkıyla e-posta sızdırmamak için sahte doğrulama
local DUMMY_HASH -- ilk çağrıda bir kez üretilir (lazy)
function _M.dummy_verify(plain)
  if not DUMMY_HASH then DUMMY_HASH = assert(_M.hash("dummy-password-for-timing")) end
  _M.verify(DUMMY_HASH, plain)
  return false
end

return _M
```

**Parametreler ve performans (00-genel-bakis #4):**

| Parametre | Değer | Anlam |
|---|---|---|
| `t_cost` | 3 | 3 geçiş |
| `m_cost` | `2^12` KiB | 4 MiB bellek (prompt değeri) |
| `parallelism` | 1 | OpenResty worker tek thread |
| salt | 16 byte CSPRNG | her hash için yeni |
| hash_len | 32 byte | |

- Hash süresi (m=4 MiB, t=3) ≈ 5–15 ms; bu süre boyunca **worker bloklanır** (C çağrısı, yield yok). Login rate limit (F5) ve eşzamanlı login'lerin worker'lara dağılması bunu kabul edilebilir kılar.
- OWASP önerisi: m=19 MiB (`ARGON2_M_COST=15`, ≈ 2^15 KiB = 32 MiB yakın üst değer; 19 MiB tam karşılığı `2^m` ile ifade edilemez → 15 önerilir). README'de not.
- `needs_rehash` sayesinde `ARGON2_M_COST` artırıldığında kullanıcılar bir sonraki başarılı login'de otomatik yükseltilir (F5 `auth_service.login`).
- Parola politikası (min 8, büyük/küçük/rakam) `validation.password()`'dadır (F1), burada değil.

### `api/src/security/jwt.lua`

```lua
-- HS256 JWT üretme ve doğrulama (lua-resty-jwt).
-- Payload (00-genel-bakis #9): { sub, user_id, email, role, iat, exp, jti, typ, iss }
local resty_jwt = require("resty.jwt")
local validators = require("resty.jwt-validators")
local config = require("config")
local random = require("security.random")
local _M = {}

local function sign(user, typ, ttl)
  local c = config.get().jwt
  local now = ngx.time()
  local payload = {
    sub = user.id, user_id = user.id, email = user.email, role = user.role,
    iat = now, exp = now + ttl, jti = random.uuid4(), typ = typ, iss = c.issuer,
  }
  local token = resty_jwt:sign(c.secret, { header = { typ = "JWT", alg = "HS256" }, payload = payload })
  return token, payload
end

-- @return token, payload
function _M.sign_access(user)  return sign(user, "access",  config.get().jwt.access_ttl)  end
function _M.sign_refresh(user) return sign(user, "refresh", config.get().jwt.refresh_ttl) end

-- Doğrulama: imza, alg == HS256 (alg=none / RS256 saldırılarına karşı), exp, iss, typ
-- @return payload | nil, code   (code: "TOKEN_EXPIRED" | "UNAUTHORIZED")
function _M.verify(token, expected_typ)
  if type(token) ~= "string" or #token > 4096 then return nil, "UNAUTHORIZED" end
  local c = config.get().jwt
  local obj = resty_jwt:verify(c.secret, token, {
    exp = validators.is_not_expired(),
    iss = validators.equals(c.issuer),
    typ = validators.equals(expected_typ),
    jti = validators.required(),
    user_id = validators.required(),
  })
  if not obj.verified then
    if obj.reason and obj.reason:find("expired") then return nil, "TOKEN_EXPIRED" end
    return nil, "UNAUTHORIZED"
  end
  if obj.header.alg ~= "HS256" then return nil, "UNAUTHORIZED" end
  return obj.payload
end

-- Refresh token'ın kalan ömrü (denylist TTL'i için)
function _M.remaining_ttl(payload) return math.max(payload.exp - ngx.time(), 1) end

-- SHA-256 hex (reset token hash'i için; F5 kullanır)
function _M.sha256_hex(s) end   -- resty.sha256 + resty.string.to_hex

return _M
```

**Güvenlik kararları:**

| Tehdit | Önlem |
|---|---|
| `alg: none` | lua-resty-jwt `verify` secret ile HS256 bekler + header `alg` açıkça kontrol edilir |
| Algoritma karışıklığı (RS256 public key'i HMAC secret olarak) | Yalnızca HS256 kabul |
| Refresh token'ı access olarak kullanma | `typ` doğrulaması (`expected_typ`) |
| Çalınan token | Access kısa ömürlü (15 dk); refresh rotasyonu + denylist (F5) |
| Aşırı büyük token (DoS) | 4096 byte sınırı |
| Rol değişikliği sonrası eski token | Access token 15 dk içinde doğal olarak düşer; kullanıcı pasifleştirme/silme için auth middleware `is_active`'i **kontrol etmez** (performans) → F7'de kullanıcı güncelleme/silme `jwt_denylist`'e ilgili kullanıcının aktif jti'lerini ekleyemediği için (jti'ler saklanmıyor) kabul edilen risk: max 15 dk. Refresh sırasında DB'den `is_active` + güncel `role` okunur (F5). |
| Saat kayması | `ngx.time()` sunucu saatine bağlı; tek sunucu doğrular → leeway gereksiz |

`JWT_SECRET` ≥ 32 byte kontrolü `config.lua`'da (F3).

### `api/src/models/user.lua`

```lua
-- Kullanıcı modeli: DB satırı → Lua tablosu, public serileştirme.
-- password_hash hiçbir public çıktıya girmez.
local cjson = require("cjson.safe")
local audit = require("models.audit")
local _M = {}

-- DB satırı (pgmoon) → model
function _M.from_row(row)
  if not row then return nil end
  return {
    id = row.id, email = row.email, password_hash = row.password_hash,
    full_name = row.full_name, role = row.role, is_active = row.is_active,
    last_login_at = row.last_login_at, created_at = row.created_at, updated_at = row.updated_at,
  }
end

-- API yanıtı: password_hash YOK; nil alanlar cjson.null (alan her zaman mevcut → şema sabit)
function _M.serialize(u)
  return {
    id = u.id, email = u.email, full_name = u.full_name or cjson.null,
    role = u.role, is_active = u.is_active,
    last_login_at = u.last_login_at or cjson.null,
    created_at = u.created_at, updated_at = u.updated_at,
  }
end

-- Audit old/new değeri: tüm alanlar + maskeleme (password_hash → "***")
function _M.serialize_for_audit(u) return audit.mask(_M.from_row(u)) end

-- Repo'larda kullanılacak kolon listesi (SELECT * yerine)
_M.COLUMNS = "id, email, password_hash, full_name, role, is_active, last_login_at, created_at, updated_at"
_M.PUBLIC_COLUMNS = "id, email, full_name, role, is_active, last_login_at, created_at, updated_at"

return _M
```

Zaman damgaları: pgmoon `TIMESTAMPTZ`'yi string döner (`2026-09-18 10:00:00.123+00`). API ISO-8601 bekler → repo sorgularında `to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at` yerine daha basit karar: **oturum başına** `SET TIME ZONE 'UTC'` + pgmoon'un döndüğü değeri modelde `iso8601(s)` yardımcı fonksiyonuyla `"2026-09-18T10:00:00.123Z"`'ye çevirme. `iso8601` bu modülde değil `models/audit.lua` yanında ortak bir yerel yardımcıya gerek olmadan her iki modelde kullanılacağı için `models/user.lua` içinde tanımlanıp `_M.iso8601` olarak export edilir (todo modeli de kullanır, F6).

Bağlantı timezone'u: `db/pool.lua` `acquire` sonrası yeni bağlantıda (pgmoon `sock:getreusedtimes() == 0` ise) bir kez `SET TIME ZONE 'UTC'` — F2 `pool.lua`'ya küçük ek.

### `api/src/models/audit.lua`

```lua
-- Audit log modeli ve hassas alan maskeleme.
local cjson = require("cjson.safe")
local _M = {}

-- 00-genel-bakis §8 (küçük harfe normalize edilmiş anahtarlar)
_M.SENSITIVE_KEYS = {
  password = true, password_hash = true, new_password = true, token = true,
  token_hash = true, refresh_token = true, access_token = true, secret = true,
}
_M.MASK = "***"

-- Derin kopya + maskeleme; girdi DEĞİŞTİRİLMEZ. Döngüsel referans koruması (seen set).
-- Derinlik sınırı 10 (aşırı iç içe payload'a karşı).
function _M.mask(value, _seen, _depth) end
--  tablo değilse aynen dön
--  her (k, v): type(k) == "string" and SENSITIVE_KEYS[k:lower()] → MASK
--             tablo → mask(v, seen, depth + 1)
--  dizi tablolar dizi olarak kalır (cjson.empty_array_mt korunur)

function _M.from_row(row) end    -- old_value/new_value JSONB → pgmoon zaten decode eder (json tipi)
function _M.serialize(a) end     -- id, user_id, user_email, action, entity_type, entity_id,
                                 -- old_value, new_value, ip_address, user_agent, status,
                                 -- error_message, created_at (ISO-8601)

return _M
```

Maskeleme **yazma anında** yapılır (audit_service, F8) → DB'de hassas veri hiç bulunmaz. `serialize` ikinci kez maskelemez (gereksiz).

`ip_address INET`: pgmoon string döner (`"172.18.0.1"` veya `"172.18.0.1/32"` değil — INET host adresi için maske eklemez). Doğrulama F8 integration testinde.

### `api/spec/security_spec.lua` (bu fazın kapsamı)

| describe | it |
|---|---|
| `random.uuid4` | format regex; 10 000 üretimde çakışma yok; versiyon nibble `4`, variant `8/9/a/b` |
| `random.token` | 64 hex karakter; iki çağrı farklı |
| `password.hash` | `$argon2id$v=19$m=4096,t=3,p=1$` öneki; aynı parola iki kez → farklı hash (salt) |
| `password.verify` | doğru → true; yanlış → false; bozuk encoded → false (hata atmaz) |
| `password.needs_rehash` | m=4096 hash + config m_cost=13 → true; eşit → false |
| `password.hash` sınırlar | boş / 1025 byte / nil → `nil, err` |
| `jwt.sign_access` + `verify("access")` | payload alanları eksiksiz (`sub, user_id, email, role, iat, exp, jti, typ, iss`) |
| `jwt.verify` typ | refresh token `verify(t, "access")` → `nil, "UNAUTHORIZED"` |
| `jwt.verify` süre | `ngx.time` stub ile exp geçmiş → `TOKEN_EXPIRED` |
| `jwt.verify` imza | son karakter değiştirilmiş token → `UNAUTHORIZED` |
| `jwt.verify` alg none | elle üretilmiş `alg: none` token → `UNAUTHORIZED` |
| `jwt.verify` farklı secret | → `UNAUTHORIZED` |
| `jwt.verify` iss | farklı issuer → `UNAUTHORIZED` |
| `audit.mask` | iç içe `{ user = { password_hash = "x" }, list = { { token = "t" } } }` → maskeli; orijinal değişmedi; `PASSWORD` (büyük harf) maskeli; döngüsel tablo sonsuz döngüye girmiyor |
| `user.serialize` | `password_hash` alanı yok; `full_name = nil` → `cjson.null` |

Çalıştırma: spec'ler `ngx` API'sine ihtiyaç duyduğu için `resty` altında busted: `resty -I api/src -I /app/lib $(which busted) api/spec/security_spec.lua` → Makefile'da `test.api` hedefi bu sarmalayıcıyı kullanır (F11'de genelleşir). `config.get()` testlerde `config.current = config.load(fake_getenv)` ile beslenir.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| `argon2` rock'u (lua-argon2) | Olgun C binding; "lua-resty-argon2" adında yaygın paket yok (00-genel-bakis #4). |
| `dummy_verify` | Olmayan kullanıcıda da ~aynı süre harcanır → e-posta numaralandırma zamanlama saldırısı engellenir. |
| `needs_rehash` | Parametre yükseltmesi toplu migration gerektirmez. |
| `jti` = UUID v4 | Denylist anahtarı; tahmin edilemez. |
| Maskeleme yazma anında, derin kopya | DB'ye hassas veri girmez; çağıranın tablosu bozulmaz. |
| `COLUMNS` sabitleri | `SELECT *` yok → şemaya kolon eklenince sızıntı olmaz. |
| UTC oturum timezone'u + ISO-8601 | İstemci tarafında tek format; frontend `Date` parse eder. |
| Auth middleware'de `is_active` DB kontrolü yok | Her istekte DB turu yerine 15 dk risk penceresi; refresh'te kontrol. |

## Kabul kriterleri (DoD)

- [ ] `api/spec/security_spec.lua` tüm senaryolarla yeşil.
- [ ] Güvenlik kodunda `math.random` yok (`grep -rn "math.random" api/src` boş).
- [ ] `SEED_DEFAULTS=true make db.seed` → 2 kullanıcı, hash öneki `$argon2id$v=19$m=4096,t=3,p=1$`.
- [ ] Seed edilen admin parolası `password.verify(hash, "Admin123!")` → true (resty tek satırlık kontrol).
- [ ] `jwt.verify` 6 negatif senaryoda (typ, exp, imza, alg none, secret, iss) reddediyor.
- [ ] `user.serialize` çıktısında `password_hash` yok (spec + grep kontrolü).
- [ ] `audit.mask` girdiyi değiştirmiyor ve döngüsel tabloda sonlanıyor.
- [ ] Hash süresi ölçüldü ve README'ye yazıldı (ör. `resty -e` ile 100 hash ortalaması).
- [ ] `luacheck api/src/security api/src/models` temiz.

## Doğrulama

```bash
make test.api ARGS=api/spec/security_spec.lua
SEED_DEFAULTS=true make db.seed
docker compose exec -T postgres psql -U todo todo -c "select email, substr(password_hash,1,32) from users"

# Parola doğrulama (konteyner içinde)
docker compose exec -T api resty -I /app/src -I /app/lib -e '
  local cfg = require("config"); cfg.current = cfg.load()
  local pg = require("db.pool"); pg.configure(cfg.current.db)
  local q = require("db.query")
  local row = q.query_one("select password_hash from users where email = $1", "admin@todoapp.local")
  print(require("security.password").verify(row.password_hash, "Admin123!"))'   # true

# Hash süresi
docker compose exec -T api resty -I /app/src -I /app/lib -e '
  local cfg = require("config"); cfg.current = cfg.load()
  local p = require("security.password"); ngx.update_time(); local t = ngx.now()
  for i = 1, 20 do p.hash("Admin123!") end
  ngx.update_time(); print(("%.1f ms/hash"):format((ngx.now() - t) * 1000 / 20))'

# JWT el ile inceleme
docker compose exec -T api resty -I /app/src -I /app/lib -e '
  local cfg = require("config"); cfg.current = cfg.load()
  local jwt = require("security.jwt")
  local t = jwt.sign_access({ id = "00000000-0000-4000-8000-000000000000", email = "a@b.c", role = "admin" })
  print(require("cjson").encode(jwt.verify(t, "access")))
  print(jwt.verify(t, "refresh"))'                                             # nil UNAUTHORIZED
```

## Riskler / Dikkat Noktaları

- **lua-argon2 API adları** (`hash_encoded`, `verify`, `variants.argon2_id`) sürüm 3.x'e göre; F4 başında rock kaynağından doğrulanmalı. Alpine'de `libargon2` / `argon2-dev` paket adı.
- **lua-resty-jwt bakım durumu**: `SkyLothar/lua-resty-jwt` uzun süredir güncellenmiyor; `cdbattags/lua-resty-jwt` fork'u aktif → rockspec'te `lua-resty-jwt` (cdbattags, 0.2.3+) pinlenir.
- **Worker bloklama**: yoğun login trafiğinde Argon2 tüm worker'ları meşgul edebilir → rate limit (F5) + yük testi (F11) ile ölçülür; gerekirse `m_cost` düşürülmez, worker sayısı artırılır.
- **`bit` kütüphanesi** yalnızca LuaJIT'te; `random.lua` backend'e özgü olduğundan sorun değil (shared'a taşınmamalı).
- **Timezone**: `SET TIME ZONE` bağlantı başına; havuzdan dönen bağlantıda korunur, yeni bağlantıda tekrar ayarlanır — `getreusedtimes` kontrolü atlanırsa her sorguda ekstra tur.

## Tahmini Efor

**M** — 1–1.5 gün.
