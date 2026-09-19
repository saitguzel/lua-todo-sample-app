# ═══ 00 — GENEL BAKIŞ VE ORTAK SÖZLEŞMELER ═══

> Bu doküman tüm faz dokümanlarının **tek doğruluk kaynağıdır** (single source of truth).
> Error kodları, ortam değişkenleri, audit olay adları, shared dict'ler, sayfa anahtarları
> ve katman kuralları burada tanımlanır; faz dokümanları bunlara referans verir, yeniden tanımlamaz.
> Bir faz dokümanı ile bu doküman çelişirse **bu doküman geçerlidir** ve faz dokümanı düzeltilir.

---

## 1. Ürün Özeti

İki katmanlı, rol tabanlı erişim kontrollü (RBAC), denetim kaydı (audit) tutan bir Todo uygulaması.

| Bileşen | Teknoloji | Çalıştığı yer | Sorumluluk |
|---|---|---|---|
| `todo-api` | OpenResty 1.25+ / LuaJIT / Lapis / pgmoon | Sunucu (Docker) | REST API, auth, RBAC, audit, zamanlanmış işler, Swagger |
| `todo-web` | Lua 5.4 (Wasmoon, WASM) + ince JS glue | Tarayıcı | SPA: kendi render motoru, reducer tabanlı state, hash router |
| `todo-shared` | Saf Lua (5.1 ∩ 5.4 alt kümesi) | Her ikisi | Tipler/enum'lar, validation, protokol (error kodları, HTTP map) |

Kullanıcı rolleri: `admin`, `todouser`.

---

## 2. Mimari Diyagram

```
            ┌───────────────────────────── Tarayıcı ──────────────────────────────┐
            │  index.html → glue.js → Wasmoon (Lua 5.4 VM, WASM)                    │
            │    main.lua → app.lua (store/reducer) → router.lua → views/*.lua      │
            │    dom.lua ←→ JS DOM     fetch.lua ←→ window.fetch (Promise→coroutine)│
            │    shared/{types,validation,protocol}.lua  (backend ile AYNI kod)     │
            └──────────────────────────────┬───────────────────────────────────────┘
                                           │ HTTPS · JSON · Authorization: Bearer <jwt>
            ┌──────────────────────────────▼───────────────────────────────────────┐
            │ OpenResty (nginx)                                                     │
            │  init_by_lua        → config.load() + assert                          │
            │  init_worker_by_lua → jobs.log_cleanup.start() (yalnızca worker 0)    │
            │  content_by_lua     → lapis.serve("app")                              │
            │                                                                       │
            │  Middleware zinciri:                                                  │
            │   cors → logger → audit_context → auth → authorization → handler      │
            │                                                                       │
            │  handlers/* → services/* → repositories/* → db/query → pgmoon         │
            │                   └→ audit_service.record(...)                        │
            │  lua_shared_dict: rbac_cache | jwt_denylist | rate_limit | job_locks  │
            └──────────────────────────────┬───────────────────────────────────────┘
                                           │ TCP 5432 (cosocket keepalive havuzu)
                                 ┌─────────▼─────────┐
                                 │ PostgreSQL 15+    │
                                 └───────────────────┘
```

---

## 3. İstek Yaşam Döngüsü (Backend)

Örnek: `PATCH /api/v1/todos/:id`

1. **nginx** isteği `location /api/` bloğuna düşürür → `content_by_lua_block { require("lapis").serve("app") }`.
2. **Lapis** route eşleşmesi yapar; route, `router.lua`'da `chain(middlewares, handler)` ile sarılmıştır.
3. **cors**: `OPTIONS` preflight'ı yanıtlar — `Origin` whitelist'teyse `204`, değilse `403`; zincir biter.
   Ortak CORS header'ları (`Access-Control-Allow-Origin`, `Vary: Origin`, `Access-Control-Expose-Headers`) zincirde
   değil, server seviyesindeki `header_filter_by_lua` fazında basılır → 404/405/413 gibi zincir dışı hatalar da
   tarayıcıda okunabilir.
