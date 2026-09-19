# ═══ FAZ 3 — BACKEND CORE ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — istek yaşam döngüsü (§3), katman kuralları (§4), error modeli (§5), env (§6), shared dict'ler (§9), ngx.ctx (§10), yanıt zarfı (§15), teknik düzeltmeler #5, #6, #7, #14.

## Amaç

Tüm endpoint'lerin üzerine oturacağı çekirdeği kurmak: env tabanlı doğrulanmış konfigürasyon, gerçek `nginx.conf`, Lapis uygulama iskeleti, middleware zinciri mekanizması, parametreli sorgu + transaction katmanı, merkezi hata yönetimi, CORS, yapılandırılmış loglama ve `GET /api/v1/health`. Bu fazın sonunda API konteyneri gerçek config ile başlar, yanlış config'te **başlamayı reddeder**, `/health` DB'ye ping atar ve her yanıt `X-Request-Id` taşır.

## Önkoşullar

- FAZ 0 (docker-compose, Makefile).
- FAZ 1 (`todo_shared.protocol`).
- FAZ 2 (`db/pool.lua`, şema).
- `security/random.lua` F4'te yazılır; logger'ın `req_id` için ihtiyacı olan `uuid4()` bu fazda **F4'teki API ile birebir** olarak yazılır (F4 aynı dosyayı genişletir; bkz. F4 "random.lua"). Böylece faz sırası bozulmaz.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/config.lua` | Env okuma, default, tip dönüşümü, doğrulama, immutable config |
| `api/conf/nginx.conf` | Ana nginx konfigürasyonu (worker, shared dict'ler, include) |
| `api/conf/lua.conf` | `lua_package_path`, `init_by_lua`, `init_worker_by_lua`, server/location blokları |
| `api/conf/mime.types` | Standart nginx mime tablosu (OpenResty dağıtımından kopya) |
| `api/src/app.lua` | Lapis `Application`, route kayıtları `router.lua`'dan, `handle_404`, `handle_error` |
| `api/src/router.lua` | Route tablosu + `chain()` middleware birleştirici |
| `api/src/db/query.lua` | `query`, `query_one`, `exec`, `with_transaction`, pg hata → AppError |
| `api/src/middleware/error_handler.lua` | `errors.new`, `errors.respond`, `xpcall` sarmalayıcı |
| `api/src/middleware/cors.lua` | Origin whitelist, preflight |
| `api/src/middleware/logger.lua` | `req_id`, erişim logu (json/text), log seviyesi, metrics sayaçları |
| `api/src/security/random.lua` | (minimal) `uuid4()`, `hex(n)` — F4'te testleriyle tamamlanır |
| `api/conf/env.conf` | `make conf.env` ile `config.lua` SPEC'inden üretilen `env NAME;` satırları (commit edilir) |
| `Makefile` | `api.dev`, `api.reload`, `conf.env` hedefleri |

Not: `/health` için ayrı handler dosyası yoktur (prompt ağacında yok); `router.lua` içinde yerel fonksiyondur.

## Dosya Bazlı Tasarım

### `api/src/config.lua`

```lua
-- Uygulama konfigürasyonu: env'den okunur, default uygulanır, doğrulanır.
-- init_by_lua aşamasında bir kez yüklenir; hata varsa nginx başlamaz.
local _M = {}

-- Şema: ad → { type, default, required, validate, secret }
local SPEC = {
  APP_ENV   = { type = "enum", values = { "development", "test", "production" }, default = "development" },
  APP_PORT  = { type = "int", default = 8080, min = 1, max = 65535 },
  DB_PASSWORD = { type = "string", required = true, secret = true },
  JWT_SECRET  = { type = "string", required = true, secret = true, min_len = 32 },
  CORS_ORIGINS = { type = "csv", default = "http://localhost:28000,http://127.0.0.1:28000" },
  -- ... 00-genel-bakis §6'daki tüm değişkenler
}

local function coerce(name, spec, raw) ... end   -- → value | nil, "APP_PORT: tamsayı olmalı"

-- Ortama özgü ek kurallar
local function cross_validate(c) ... end
--  production: JWT_SECRET .env.example değeri olamaz; CORS_ORIGINS '*' içeremez;
--              DB_PASSWORD >= 16; LOG_LEVEL debug ise uyarı
--  SEED_DEFAULTS=true + production → uyarı (hata değil)

-- Tüm hataları toplayıp tek seferde fırlatır (ilk hatada durmaz)
function _M.load(getenv)   -- getenv: test için enjekte edilebilir, default os.getenv
  ...
  if #errors > 0 then error("Konfigürasyon hatası:\n  " .. table.concat(errors, "\n  "), 0) end
  return setmetatable({}, { __index = values, __newindex = function() error("config salt okunur") end })
end

-- X_FILE konvansiyonu (00 §6): DB_PASSWORD_FILE / JWT_SECRET_FILE / SMTP_PASSWORD_FILE tanımlıysa
-- değer dosyadan okunur, sondaki \r?\n kırpılır; dosya okunamazsa toplanan hatalara eklenir.
local function read_env(getenv, name) ... end   -- → raw | nil, err

-- Loglamak için: secret alanlar "***"
function _M.redacted(c) ... end

-- Modül seviyesinde tekil örnek (init_by_lua'da doldurulur)
function _M.get() return _M.current end

return _M
```

**nginx ve env:** nginx varsayılan olarak env değişkenlerini worker'lara **geçirmez**. `nginx.conf`'ta her değişken için `env NAME;` satırı gerekir. Bu liste §6 ile senkron tutulmalı → `config.lua`'daki `SPEC` anahtarlarından üretilir: `make conf.env` hedefi `resty -e` ile `env X;` satırlarını `api/conf/env.conf` dosyasına yazar, `nginx.conf` bunu `include` eder. Karar: üretilmiş dosya **commit edilir** (build adımı olmadan çalışsın), CI'da `make conf.env && git diff --exit-code` ile senkron kontrol edilir.

**Anahtar dönüşümleri** (config tablosunda kullanılan adlar, `snake_case` gruplu):

```lua
config.db = { host, port, database, user, password, ssl, pool_size, idle_timeout_ms, connect_timeout_ms, query_timeout_ms }
config.jwt = { secret, issuer, access_ttl, refresh_ttl }
config.argon2 = { t_cost, m_cost, parallelism }
config.smtp = { host, port, user, password, from, tls }
config.cors_origins = { ["http://localhost:28000"] = true }   -- set
config.trusted_proxies = { "127.0.0.1" }
config.audit = { retention_days, cleanup_enabled, cleanup_hour, cleanup_batch_size }
config.log = { format, level }
config.app = { env, port, base_url, web_base_url }
config.password_reset_ttl, config.login_rate_limit, config.seed_defaults, config.rbac_cache_ttl
```

### `api/conf/nginx.conf`

```nginx
# OpenResty ana konfigürasyonu
worker_processes auto;
error_log stderr info;              # LOG_LEVEL uygulama tarafında filtrelenir
pid logs/nginx.pid;

include env.conf;                   # env APP_ENV; env DB_HOST; ... (üretilmiş)

events { worker_connections 4096; }

http {
  include       mime.types;
  default_type  application/octet-stream;
  server_tokens off;
  access_log    off;                # erişim logu logger.lua (log_by_lua) yazar
  client_max_body_size 1m;          # PAYLOAD_TOO_LARGE sınırı
  client_body_buffer_size 1m;       # body'yi belleğe al (ngx.req.get_body_data nil dönmesin)
  keepalive_timeout 65;
  resolver 127.0.0.11 ipv6=off valid=30s;   # docker DNS (postgres, mailhog adları)

  lua_shared_dict rbac_cache   1m;
  lua_shared_dict jwt_denylist 10m;
  lua_shared_dict rate_limit   10m;
  lua_shared_dict job_locks    1m;
  lua_shared_dict metrics      1m;

  lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
  lua_ssl_verify_depth 3;

  include lua.conf;
}
```

### `api/conf/lua.conf`

```nginx
lua_package_path "/app/src/?.lua;/app/src/?/init.lua;/app/lib/?.lua;;";
lua_code_cache on;                  # dev'de de açık; değişiklik sonrası make api.reload
lua_socket_log_errors off;          # pgmoon keepalive gürültüsü

init_by_lua_block {
  -- Konfigürasyon + modül önyükleme (fork öncesi, copy-on-write paylaşımı)
  local config = require("config")
  config.current = config.load()
  require("db.pool").configure(config.current.db)
  require("cjson.safe").encode_empty_table_as_object(false)
  require("app")                    -- route tablosu master'da derlenir
}

init_worker_by_lua_block {
  require("db.pool").warm(5)        -- ngx.timer.at(0) içinde; "min 5" karşılığı
  -- F10: require("jobs.log_cleanup").start()
}

server {
  listen 8080;

  location = /api/v1/swagger { ... }   # F9
  location /api/ {
    default_type application/json;
    content_by_lua_block { require("lapis").serve("app") }
    log_by_lua_block     { require("middleware.logger").log_phase() }
  }
  location / { return 404; }
}
```

Dev çalışma şekli: nginx direktifleri runtime'da env okuyamadığından `lua_code_cache` için ayrı dev/prod conf tutulmaz; `lua_code_cache on` sabittir ve kod değişikliğinden sonra `make api.reload` (`openresty -s reload`, < 100 ms) çalıştırılır. (F0'daki "hot reload" ifadesi bu anlamdadır.)

### `api/src/app.lua`

```lua
-- Lapis uygulama giriş noktası: route'ları router.lua'dan kaydeder.
local lapis = require("lapis")
local router = require("router")
local errors = require("middleware.error_handler")

local app = lapis.Application()
app.layout = false                  -- HTML layout yok, saf JSON API

router.register(app)

-- Eşleşmeyen route → NOT_FOUND (JSON)
app.handle_404 = function(self) return errors.respond(errors.new("NOT_FOUND", "Kaynak bulunamadı")) end

-- Lapis'in kendi hata sayfası yerine JSON 500 (xpcall dışında kalan son savunma hattı)
app.handle_error = function(self, err, trace) return errors.on_unhandled(err, trace) end

return app
```

### `api/src/router.lua`

Route kayıt tablosu **tek yerde** — hem Lapis kaydı hem Swagger (F9) hem RBAC denetimi buradan beslenir.

```lua
-- Route tablosu ve middleware zinciri birleştirici.
-- Zincir: cors → logger → audit_context → auth → authorization → handler (00-genel-bakis #7)
local _M = {}

-- chain({mw1, mw2, ...}, handler) → function(self)
-- Her middleware: function(self) → nil (devam) | response tablosu (kısa devre)
function _M.chain(middlewares, handler)
  local n = #middlewares
  return function(self)
    return errors.guard(function()          -- xpcall + INTERNAL_ERROR
      for i = 1, n do
        local res = middlewares[i](self)
        if res then return res end
      end
      return handler(self)
    end)
  end
end

-- Route tanımı: { method, path, handler, auth = bool, page = "todos.edit" | nil, name }
_M.ROUTES = {
  { "GET", "/health", health, auth = false },   -- API_PREFIX ile → /api/v1/health (yerel fonksiyon)
  -- F5: auth, F6: todos, F7: users/rbac, F8: audit, F9: swagger
}

-- Kayıtlı route'ların düz listesi: { {method, path(API_PREFIX dahil), auth, page, name}, ... }
-- F9 spec kapsama testi (her route spec'te var mı) ve debug için
function _M.route_list() ... end

function _M.register(app) ... end
--  her route için: base = { cors, logger, audit_context }
--    auth → + middleware.auth
--    page → + middleware.authorization.requires(page)
--  app:match(name, API_PREFIX .. path, respond_to({ [METHOD] = chain(...) }))
--  aynı path'teki farklı metodlar tek respond_to altında toplanır (Lapis kuralı)
--  OPTIONS her path için cors preflight'a bağlanır

return _M
```