4. **logger**: `ngx.ctx.req_id = random.uuid4()`, `ngx.ctx.started_at = ngx.now()`; response header `X-Request-Id`.
5. **audit_context**: `ngx.ctx.audit = { ip = ..., user_agent = ... }` (X-Forwarded-For yalnızca güvenilir proxy'den).
6. **auth**: `Authorization: Bearer` → `jwt.verify` → `typ == "access"` → denylist kontrolü → `ngx.ctx.identity = { user_id, email, role, jti, exp }`.
7. **authorization(`"todos.edit"`)**: `rbac_service.can(role, page_key)` (shared dict cache) → hayır ise `403` + `access.denied` audit.
8. **handler**: body parse + `validation.validate(schema, body)` → `todo_service.patch(identity, id, input)`.
9. **service**: iş kuralları, sahiplik, `query.with_transaction(fn)` içinde repo çağrıları, `audit_service.record(...)`.
10. **repository**: parametreli SQL (`$1, $2`) → `db/query.lua` → pgmoon.
11. **error_handler**: zincirin tamamı `xpcall` içinde; yakalanan hata → `protocol.http_status(code)` → JSON `{ error = { code, message, details, req_id } }`.
12. **logger (log fazı)**: `log_by_lua` içinde tek satır erişim logu (`req_id, method, path, status, duration_ms, user_id`).

---

## 4. Katman Kuralları (İhlal = Code Review Red)

| Katman | Yapabilir | Yapamaz |
|---|---|---|
| `handlers/` | `self.params`, body parse, validation, service çağrısı, HTTP response şekli | SQL yazmak, repo çağırmak |
| `services/` | İş kuralı, transaction sınırı, audit kaydı, birden fazla repo orkestrasyonu | HTTP status seçmek (sadece error code döner), Lapis `self` görmek |
| `repositories/` | Parametreli SQL, satır → model dönüşümü | İş kuralı, audit, HTTP |
| `models/` | Saf veri: `from_row`, `serialize` (public görünüm), maskeleme | I/O |
| `db/` | Bağlantı, havuz, transaction, migration | Tablo bilgisi |
| `security/` | Kripto primitifleri | DB, HTTP |
| `middleware/` | `ngx.ctx` yazmak, erken dönüş | İş kuralı |

**Service dönüş sözleşmesi** (idiomatic Lua, exception yerine çoklu dönüş):

```lua
-- Başarı
return result                 -- (result, nil)
-- Beklenen hata
return nil, errors.new(ERR.TODO_NOT_FOUND, "Todo bulunamadı", { id = id })
```

Handler'da:

```lua
local todo, err = todo_service.get(ngx.ctx.identity, self.params.id)
if not todo then return errors.respond(err) end
return { status = 200, json = { data = todo } }
```

Beklenmeyen hatalar (`error()`, programlama hataları) `error_handler`'daki `xpcall` ile yakalanır → `INTERNAL_ERROR` (500); stack trace yalnızca loga yazılır, istemciye asla.

---

## 5. Hata Modeli ve Error Kodları (Kanonik Liste)

Tüm hatalar şu JSON şekliyle döner:

```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Girdi doğrulanamadı",
    "details": { "title": ["zorunlu alan"], "priority": ["geçersiz değer: urgent"] },
    "req_id": "5b1d9c1e-7f7a-4c1b-9a8e-3f2d8e1c0a11"
  }
}
```

`shared/src/protocol.lua` içinde tanımlanır:

| Kod | HTTP | Kullanım |
|---|---|---|
| `VALIDATION_FAILED` | 422 | Şema doğrulama hatası; `details` = alan → mesaj listesi |
| `BAD_REQUEST` | 400 | JSON parse hatası, bozuk parametre |
| `UNAUTHORIZED` | 401 | Token yok / geçersiz imza |
| `TOKEN_EXPIRED` | 401 | Access token süresi dolmuş (frontend refresh tetikler) |
| `TOKEN_REVOKED` | 401 | Denylist'teki token |
| `INVALID_CREDENTIALS` | 401 | Login başarısız (email/parola ayrımı YAPILMAZ) |
| `ACCOUNT_DISABLED` | 403 | `is_active = false` |
| `FORBIDDEN` | 403 | RBAC reddi |
| `NOT_FOUND` | 404 | Genel / bilinmeyen route |
| `TODO_NOT_FOUND` | 404 | Todo yok **veya başkasına ait** (varlık sızıntısı önleme) |
| `USER_NOT_FOUND` | 404 | |
| `EMAIL_TAKEN` | 409 | Unique ihlali |
| `CONFLICT` | 409 | Genel çakışma (ör. admin'in `rbac.matrix` iznini kapatma) |
| `LAST_ADMIN` | 409 | Son aktif admin silinemez / düşürülemez / pasifleştirilemez |
| `SELF_ACTION_FORBIDDEN` | 409 | Admin kendini silemez / rolünü düşüremez |
| `RESET_TOKEN_INVALID` | 400 | Geçersiz / kullanılmış / süresi dolmuş reset token |
| `RATE_LIMITED` | 429 | `Retry-After` header ile |
| `PAYLOAD_TOO_LARGE` | 413 | Body > 1 MiB |
| `INTERNAL_ERROR` | 500 | Beklenmeyen hata |
| `MAIL_FAILED` | 502 | SMTP hatası (yalnızca loglanır; forgot-password yine 202 döner) |
| `DB_UNAVAILABLE` | 503 | Bağlantı kurulamadı |

**Yalnızca istemci tarafı kodlar:** `NETWORK_ERROR` (fetch reddedildi / ağ yok) ve `INVALID_RESPONSE` (JSON parse
edilemedi / beklenmeyen şekil) — `web/src/fetch.lua` üretir; sunucu bunları asla döndürmez, `protocol.lua`'ya
**eklenmez**.

---

## 6. Ortam Değişkenleri (Kanonik Liste)

`api/src/config.lua` bu listeyi okur; `.env.example` bu listeyle **birebir** aynıdır.

| Değişken | Varsayılan | Tip | Doğrulama / Not |
|---|---|---|---|
| `APP_ENV` | `development` | enum | `development\|test\|production` |
| `APP_PORT` | `8080` | int | 1–65535 — **konteyner içi** nginx `listen` portu; host portu değil (§6.1) |
| `APP_BASE_URL` | `http://localhost:28080` | url | Swagger `servers`; IP/domain ile erişimde o adres (§6.2) |
| `WEB_BASE_URL` | `http://localhost:28000` | url | Reset e-posta linkinin frontend adresi; IP/domain ile erişimde o adres (§6.2) |
| `DB_HOST` | `postgres` | string | zorunlu |
| `DB_PORT` | `5432` | int | |
| `DB_NAME` | `todo` | string | zorunlu |
| `DB_USER` | `todo` | string | zorunlu |
| `DB_PASSWORD` | — | string | **zorunlu**; prod'da ≥ 16 karakter |
| `DB_SSL` | `false` | bool | prod'da `true` önerilir |
| `DB_POOL_SIZE` | `20` | int | 1–200 (worker başına keepalive) |
| `DB_POOL_IDLE_TIMEOUT_MS` | `60000` | int | |
| `DB_CONNECT_TIMEOUT_MS` | `3000` | int | |
| `DB_QUERY_TIMEOUT_MS` | `10000` | int | |
| `JWT_SECRET` | — | string | **zorunlu**, ≥ 32 byte; prod'da `.env.example` değeri reddedilir |
| `JWT_ISSUER` | `todo-api` | string | |
| `JWT_ACCESS_TTL` | `900` | int (sn) | 15 dk |
| `JWT_REFRESH_TTL` | `604800` | int (sn) | 7 gün |
| `ARGON2_T_COST` | `3` | int | ≥ 1 |
| `ARGON2_M_COST` | `12` | int (log2 KiB) | 10–20 |
| `ARGON2_PARALLELISM` | `1` | int | ≥ 1 |
| `PASSWORD_RESET_TTL` | `3600` | int (sn) | 1 saat |
| `LOGIN_RATE_LIMIT` | `5` | int | IP+email başına dakikada deneme |
| `SMTP_HOST` | `mailhog` | string | |
| `SMTP_PORT` | `1025` | int | |
| `SMTP_USER` | (boş) | string | |
| `SMTP_PASSWORD` | (boş) | string | |
| `SMTP_FROM` | `no-reply@todoapp.local` | email | |
| `SMTP_TLS` | `false` | bool | STARTTLS |
| `CORS_ORIGINS` | `http://localhost:28000,http://127.0.0.1:28000` | csv | prod'da `*` reddedilir |
| `TRUSTED_PROXIES` | `127.0.0.1` | csv | X-Forwarded-For güveni |
| `LOG_FORMAT` | `json` | enum | `json\|text` |
| `LOG_LEVEL` | `info` | enum | `debug\|info\|warn\|error` |
| `AUDIT_LOG_RETENTION_DAYS` | `30` | int | ≥ 1 |
| `AUDIT_CLEANUP_ENABLED` | `true` | bool | |
| `AUDIT_CLEANUP_HOUR` | `3` | int | 0–23 (UTC) |
| `AUDIT_CLEANUP_BATCH_SIZE` | `1000` | int | 100–10000 |
| `SEED_DEFAULTS` | `false` | bool | prod'da `true` ise uyarı logu |
| `RBAC_CACHE_TTL` | `60` | int (sn) | |

**`_FILE` konvansiyonu (Docker secrets):** Gizli değerler için `X_FILE` varyantı desteklenir — `DB_PASSWORD_FILE`,
`JWT_SECRET_FILE`, `SMTP_PASSWORD_FILE`. Tanımlıysa `config.lua` değeri dosyadan okur (sondaki `\n`/`\r\n` kırpılır)
ve düz `X` değişkenini yok sayar; ikisi birden tanımlıysa uyarı loglanır. Dosya okunamazsa başlangıç reddedilir (F3, F18).

### 6.1 Host Port Eşlemeleri (yalnızca docker-compose)

Bu değişkenleri `config.lua` **okumaz**; yalnızca `docker-compose.yml` `ports:` satırlarında kullanılır. Geliştirme
makinesinde yaygın olarak dolu olan portlarla (80, 443, 3000, 5173, 8000, 8080, 9000, 5432) çakışmamak için tüm host
portları **28xxx bloğundan** seçildi (Linux geçici port aralığı 32768–60999'un dışında). `make up` önce
`make ports.check` (F0) çalıştırır; dolu port varsa hangi konteynerin tuttuğunu yazar ve durur.

| Değişken | Varsayılan | Tip | Doğrulama / Not |
|---|---|---|---|
| `API_HOST_PORT` | `28080` | int | → api konteyneri `8080`; `APP_BASE_URL` ile tutarlı olmalı |
| `WEB_HOST_PORT` | `28000` | int | → web konteyneri `80`; `WEB_BASE_URL` ile tutarlı olmalı; `/api/` bu port üzerinden api'ye proxy'lenir (§6.2) |
| `DB_HOST_PORT` | `25432` | int | → postgres `5432`; yalnızca `127.0.0.1`'e bağlanır |
| `MAILHOG_UI_HOST_PORT` | `28025` | int | → mailhog UI `8025`; yalnızca `127.0.0.1`'e bağlanır; SMTP `1025` host'a açılmaz |

| Konteyner içi (sabit, değişmez) | Port |
|---|---|
| api (OpenResty `listen`) | `8080` (`APP_PORT`) |
| web (nginx) | `80` |
| postgres | `5432` (`DB_PORT`) |
| mailhog | `1025` SMTP (`SMTP_PORT`), `8025` UI |

Prod (F18): yalnızca `proxy` servisi host'a açılır: `${HTTP_PORT:-80}` / `${HTTPS_PORT:-443}`. Prod compose'u bu geliştirme
makinesinde denemek için `HTTP_PORT=28088 HTTPS_PORT=28443` kullanılır (80/443 burada başka bir reverse proxy'de dolu).
`HTTP_PORT`/`HTTPS_PORT` yalnızca `docker-compose.prod.yml` ve `.env.prod` içindedir.


### 6.2 Erişim Adresi (localhost / IP / domain) — Aynı Origin

Frontend API'ye **her zaman sayfanın açıldığı origin'den** gider: `apiBase = ${location.origin}/api/v1`
(`web/static/boot.js`). Böylece uygulama `localhost`, sunucu IP'si veya domain ile açılsa da ek ayar gerekmez ve
tarayıcı açısından istek aynı origin'dir → CORS/preflight devreye girmez, CSP `connect-src 'self'` yeterlidir.

| Ortam | `/api/` isteğini api'ye kim aktarır | Not |
|---|---|---|
| Dev | web konteyneri nginx'i — `deploy/web/dev.conf` (`proxy_pass http://api:8080`) | `docker-compose.yml` bu dosyayı web'e mount eder |
| Prod | `proxy` servisi — `deploy/proxy/nginx.conf` | web imajı yalnızca statik dosya sunar |

- `API_HOST_PORT` (28080) doğrudan erişim yalnızca curl, entegrasyon testleri ve bench içindir. Başka bir origin'deki
  tarayıcı istemcisi bu porta giderse `CORS_ORIGINS` gerekir.
- **Gerçek istemci IP'si:** dev ağında web konteyneri sabit IP alır (`172.31.250.10`, alt ağ `172.31.250.0/24`);
  compose api servisine `TRUSTED_PROXIES=127.0.0.1,172.31.250.10` verir (`.env`'deki değeri ezer). Audit ve login rate
  limit'i `X-Forwarded-For` üzerinden gerçek istemci IP'sini görür (F8). Prod'da aynı rolü sabit proxy IP'si üstlenir (F18).
- **IP ile erişim:** `.env` içinde `APP_BASE_URL` ve `WEB_BASE_URL` → `http://<sunucu-ip>:28000` yapılır (reset e-postası
  linki ve Swagger `servers` bu adresi gösterir); `.env.example` localhost değerleriyle kalır.
- **Güvenlik:** dev yığını (demo hesaplar login ekranında görünür, HTTP, `SEED_DEFAULTS=true`) herkese açık bir IP'de
  güvenlik duvarı/IP kısıtı olmadan açılmaz. Dış erişim gerekiyorsa prod yığını (HTTPS, demo hesap yok) kullanılır.
---

## 7. Sayfa Anahtarları ve Varsayılan RBAC Matrisi

`shared/src/types.lua` → `PAGES`:

| page_key | admin | todouser | Korunan endpoint'ler |
|---|---|---|---|
| `dashboard` | ✅ | ✅ | `GET /todos/stats` |
| `todos.list` | ✅ | ✅ | `GET /todos`, `GET /todos/:id` |
| `todos.create` | ✅ | ✅ | `POST /todos` |
| `todos.edit` | ✅ | ✅ | `PUT/PATCH/DELETE /todos/:id` |
| `users.list` | ✅ | ❌ | `GET /users`, `GET /users/:id` |
| `users.create` | ✅ | ❌ | `POST /users`, `PUT /users/:id`, `DELETE /users/:id` |
| `rbac.matrix` | ✅ | ❌ | `/rbac/*` |
| `audit.logs` | ✅ | ❌ | `/audit/*` |
| `settings` | ✅ | ❌ | (yalnızca frontend ayar sayfası) |

**Kilit kuralı:** `admin` rolünün `rbac.matrix` izni **değiştirilemez** (kendini kilitleme önlemi). `PUT/PATCH /rbac/matrix` bu hücreyi `false` yapmaya çalışırsa `CONFLICT` döner.

**Veri kapsamı** (RBAC'tan bağımsız, service katmanında): `todouser` yalnızca `user_id = identity.user_id` olan todo'ları görür/değiştirir; `admin` hepsini.

**Auth endpoint'leri** (`/auth/*`) ve `/auth/me` RBAC dışındadır; `/auth/me` yalnızca `auth` middleware ister. `/api/v1/health` (liveness), `/api/v1/health/ready` (readiness, F18), `/api/v1/swagger`, `/api/v1/swagger.json` tamamen açıktır (tüm route'lar `API_PREFIX = /api/v1` altında).

---

## 8. Audit Olayları (Kanonik Liste)

| action | entity_type | Tetikleyen | old_value | new_value |
|---|---|---|---|---|
| `auth.login.success` | `user` | auth_service.login | — | `{ email }` |
| `auth.login.failure` | `user` | auth_service.login | — | `{ email, reason }` — reason: `invalid_credentials\|disabled\|rate_limited` |
| `auth.logout` | `user` | auth_service.logout | — | — |
| `auth.token.refresh` | `user` | auth_service.refresh | — | — |
| `auth.password.reset.request` | `user` | auth_service.forgot_password | — | `{ email }` |
| `auth.password.reset.success` | `user` | auth_service.reset_password | — | — |
| `todo.create` | `todo` | todo_service.create | — | todo |
| `todo.update` | `todo` | todo_service.update / patch | önceki todo | yeni todo |
| `todo.delete` | `todo` | todo_service.delete | silinen todo | — |
| `user.create` | `user` | user_service.create | — | user (maskeli) |
| `user.update` | `user` | user_service.update | önceki (maskeli) | yeni (maskeli) |
| `user.delete` | `user` | user_service.delete | silinen (maskeli) | — |
| `rbac.matrix.update` | `rbac` | rbac_service.update_matrix / set_cell | değişen hücreler (eski) | değişen hücreler (yeni) |
| `access.denied` | `page` | authorization middleware | — | `{ page_key, method, path }` |

`auth.token.refresh` prompt'ta yok; oturum izlenebilirliği için eklendi.
Başarısız işlemler de kaydedilir: `status = 'failure'`, `error_message` doldurulur (ör. `auth.login.failure`).

**Maskelenen alanlar** (recursive, büyük/küçük harf duyarsız): `password`, `password_hash`, `new_password`, `token`, `token_hash`, `refresh_token`, `access_token`, `secret` → `"***"`.

---

## 9. lua_shared_dict Haritası

| Dict | Boyut | Anahtar şeması | TTL | Kullanan |
|---|---|---|---|---|
| `rbac_cache` | 1m | `rbac:<role>` → JSON `{ [page_key] = bool }` | `RBAC_CACHE_TTL` | rbac_service |
| `jwt_denylist` | 10m | `jti:<jti>` → `1` | token'ın kalan ömrü | auth middleware, auth_service |
| `rate_limit` | 10m | `login:<ip>:<email_lower>` → sayaç | 60 sn | auth_service.login |
| `job_locks` | 1m | `lock:log_cleanup`, `last_run:log_cleanup` | 3600 sn / 86400 sn | jobs/log_cleanup |
| `metrics` | 1m | `req_total`, `req:2xx`, `req:4xx`, `req:5xx`, `latency_sum_ms` | — | logger, `/metrics` (F18) |

## 10. ngx.ctx Haritası (Request-Scoped, "arena")

| Anahtar | Yazan | Okuyan |
|---|---|---|
| `req_id` | logger | error_handler, audit_service, log fazı |
| `started_at` | logger | log fazı |
| `audit` = `{ ip, user_agent }` | audit_context | audit_service |
| `identity` = `{ user_id, email, role, jti, exp }` | auth | authorization, handler, service, audit_service |
| `tx_conn` (açık transaction bağlantısı) | db/query `with_transaction` | db/query |

İstek bitince ngx.ctx otomatik atılır → request-scoped bellek "arena" gibi davranır; hiçbir modül-seviyesi tabloya request verisi yazılmaz.

---

## 11. Teknik Düzeltmeler (Prompt'taki Sorunlar ve Karar)

Orijinal prompt'taki teknik olarak hatalı veya eksik noktalar. Faz planları düzeltilmiş hali uygular.

| # | Prompt'ta | Sorun | Karar |
|---|---|---|---|
| 1 | "Lua → WASM (Wasmoon)", "Emscripten" | Wasmoon, Lua 5.4 VM'ini **hazır derlenmiş** WASM olarak getirir; Lua kodu WASM'a derlenmez, VM içinde yorumlanır. | Emscripten kullanılmaz. `public/app.wasm` = Wasmoon paketindeki `glue.wasm`'ın kopyası. `build-wasm.sh` Lua kaynaklarını tek `bundle.json` manifestine paketler. |
| 2 | Shared kütüphane ortak | Backend LuaJIT (Lua 5.1 semantiği), frontend Lua 5.4. | Shared kod **ortak alt kümede**: `//`, `goto`, `<const>`, `<close>`, `utf8.*`, bit operatörleri, `math.type` YOK. `local unpack = table.unpack or unpack`. CI iki yorumlayıcıda da spec koşturur. |
| 3 | `lua-resty-http (SMTP)` | lua-resty-http SMTP konuşmaz. | `lua-resty-mail` (cosocket tabanlı SMTP; STARTTLS + AUTH). |
| 4 | `lua-resty-argon2` | Bu adla yaygın paket yok; yaygın olan LuaRocks `argon2` (thibaultcha/lua-argon2, C binding). Hash CPU-bloklayıcıdır (worker'ı ~10–50 ms kilitler). | `argon2` rock'u + login rate limit. `m_cost=12` (4 MiB) OWASP minimumunun (19 MiB ≈ `m_cost=15`) altında: prompt değeri default kalır, env ile artırılabilir, README'de önerilir. |
| 5 | "Connection pool (min 5, max 20)" | OpenResty'de havuz cosocket keepalive'dır ve **worker başına**dır; "min" kavramı yok, bağlantılar talep üzerine açılır. | `pg:keepalive(DB_POOL_IDLE_TIMEOUT_MS, DB_POOL_SIZE)`. Toplam üst sınır = `worker_processes × DB_POOL_SIZE` → Postgres `max_connections` buna göre. İsteğe bağlı "ısıtma": `init_worker`'da 5 bağlantı açıp havuza bırakma (min 5 karşılığı). |
| 6 | "Prepared statement KULLAN" | Lapis `db.query` değerleri client-side escape eder; gerçek bind parametresi değildir. | DB erişimi `db/query.lua` üzerinden pgmoon **extended query protocol**'ü ile: `pg:query("SELECT ... WHERE id = $1", id)` (pgmoon ≥ 1.16). Lapis **yalnızca routing** için; migration'lar kendi runner'ımızla (`db/migrations.lua`: pgmoon + `schema_migrations` + advisory lock, F2) koşar. |
| 7 | Zincir: `cors → logger → auth → authorization → audit` | `authorization` reddi `access.denied` audit'i yazar; o anda IP/UA hazır olmalı. | `cors → logger → audit_context → auth → authorization → handler`. |
| 8 | `PATCH /rbac/matrix/:role/:page-key` | Lapis param adında `-` sorunlu. | `/rbac/matrix/:role/:page_key`. |
| 9 | JWT payload `{ user_id, email, role, exp, iat }` | `jti` olmadan logout/refresh iptali yapılamaz; `typ` olmadan refresh token access yerine kullanılabilir. | `{ sub, user_id, email, role, iat, exp, jti, typ = "access"\|"refresh", iss }`. |
| 10 | `swagger-cli validate` | swagger-cli deprecated; OpenAPI 3.1 desteği yok. | `npx @redocly/cli lint`. |
| 11 | "WASM optimizasyonu (-O3, ReleaseSmall)" | `ReleaseSmall` Zig terimi; WASM'ı kendimiz derlemiyoruz. | Lua kaynak minify + gzip/brotli, `<link rel="preload">` ile wasm, view'ların lazy `require`'ı, `WebAssembly.compileStreaming`. |
| 12 | Tailwind CDN | Play CDN production için önerilmez (runtime JIT, ~300 KB). | Dev: CDN. Prod (F18): Tailwind CLI ile derlenmiş `tailwind.css`. |
| 13 | `ngx.timer.at` her saat | `init_worker` her worker'da çalışır → job N kez tetiklenir. | Yalnızca `ngx.worker.id() == 0` + `pg_try_advisory_lock` (çok instance için). |
| 14 | `/todos/stats` + `/todos/:id` | Route çakışması. | `/todos/stats` önce tanımlanır; `:id` UUID regex ile doğrulanır. |
| 15 | `gen_random_uuid()` | PG 13+ çekirdekte; öncesinde `pgcrypto`. | Migration 001'de `CREATE EXTENSION IF NOT EXISTS pgcrypto;`. |
| 16 | `ngx.thread.spawn` "concurrent" | Handler'larda gerçek bir paralel ihtiyaç yok. | Tek kullanım yeri: `GET /todos/stats` ve `GET /audit/stats` — bağımsız aggregate sorgularını paralel koşturmak. Her thread kendi bağlantısını alır. |

---

## 12. Faz Bağımlılık Grafiği

```
F0 ─► F1 ─► F2 ─► F3 ─► F4 ─► F5 ─► F6 ─► F7 ─► F8 ─► F9 ─► F10 ─► F11 ──┐
                                 │                                         ├─► F18
                                 └─► F12 ─► F13 ─► F14 ─► F15 ─► F16 ─► F17 ┘
```

- F12 (frontend iskelet) F5'ten (auth API) sonra paralel başlayabilir.
- F9 (Swagger): her yeni endpoint eklendiğinde spec güncellenir; F9 spec'in tamamlanıp lint'ten geçtiği kapıdır.
- F5–F7'deki servisler `audit_service.record`'u (F5 minimal sürüm) zaten çağırır; F8 repo/handler/export/entegrasyon doğrulamasını tamamlar.

## 13. Faz Özet Tablosu

| Faz | Ad | Doküman | Efor |
|---|---|---|---|
| 0 | Monorepo + Altyapı | [faz-00](faz-00-monorepo-altyapi.md) | S |
| 1 | Shared Kütüphane | [faz-01](faz-01-shared-kutuphane.md) | M |
| 2 | Veritabanı + Migration | [faz-02](faz-02-veritabani-migration.md) | M |
| 3 | Backend Core | [faz-03](faz-03-backend-core.md) | L |
| 4 | Security | [faz-04](faz-04-security.md) | M |
| 5 | Auth Endpoint'leri | [faz-05](faz-05-auth-endpointleri.md) | L |
| 6 | Todos CRUD + Stats | [faz-06](faz-06-todos-crud-stats.md) | M |
| 7 | Users + RBAC | [faz-07](faz-07-users-rbac.md) | L |
| 8 | Audit Log + Middleware | [faz-08](faz-08-audit-log-middleware.md) | M |
| 9 | Swagger / OpenAPI 3.1 | [faz-09](faz-09-swagger-openapi.md) | M |
| 10 | Scheduled Jobs | [faz-10](faz-10-scheduled-jobs.md) | S |
| 11 | Backend Test + Load Test | [faz-11](faz-11-backend-test-load-test.md) | L |
| 12 | Frontend İskelet | [faz-12](faz-12-frontend-iskelet.md) | M |
| 13 | Frontend Core | [faz-13](faz-13-frontend-core.md) | L |
| 14 | Frontend Views (Auth + Todos) | [faz-14](faz-14-frontend-views-auth-todos.md) | L |
| 15 | Frontend Views (Admin) | [faz-15](faz-15-frontend-views-admin.md) | M |
| 16 | Frontend UX Polish | [faz-16](faz-16-frontend-ux-polish.md) | M |
| 17 | Frontend Test + WASM Opt | [faz-17](faz-17-frontend-test-wasm-opt.md) | M |
| 18 | Deployment + Dokümantasyon | [faz-18](faz-18-deployment-dokumantasyon.md) | L |

Efor: S ≈ 0.5–1 gün, M ≈ 1–2 gün, L ≈ 2–4 gün (tek geliştirici).

## 14. Kod Konvansiyonları

- Tüm kod yorumları **Türkçe**; tanımlayıcılar İngilizce `snake_case`.
- Her modül `local _M = {}` … `return _M`; global yok (`luacheck`, `std = "ngx_lua"`).
- Sık kullanılan fonksiyonlar modül başında local'e alınır (`local ngx_now = ngx.now`) — LuaJIT JIT dostu.
- Sıcak path'lerde geçici tablolar `table.new(narr, nrec)` ile ön-boyutlanır, `table.clear` ile yeniden kullanılır — yalnızca ölçülmüş darboğazlarda (CSV export satır tamponu, log satırı tablosu).
- Döngüde string birleştirme `..` değil, tablo + `table.concat`.
- Hata: beklenen → `return nil, err`; beklenmeyen → `error(err_tbl, 0)` (yalnızca altyapı katmanında).
- Her dosyanın başında 2–4 satırlık Türkçe modül açıklaması.
- Satır uzunluğu 120; girinti 2 boşluk; `.editorconfig` F0'da.
- `collectgarbage("collect")` yalnızca iki yerde: CSV export sonu ve log_cleanup job sonu.

## 15. API Yanıt Zarfı

| Durum | Şekil |
|---|---|
| Tekil | `{ "data": { ... } }` |
| Liste | `{ "data": [ ... ], "meta": { "page": 1, "per_page": 20, "total": 134, "total_pages": 7 } }` |
| Boş başarı | `204 No Content` |
| Hata | `{ "error": { code, message, details, req_id } }` |

Sayfalama parametreleri: `page` (≥1, default 1), `per_page` (1–100, default 20). Sıralama: `sort=field` / `sort=-field`, alan whitelist'i endpoint bazında.

## 16. Sözlük

| Terim | Anlam |
|---|---|
| Identity | `ngx.ctx.identity`; doğrulanmış JWT'den çıkan kullanıcı bilgisi |
| Page key | RBAC'ta korunan UI sayfası / yetki anahtarı (`todos.edit`) |
| Denylist | İptal edilmiş JWT `jti` kümesi (shared dict) |
| Reducer | `(state, action) → new_state` saf fonksiyonu (frontend) |
| Optimistic UI | Sunucu yanıtı beklenmeden state'i güncelleme, hata olursa geri alma |
| Keepalive pool | OpenResty cosocket bağlantı yeniden kullanım havuzu |
| DoD | Definition of Done — fazın kabul kriterleri |