**Route sırası kuralı:** `ROUTES` dizisi sıralıdır; literal path'ler (`/todos/stats`) parametreli olanlardan (`/todos/:id`) **önce** yazılır (00-genel-bakis #14). Ayrıca `:id` parametresi Lapis route pattern'inde değil handler'da `validation.is_uuid` ile doğrulanır. Karar: geçersiz UUID → **404** (varlık yok; bilgi sızdırmaz, istemci için daha basit). Handler'lar ortak `require_uuid_param(self, "id", ERR.TODO_NOT_FOUND)` yardımcı fonksiyonunu kullanır (error_handler modülünde).

`"handlers.todos#list"` notasyonu (F5+ route'ları): `"modül#fonksiyon"` string'i `register` sırasında `require` edilip çözülür → route tablosu handler modüllerini yükleme sırasından bağımsız ve Swagger tarafından okunabilir.

**Health handler** (router.lua içinde değil, `handlers/` altında dosya ağacında olmadığı için `router.lua`'da küçük yerel fonksiyon):

```lua
-- GET /api/v1/health → { status, db, version, uptime_s }
local function health(self)
  local ok, err = query.ping()            -- SELECT 1, 1 sn timeout
  local body = { status = ok and "ok" or "degraded", db = ok and "up" or "down",
                 version = VERSION, uptime_s = math.floor(ngx.now() - STARTED) }
  return { status = ok and 200 or 503, json = body }
end
```

Route tablosunda `handler = health` (fonksiyon referansı) olarak geçer. `/health` zincirinde yalnızca `cors` + `logger` vardır (audit_context gereksiz).

### `api/src/db/query.lua`

```lua
-- Parametreli sorgu katmanı (pgmoon extended protocol, $1..$n).
-- Değerler ASLA SQL string'ine gömülmez. Transaction bağlantısı ngx.ctx.tx_conn'da tutulur.
local pool = require("db.pool")
local _M = {}

-- Satır listesi döner
-- @return rows | nil, err (err: AppError { code = DB_UNAVAILABLE | INTERNAL_ERROR | EMAIL_TAKEN ... })
function _M.query(sql, ...) end

-- Tek satır veya nil (bulunamadı) döner
function _M.query_one(sql, ...) end        -- → row | nil (ve hata yoksa ikinci değer nil)

-- INSERT/UPDATE/DELETE: etkilenen satır sayısı
function _M.exec(sql, ...) end             -- → affected_rows | nil, err

-- fn() içindeki tüm query'ler aynı bağlantıda, BEGIN/COMMIT arasında koşar.
-- fn nil, err dönerse veya error() fırlatırsa ROLLBACK.
-- İç içe çağrı: dıştaki transaction kullanılır (SAVEPOINT yok — YAGNI)
function _M.with_transaction(fn) end       -- → fn'in dönüş değerleri | nil, err

-- Health için
function _M.ping() end                     -- → true | nil, err

-- LIKE/ILIKE araması için kullanıcı girdisini kaçışlar: \ → \\, % → \%, _ → \_ ve "%...%" ile sarar.
-- Sonuç yine $n parametresi olarak gönderilir: "title ILIKE $1 ESCAPE '\'"
function _M.like_pattern(s) end            -- → string
```

**pgmoon ayarları** (`pool.configure` sırasında, F2 `db/pool.lua` ile birlikte):

- `convert_null = true` → SQL `NULL` Lua'ya `pgmoon.NULL` olarak gelir; `models/*.serialize` bunu `cjson.null`'a çevirir (alan JSON'da `null` görünür, kaybolmaz).
- `pg:set_type_deserializer(oid_jsonb, "json")` + `pg:set_type_deserializer(oid_json, "json")` → `audit_logs.old_value/new_value` Lua tablosu olarak gelir (cjson.safe ile decode).
- `TEXT[]` (`todos.tags`) için pgmoon'un yerleşik array deserializer'ı kullanılır; yazarken `$1::text[]` + `pgmoon.arrays.encode_array`.

**Bağlantı seçimi:**

```
query(sql, ...):
  if ngx.ctx.tx_conn: pg = ngx.ctx.tx_conn  (iade ETME)
  else: pg = pool.acquire(); sorgu; pool.release(pg, broken)
```

**pgmoon hata → AppError eşlemesi** (`map_pg_error`):

| pgmoon / SQLSTATE | AppError kodu | Not |
|---|---|---|
| connect hatası, `timeout`, `closed` | `DB_UNAVAILABLE` | bağlantı `broken` |
| `23505` unique_violation, constraint `users_email_key` | `EMAIL_TAKEN` | constraint adına göre |
| `23505` diğer | `CONFLICT` | |
| `23503` foreign_key_violation | `NOT_FOUND` | ör. silinmiş kullanıcıya todo |
| `22P02` invalid_text_representation (bozuk UUID/enum) | `BAD_REQUEST` | |
| `23514` check_violation | `VALIDATION_FAILED` | `details = { _ = { constraint } }` |
| diğer | `INTERNAL_ERROR` | SQL + hata loglanır, istemciye gitmez |

Eşleme sonucu dönen AppError `err.sqlstate` alanını da taşır (ör. `"23505"`); service katmanı gerekirse
kodu bağlama göre yeniden yazar (ör. `user_service` 23505'i her durumda `EMAIL_TAKEN` yapar). Varsayılan eşleme
burada, bağlama özel yorum service'te.

pgmoon hata nesnesinden SQLSTATE: pgmoon ≥ 1.16'da `query` başarısızlığında 2. dönüş mesaj, 3. dönüş (extended) `{ code = "23505", constraint = "...", ... }` şeklinde alan tablosu. Kesin API F3 başında pgmoon kaynağından doğrulanır; `map_pg_error` tek fonksiyonda izole olduğu için değişiklik tek yerde.

**Güvenlik kuralı:** `query.lua` dışındaki hiçbir modül `pgmoon`'u `require` etmez. Dinamik SQL parçaları (ORDER BY alanı, WHERE koşul listesi) yalnızca **whitelist'ten** gelen sabit string'lerle kurulur; değerler her zaman `$n`. Yardımcı:

```lua
-- Dinamik WHERE kurucu: koşullar ve değerleri eş zamanlı toplar, $n numaralarını yönetir
local b = query.builder()
b:where("user_id = $?", identity.user_id)
b:where("status = $?::todo_status", filters.status)      -- nil ise eklenmez
local sql, params = b:build("SELECT ... FROM todos", "ORDER BY created_at DESC LIMIT $? OFFSET $?", limit, offset)
query.query(sql, unpack(params))
```

`$?` yer tutucuları `build` sırasında `$1, $2, ...`'ye çevrilir. Tablo (sıcak path) `table.new(8, 0)` ile ön-boyutlanır.

### `api/src/middleware/error_handler.lua`

```lua
-- Merkezi hata yönetimi: AppError oluşturma, HTTP yanıtına çevirme, beklenmeyen hataları yakalama.
local protocol = require("todo_shared.protocol")
local _M = {}

-- Beklenen hata nesnesi (00-genel-bakis §4)
function _M.new(code, message, details) → { code, message, details, __app_error = true }

function _M.is_app_error(e) end

-- AppError → Lapis yanıt tablosu
function _M.respond(err)
  local status = protocol.http_status(err.code)
  local headers = err.headers                    -- ör. Retry-After (RATE_LIMITED)
  return { status = status, json = protocol.error_body(err, ngx.ctx.req_id), headers = headers }
end

-- Zinciri xpcall ile sarar; error() ile fırlatılan AppError'ı da (altyapı katmanı) yanıtlar
function _M.guard(fn)
  local ok, res = xpcall(fn, debug.traceback)
  if ok then return res end
  -- res: string (traceback) veya AppError tablosu
  ...
  ngx.log(ngx.ERR, cjson.encode({ req_id = ngx.ctx.req_id, err = tostring(res) }))
  -- Header'lar zaten gönderildiyse (ör. CSV export streaming ortasında hata) yeni yanıt yazılamaz:
  -- yalnızca logla ve bağlantıyı kes ki istemci yarım dosyayı başarılı sanmasın.
  if ngx.headers_sent then return ngx.exit(ngx.ERROR) end
  return _M.respond(_M.new("INTERNAL_ERROR", "Beklenmeyen bir hata oluştu"))
end

-- JSON gövde okuma (tüm handler'lar kullanır)
-- @return table | nil, AppError(BAD_REQUEST | PAYLOAD_TOO_LARGE)
function _M.read_json_body() end
--  ngx.req.read_body(); data = ngx.req.get_body_data()
--  data nil ve get_body_file() var → PAYLOAD_TOO_LARGE (buffer aşıldı)
--  Content-Type application/json değil → BAD_REQUEST
--  cjson.safe.decode → nil ise BAD_REQUEST "Geçersiz JSON"
--  kök tablo değilse BAD_REQUEST

-- validation hatası → AppError
function _M.validation(errors) return _M.new("VALIDATION_FAILED", nil, errors) end

function _M.require_uuid_param(self, name, not_found_code) end

function _M.on_unhandled(err, trace) end   -- app.handle_error için

return _M
```

**Modül adı:** Dosya `middleware/error_handler.lua`'dır; tüm katmanlar onu `errors` adıyla alır:
`local errors = require("middleware.error_handler")` → `errors.new`, `errors.respond`, `errors.guard`,
`errors.read_json_body`, `errors.validation`, `errors.require_uuid_param`. Ayrı `util/` veya `errors.lua` dosyası
**yoktur**; JSON gövde okuma için kanonik ad `errors.read_json_body()`'dir.

**Kural:** 5xx yanıtlarında `message` her zaman jenerik; `details` yok. 4xx'te `details` serbest ama hiçbir zaman SQL/stack içermez.

### `api/src/middleware/cors.lua`

```lua
-- CORS: yalnızca CORS_ORIGINS listesindeki origin'lere izin verir.
-- handle: zincirin ilk halkası, yalnızca preflight'ı sonlandırır
function _M.handle()
  if ngx.req.get_method() ~= "OPTIONS" then return nil end
  local origin = ngx.var.http_origin
  if not origin then return nil end                       -- tarayıcı dışı istemci
  if not allowed(origin) then return { status = 403, json = ... } end
  ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  ngx.header["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
  ngx.header["Access-Control-Max-Age"] = "600"
  return { status = 204, layout = false }
end

-- header_filter: lua.conf server bloğunda header_filter_by_lua_block ile her yanıta (hata dahil)
function _M.header_filter()
  local origin = ngx.var.http_origin
  if not origin then return end
  ngx.header["Vary"] = "Origin"                            -- izinsiz origin'de de cache ayrışmalı
  if not allowed(origin) then return end                   -- header yok → tarayıcı engeller
  ngx.header["Access-Control-Allow-Origin"] = origin
  ngx.header["Access-Control-Expose-Headers"] = "X-Request-Id, Retry-After, Content-Disposition"
end
```

Neden iki parça: zincir yalnızca Lapis route'larında çalışır; 404 handler, Lapis `respond_to` 405'i ve nginx
`error_page 413` zincirin dışında kalır. Header'lar handler'da basılsaydı bu hatalar tarayıcıda "ağ hatası" olarak
görünürdü (JSON gövde okunamaz). `header_filter` fazı her yanıtta çalışır.

Frontend normalde API'ye aynı origin'den gider (00 §6.2); CORS yalnızca API portuna başka bir origin'den doğrudan
erişimde devreye girer.

`Access-Control-Allow-Credentials` **yok**: kimlik doğrulama cookie değil Bearer header ile → CSRF yüzeyi yok.

### `api/src/middleware/logger.lua`

```lua
-- İstek logu: req_id üretir, log fazında tek satır erişim logu yazar (json | text).
function _M.handle(self)                -- zincirin 2. halkası
  local id = ngx.var.http_x_request_id  -- güvenilir proxy'den geliyorsa ve UUID ise kullan
  if not (id and is_uuid(id)) then id = random.uuid4() end
  ngx.ctx.req_id = id
  ngx.ctx.started_at = ngx.now()
  ngx.header["X-Request-Id"] = id
end

function _M.log_phase()                 -- log_by_lua
  -- alanlar: ts (ISO8601), level, req_id, method, path, status, duration_ms,
  --          user_id (ngx.ctx.identity), ip, bytes
  -- query string LOGLANMAZ (reset token vb. sızmasın) — yalnızca ngx.var.uri
  -- metrics shared dict: incr req_total, req:<2xx|4xx|5xx>, latency_sum_ms
end

-- Uygulama logu (servisler kullanır): seviye filtreli, req_id otomatik eklenir
function _M.info(msg, fields) end
function _M.warn(msg, fields) end
function _M.error(msg, fields) end
function _M.debug(msg, fields) end
```

Formatlar:

```
json: {"ts":"2026-09-18T10:00:00.123Z","level":"info","req_id":"…","method":"GET","path":"/api/v1/todos","status":200,"duration_ms":12,"user_id":"…"}
text: 2026-09-18T10:00:00.123Z INFO [5b1d9c1e] GET /api/v1/todos 200 12ms user=…
```

Log satırı tablosu modül seviyesinde tek tablo + `table.clear` ile yeniden kullanılır (log fazı sıcak path; `-- ponytail:` notu ile ölçüm gerekçesi). Log hedefi `ngx.log(ngx.NOTICE, line)` → stderr → Docker log sürücüsü.

`logger.handle` zincirde 2. sırada olduğu için `cors` preflight (204) yanıtlarında `req_id` üretilmez → log fazında `req_id` yoksa `"-"` yazılır. Kabul edilebilir.

### `api/src/security/random.lua` (minimal)

```lua
local resty_random = require("resty.random")
local str = require("resty.string")
-- Kriptografik rastgele n byte → hex
function _M.hex(n) return str.to_hex(assert(resty_random.bytes(n, true))) end
-- RFC 4122 v4 UUID
function _M.uuid4() end
```

Tam tasarım ve testleri F4'te.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Route tablosu veri olarak (`ROUTES`) | Tek kaynak: Lapis kaydı, RBAC eşlemesi ve Swagger path kontrolü aynı listeden. |
| `chain()` kendi fonksiyonumuz, Lapis `before_filter` değil | `before_filter` route bazlı middleware seçimine uygun değil; zincir sırası açık ve test edilebilir. |
| `init_by_lua`'da `require("app")` | Modüller master'da yüklenir, worker'lar copy-on-write paylaşır; config hatası nginx'i hiç başlatmaz. |
| `env.conf` üretilip commit edilir | nginx env geçirmez; elle senkron tutmak hata kaynağı. |
| İç içe transaction = dış transaction | SAVEPOINT ihtiyacı yok (YAGNI). |
| Geçersiz UUID → 404 | Bilgi sızdırmaz, istemci tek hata yolu işler. |
| Query string loglanmaz | Reset token, arama terimleri gibi hassas veriler loga düşmez. |
| `lua_code_cache` hep `on` | İki conf dosyası tutmamak; dev'de `make api.reload`. |

## Kabul kriterleri (DoD)

- [ ] `JWT_SECRET` eksikken `make up` → api konteyneri başlamaz, logda `Konfigürasyon hatası: JWT_SECRET: zorunlu`.
- [ ] Birden fazla hatalı env → tüm hatalar tek mesajda listelenir.
- [ ] `APP_ENV=production` + `CORS_ORIGINS=*` → başlamaz.
- [ ] `curl -i localhost:28080/api/v1/health` → `200`, `{"status":"ok","db":"up",...}`, `X-Request-Id` header'ı UUID.
- [ ] Postgres durdurulunca `/health` → `503`, `"db":"down"`; API çökmez.
- [ ] `curl localhost:28080/api/v1/yok` → `404` JSON `{"error":{"code":"NOT_FOUND",...,"req_id":...}}`.
- [ ] Kasıtlı `error("x")` atan test route'u → `500 INTERNAL_ERROR`, gövdede stack yok, logda traceback var.
- [ ] `OPTIONS` + izinli `Origin` → `204` + CORS header'ları; izinsiz origin → `403`, `Allow-Origin` yok.
- [ ] İzinli `Origin` ile 401/404/405/413 hata yanıtlarında da `Access-Control-Allow-Origin` var (`header_filter`).
- [ ] `LOG_FORMAT=text` → text satır; `json` → geçerli JSON (`jq .` ile parse edilir).
- [ ] 1.5 MiB body → `413 PAYLOAD_TOO_LARGE` (nginx'in HTML 413'ü değil — `error_page 413 = @json413` ile JSON).
- [ ] `query.lua` birim testi: builder `$?` → `$1..$n` doğru numaralanır; `with_transaction` hata durumunda ROLLBACK çağırır (pgmoon mock).
- [ ] `grep -rn "require(\"pgmoon\")" api/src` → yalnızca `db/pool.lua`.
- [ ] `make conf.env && git diff --exit-code api/conf/env.conf` temiz.

## Doğrulama

```bash
make up && make api.reload
curl -si localhost:28080/api/v1/health | sed -n '1p;/X-Request-Id/p;$p'
docker compose stop postgres; curl -s localhost:28080/api/v1/health; docker compose start postgres
curl -s localhost:28080/api/v1/does-not-exist | jq .
curl -si -X OPTIONS -H 'Origin: http://localhost:28000' \
     -H 'Access-Control-Request-Method: POST' localhost:28080/api/v1/health | head -n 8
head -c 1600000 /dev/zero | curl -s -X POST -H 'Content-Type: application/json' \
     --data-binary @- localhost:28080/api/v1/health | jq .error.code        # "PAYLOAD_TOO_LARGE"
docker compose logs api --tail 5 | tail -n 1 | jq .                         # JSON log satırı
JWT_SECRET= docker compose up api                                           # başlamamalı
busted api/spec --pattern=query                                             # builder + transaction
```

## Riskler / Dikkat Noktaları

- **Lapis sürüm farkları**: `respond_to`, `handle_404`, `handle_error` imzaları Lapis 1.16'da doğrulanmalı. Lapis'in `json` yanıtı `cjson` ile encode eder; boş tabloların `{}` vs `[]` davranışı: listeler için `cjson.empty_array_mt` kullanılır (`data = setmetatable(rows, cjson.empty_array_mt)`).
- **`client_body_buffer_size`** body'yi bellekte tutar; 1 MiB × eşzamanlı istek bellek kullanımı — kabul edilebilir (limit zaten 1 MiB).
- **Docker DNS resolver** `127.0.0.11` yalnızca Docker'da; prod'da (F18) resolver env/konfig ile değişir.
- **pgmoon SQLSTATE erişimi** sürüme bağlı → `map_pg_error` testleri gerçek DB'ye karşı integration testinde (F11) de doğrulanır.
- **`X-Request-Id`'yi dışarıdan kabul etmek** log zehirlemesine açık → yalnızca UUID formatı kabul edilir.

## Tahmini Efor

**L** — 2–3 gün.
