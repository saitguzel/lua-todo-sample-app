# ═══ FAZ 2 — VERİTABANI + MIGRATION ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — teknik düzeltmeler #5 (havuz), #6 (parametreli sorgu), #15 (pgcrypto); env §6 (`DB_*`, `SEED_DEFAULTS`); RBAC §7.

## Amaç

PostgreSQL şemasını 7 sıralı, geri alınabilir, idempotent migration ile kurmak; varsayılan kullanıcıları ve RBAC matrisini seed'lemek; OpenResty cosocket keepalive tabanlı bağlantı havuzunu (`db/pool.lua`) yazmak. Bu fazın sonunda `make db.migrate && make db.seed` temiz bir veritabanında şemayı ve seed verisini oluşturur, ikinci kez çalıştırıldığında hiçbir şey değiştirmez.

## Önkoşullar

- FAZ 0 (docker-compose'da `postgres`, Makefile).
- FAZ 1 (`todo_shared.types` — enum değerleri ve `DEFAULT_PERMISSIONS` seed'de kullanılır).
- FAZ 4'teki `security/password.lua` seed için gerekir → **sıra notu:** `seeds/default_users.lua` bu fazda yazılır ama `make db.seed` F4 bitene kadar yalnızca `rbac_defaults` çalıştırır; `default_users` F4 sonunda etkinleşir (DoD'de ayrı madde).
- `config.lua` F3'te yazılır; bu fazda `pool.lua` env'i doğrudan `os.getenv` ile okuyan **geçici** bir `config` stub'ı kullanmaz — bunun yerine `pool.lua` konfigürasyonu parametre olarak alır (`pool.configure(opts)`), F3'te `config.lua` bunu çağırır. Migration CLI kendi `os.getenv` okumasını yapar (tek yer).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/migrations/001_users.lua` | `pgcrypto`, `user_role` enum, `users` |
| `api/migrations/002_todos.lua` | `todo_status`, `todo_priority` enum, `todos` + indeksler |
| `api/migrations/003_audit_logs.lua` | `audit_logs` + indeksler |
| `api/migrations/004_rbac.lua` | `role_page_permissions` |
| `api/migrations/005_password_reset.lua` | `password_reset_tokens` |
| `api/migrations/006_triggers.lua` | `set_updated_at()` + trigger'lar |
| `api/migrations/007_cleanup_logs.lua` | `cleanup_logs` |
| `api/seeds/default_users.lua` | admin + todouser (Argon2id hash) |
| `api/seeds/rbac_defaults.lua` | 2 rol × 9 sayfa matrisi |
| `api/src/db/pool.lua` | pgmoon bağlantı al/bırak, keepalive havuzu |
| `api/src/db/migrations.lua` | Migration runner (up / down / status / seed) + CLI girişi |
| `Makefile` | `db.migrate`, `db.rollback`, `db.status`, `db.seed`, `db.reset` |

## Dosya Bazlı Tasarım

### Migration Dosya Formatı

Her migration dosyası aynı şekli döndürür:

```lua
-- 002_todos: todo durum/öncelik enum'ları ve todos tablosu
return {
  version = 2,
  name = "todos",
  up = {
    [[CREATE TYPE todo_status AS ENUM ('pending','in_progress','completed')]],
    [[CREATE TYPE todo_priority AS ENUM ('low','medium','high')]],
    [[CREATE TABLE todos ( ... )]],
    [[CREATE INDEX idx_todos_user_status ON todos(user_id, status)]],
  },
  down = {
    [[DROP TABLE IF EXISTS todos]],
    [[DROP TYPE IF EXISTS todo_priority]],
    [[DROP TYPE IF EXISTS todo_status]],
  },
}
```

Karar: Lapis'in `lapis.db.migrations` modülü **kullanılmaz**. Gerekçe: Lapis migration'ları `lapis.db` (client-side escape, kendi bağlantı yönetimi) üzerinden koşar ve fonksiyon tabanlıdır; bizim ihtiyacımız DDL string listesi + transaction + sürüm tablosu — ~120 satırlık kendi runner'ımız pgmoon'u doğrudan kullanır ve `db/query.lua` ile aynı bağlantı yolunu paylaşır. (00-genel-bakis §11 #6 ile uyumlu: Lapis yalnızca routing için.)

`up`/`down` string listesidir (fonksiyon değil) → migration'lar deterministik, `status` komutu SQL'i yazdırabilir.

### Şema (Migration İçerikleri)

#### 001_users

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TYPE user_role AS ENUM ('admin', 'todouser');
CREATE TABLE users (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email          VARCHAR(255) UNIQUE NOT NULL,
  password_hash  VARCHAR(255) NOT NULL,
  full_name      VARCHAR(255),
  role           user_role NOT NULL DEFAULT 'todouser',
  is_active      BOOLEAN DEFAULT true,
  last_login_at  TIMESTAMPTZ,
  created_at     TIMESTAMPTZ DEFAULT now(),
  updated_at     TIMESTAMPTZ DEFAULT now()
);
-- E-posta her zaman küçük harfle saklanır (validation lower yapar); DB de garanti etsin
ALTER TABLE users ADD CONSTRAINT users_email_lower CHECK (email = lower(email));
```

Down: `DROP TABLE users; DROP TYPE user_role;` (`pgcrypto` extension'ı silinmez — başka şema kullanıyor olabilir).

#### 002_todos

Prompt'taki şema + ekler:

```sql
-- prompt şeması aynen, ek olarak:
CREATE INDEX idx_todos_user_status  ON todos(user_id, status);
CREATE INDEX idx_todos_user_created ON todos(user_id, created_at DESC);
CREATE INDEX idx_todos_due_date     ON todos(due_date) WHERE status <> 'completed';
CREATE INDEX idx_todos_tags         ON todos USING GIN (tags);
ALTER TABLE todos ADD CONSTRAINT todos_title_not_blank CHECK (length(btrim(title)) > 0);
```

| İndeks | Hangi sorgu |
|---|---|
| `(user_id, status)` | todouser listesi + status filtresi, stats `GROUP BY status` |
| `(user_id, created_at DESC)` | varsayılan sıralama |
| `due_date` partial | "gecikmiş" stats sayacı |
| `GIN(tags)` | `?tag=x` filtresi (`tags @> ARRAY[$1]`) |

#### 003_audit_logs

Prompt'taki şema + iki indeks aynen, ek:

```sql
CREATE INDEX idx_audit_action ON audit_logs(action, created_at DESC);
```

(Audit filtresi `action` ile yapılır, F8.)

#### 004_rbac

Prompt'taki `role_page_permissions` aynen. `UNIQUE(role, page_key)` seed'in `ON CONFLICT` hedefidir.

#### 005_password_reset

Prompt'taki şema + ek:

```sql
CREATE INDEX idx_reset_user ON password_reset_tokens(user_id);
CREATE INDEX idx_reset_expires ON password_reset_tokens(expires_at);  -- temizlik için
```

#### 006_triggers

Prompt'taki fonksiyon + iki trigger aynen. Down: `DROP TRIGGER ... ; DROP FUNCTION set_updated_at();`.

#### 007_cleanup_logs

Prompt'taki şema aynen + `CREATE INDEX idx_cleanup_created ON cleanup_logs(created_at DESC);`.

### Sürüm Tablosu

Runner ilk çalıştığında oluşturur (migration değildir):

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    INTEGER PRIMARY KEY,
  name       VARCHAR(100) NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### `api/src/db/pool.lua`

```lua
-- pgmoon bağlantı havuzu: OpenResty cosocket keepalive (worker başına).
-- "min/max" yerine: pool_size = worker başına en fazla boşta tutulan bağlantı.
local pgmoon = require("pgmoon")
local _M = {}

local cfg -- configure() ile set edilir

-- F3'te config.lua tarafından init_by_lua aşamasında çağrılır
function _M.configure(opts)
  -- opts: host, port, database, user, password, ssl, pool_size,
  --       idle_timeout_ms, connect_timeout_ms, query_timeout_ms
  cfg = opts
end

-- Havuzdan (veya yeni) bağlantı alır
-- @return pg | nil, err
function _M.acquire()
  local pg = pgmoon.new({
    host = cfg.host, port = cfg.port, database = cfg.database,
    user = cfg.user, password = cfg.password, ssl = cfg.ssl,
    pool = "todo:" .. cfg.database,   -- keepalive havuz adı
  })
  pg:settimeouts(cfg.connect_timeout_ms, cfg.query_timeout_ms, cfg.query_timeout_ms)
  local ok, err = pg:connect()
  if not ok then return nil, err end
  return pg
end

-- Bağlantıyı havuza iade eder; hata durumunda kapatır
-- @param broken boolean: sorgu sırasında ağ/protokol hatası olduysa true
function _M.release(pg, broken)
  if broken then return pg:disconnect() end
  local ok, err = pg:keepalive(cfg.idle_timeout_ms, cfg.pool_size)
  if not ok then ngx.log(ngx.WARN, "keepalive başarısız: ", err); pg:disconnect() end
end

-- Kullanım yardımcısı: bağlantıyı al, fn(pg) çalıştır, her durumda iade et
function _M.with_connection(fn) ... end  -- pcall ile; hata varsa broken=true

-- init_worker'da "ısıtma": n bağlantı açıp havuza bırak (prompt'taki "min 5" karşılığı)
function _M.warm(n) ... end   -- ngx.timer.at(0, ...) içinden çağrılır (init_worker'da cosocket yok)

return _M
```

**Önemli davranışlar:**

| Durum | Davranış |
|---|---|
| `connect` başarısız | `nil, err` → üst katman `DB_UNAVAILABLE` (503) üretir (F3 `query.lua`) |
| Transaction içindeyken hata | Bağlantı `ROLLBACK` sonrası iade edilir; ROLLBACK da başarısızsa `broken=true` |
| Açık transaction'lı bağlantı havuza dönmemeli | `query.lua` `with_transaction` bunu garanti eder (F3) |
| `ssl = true` | `ssl_verify = true` + `lua_ssl_trusted_certificate` (nginx.conf, F3) |
| Timer / CLI bağlamı | cosocket `init_by_lua` ve `init_worker_by_lua`'da kullanılamaz → yalnızca request, timer ve `resty` CLI bağlamlarında |

**Parametreli sorgu (pgmoon ≥ 1.16):** `pg:query("SELECT * FROM users WHERE email = $1", email)` → extended query protocol (Parse/Bind/Execute); değer asla SQL string'ine girmez. `pool.lua` bunu bilmez; F3 `query.lua` kullanır. Bu fazdaki seed'ler de aynı yolu kullanır.

### `api/src/db/migrations.lua`

İki rol: (1) kütüphane (`_M.up`, `_M.down`, `_M.status`), (2) `resty` ile çalıştırılan CLI.

```lua
-- Migration runner: api/migrations/NNN_*.lua dosyalarını sırayla uygular.
-- CLI: resty -I /app/src -I /app/lib /app/src/db/migrations.lua <up|down|status|seed> [adım]
local _M = {}

-- migrations/ dizinini tarar, version'a göre sıralı liste döner
-- (io.popen("ls") yerine sabit dosya listesi DEĞİL; lfs yok → io.popen('ls -1 dir'))
local function load_all(dir) ... end   -- → { {version, name, up, down}, ... }

local function ensure_version_table(pg) ... end
local function applied_versions(pg) ... end        -- → set

-- Uygulanmamış tüm migration'ları, HER BİRİ KENDİ transaction'ında uygular
-- Postgres DDL transactional → yarım migration kalmaz
function _M.up(pg, dir) ... end          -- → applied_count | nil, err

-- Son `steps` (default 1) migration'ı geri alır
function _M.down(pg, dir, steps) ... end

function _M.status(pg, dir) ... end      -- → { {version, name, applied_at|nil}, ... }

-- Seed'leri sırayla çalıştırır: rbac_defaults, default_users (SEED_DEFAULTS=true ise)
function _M.seed(pg, seeds_dir, opts) ... end

-- CLI girişi: arg tablosu varsa (resty script modu) çalışır
if arg and arg[0] and arg[0]:match("migrations%.lua$") then
  -- env'den bağlantı bilgisi oku, pool.configure(...), with_connection(...)
  -- çıktı: "↑ 001_users (12 ms)" satırları; hata → stderr + os.exit(1)
end

return _M
```

**Eşzamanlılık kilidi:** Aynı anda iki `db.migrate` (ör. iki API replica start'ta) çalışmasın diye tüm `up`/`down` işlemi `SELECT pg_advisory_lock(727001)` / `pg_advisory_unlock(727001)` arasında koşar. Sabit anahtar `727001` = "todo migrations" (dokümante edilmiş sihirli sayı).

**Akış (`up`):**

```
acquire conn
pg_advisory_lock(727001)
ensure schema_migrations
applied = SELECT version FROM schema_migrations
for m in load_all() sorted by version:
  if applied[m.version]: continue
  BEGIN
    for stmt in m.up: query(stmt)  -- hata → ROLLBACK, unlock, return nil, "NNN: <err>"
    INSERT INTO schema_migrations(version, name) VALUES ($1, $2)
  COMMIT
  log "↑ NNN_name (x ms)"
pg_advisory_unlock(727001)
release conn
```

**Dosya adı ↔ version doğrulaması:** `002_todos.lua` içinde `version = 2` değilse runner hata verir (kopyala-yapıştır hatası koruması). Version'lar ardışık olmalı (boşluk → hata).

**Migration'lar uygulama başlangıcında otomatik koşmaz.** Karar: prod'da migration açık bir adım (F18 deploy pipeline'ında `db.migrate` job'u); OpenResty `init_worker`'da DDL koşturmak çok worker/replica yarışına yol açar.

### `api/seeds/rbac_defaults.lua`

```lua
-- Varsayılan RBAC matrisi: her rol × her sayfa için bir satır.
-- Mevcut satırlara DOKUNMAZ (admin'in yaptığı değişiklikler korunur).
local types = require("todo_shared.types")

return {
  name = "rbac_defaults",
  run = function(q)   -- q(sql, ...) : parametreli sorgu fonksiyonu
    for _, role in ipairs(types.ROLES) do
      for _, page in ipairs(types.PAGES) do
        q([[INSERT INTO role_page_permissions (role, page_key, can_access)
            VALUES ($1::user_role, $2, $3)
            ON CONFLICT (role, page_key) DO NOTHING]],
          role, page, types.default_permission(role, page))
      end
    end
  end,
}
```

18 satır (2 × 9). Her zaman çalışır (`SEED_DEFAULTS`'tan bağımsız) — matris boşsa sistem kullanılamaz. Karar: yeni bir sayfa `PAGES`'e eklendiğinde seed tekrar koşunca yalnızca yeni satırlar eklenir.

### `api/seeds/default_users.lua`

```lua
-- Varsayılan kullanıcılar: yalnızca SEED_DEFAULTS=true iken çalışır.
local password = require("security.password")   -- F4

local USERS = {
  { email = "admin@todoapp.local", password = "Admin123!", full_name = "Sistem Yöneticisi", role = "admin" },
  { email = "user@todoapp.local",  password = "User123!",  full_name = "Örnek Kullanıcı",   role = "todouser" },
}

return {
  name = "default_users",
  enabled = function(env) return env.SEED_DEFAULTS == "true" end,
  run = function(q)
    for _, u in ipairs(USERS) do
      local hash = assert(password.hash(u.password))
      q([[INSERT INTO users (email, password_hash, full_name, role)
          VALUES ($1, $2, $3, $4::user_role)
          ON CONFLICT (email) DO NOTHING]],
        u.email, hash, u.full_name, u.role)
    end
  end,
}
```

- `ON CONFLICT DO NOTHING`: var olan kullanıcının parolası **sıfırlanmaz** (üretimde admin parolasını değiştirmiş biri seed'i tekrar koşarsa kaybetmez).
- `APP_ENV=production` ve `SEED_DEFAULTS=true` → runner `WARN` loglar ("varsayılan parolalarla kullanıcı oluşturuluyor") ama engellemez (prompt davranışı korunur).
- Seed audit log yazmaz (sistem işlemi).

### Makefile Eklemeleri

```make
MIGRATE = docker compose exec -T api resty -I /app/src -I /app/lib /app/src/db/migrations.lua
db.migrate:  ; $(MIGRATE) up
db.rollback: ; $(MIGRATE) down $(or $(STEPS),1)
db.status:   ; $(MIGRATE) status
db.seed:     ; $(MIGRATE) seed
db.reset:
	docker compose down -v && docker compose up -d --wait postgres api
	$(MAKE) db.migrate db.seed
```

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Kendi runner'ımız (Lapis migrations değil) | Parametreli sorgu yolu tek (pgmoon), DDL string listesi, advisory lock, dosya adı doğrulaması. |
| Her migration kendi transaction'ında | PG DDL transactional; yarım kalan migration imkânsız. |
| Advisory lock | Paralel deploy / replica'larda çift uygulama önlenir. |
| Seed'ler idempotent, var olanı ezmez | Tekrar koşmak güvenli; admin değişiklikleri korunur. |
| `rbac_defaults` her zaman, `default_users` bayraklı | Matris olmadan uygulama çalışmaz; kullanıcılar opsiyonel. |
| `email = lower(email)` CHECK | Uygulama katmanı atlansa bile case-insensitive unique garantisi. |
| Otomatik migration yok | Çok worker yarışı; açık deploy adımı daha güvenli. |
| `pool.warm(n)` | Prompt'taki "min 5" gereksinimini cosocket modelinde karşılamanın tek yolu; `init_worker` → `ngx.timer.at(0)` içinde. |

## Kabul kriterleri (DoD)

- [ ] Boş veritabanında `make db.migrate` → 7 migration uygulanır, `schema_migrations`'ta 7 satır.
- [ ] İkinci `make db.migrate` → "uygulanacak migration yok", çıkış kodu 0.
- [ ] `make db.rollback STEPS=7` → tüm tablolar/tipler silinir; ardından `make db.migrate` tekrar başarılı (up/down simetrisi).
- [ ] `\d todos` indeksleri ve CHECK constraint'i gösterir.
- [ ] `make db.seed` → `role_page_permissions` 18 satır; admin 9 true, todouser 4 true / 5 false.
- [ ] (F4 sonrası) `SEED_DEFAULTS=true make db.seed` → 2 kullanıcı; `password_hash` `$argon2id$v=19$m=4096,t=3,p=1$` ile başlar.
- [ ] Seed ikinci kez → satır sayıları değişmez; admin'in değiştirilmiş parolası korunur.
- [ ] Hatalı SQL içeren sahte bir `008_*.lua` → migration geri alınır, `schema_migrations`'ta 008 yok, çıkış kodu 1.
- [ ] `version` ↔ dosya adı uyuşmazlığı hata verir.
- [ ] `UPDATE users SET full_name='x'` sonrası `updated_at` değişir (trigger).
- [ ] `INSERT INTO users(email, ...) VALUES ('A@B.com', ...)` → CHECK ihlali.
- [ ] Hiçbir seed/runner SQL'inde değer string birleştirme ile gömülmüyor (`grep -n '\.\. *"' api/seeds api/src/db` yalnızca log satırları).

## Doğrulama

```bash
make db.reset
make db.status                                  # 7 satır, hepsi applied
docker compose exec -T postgres psql -U todo todo -c '\dt'
docker compose exec -T postgres psql -U todo todo -c \
  "select role, count(*) filter (where can_access) from role_page_permissions group by role"
#   admin | 9
#   todouser | 4
docker compose exec -T postgres psql -U todo todo -c \
  "select email, role, left(password_hash, 30) from users"
make db.rollback STEPS=7 && make db.migrate     # simetri

# Eşzamanlılık: iki migrate paralel → biri bekler, sonuç tutarlı
( make db.migrate & make db.migrate & wait )
```

## Riskler / Dikkat Noktaları

- **`CREATE TYPE` idempotent değil** → down'lar `IF EXISTS` kullanır; up'lar sürüm tablosu sayesinde tekrar koşmaz. Elle yarım müdahale edilmiş DB'de runner hata verir (beklenen davranış).
- **Enum'a değer eklemek** (`ALTER TYPE ... ADD VALUE`) PG'de transaction içinde kısıtlıdır (PG 12+ izin verir ama aynı tx'te kullanılamaz) → gelecekte yeni rol eklenirse ayrı migration ve not.
- **`io.popen('ls')`** Docker imajında `ls` var; ama dosya adında boşluk olmamalı (adlandırma kuralı: `NNN_snake_case.lua`).
- **Argon2 seed süresi**: m_cost=12, t=3 → ~10–20 ms/kullanıcı; sorun değil.
- **Toplam bağlantı**: `worker_processes auto` (ör. 8 çekirdek) × `DB_POOL_SIZE=20` = 160 > PG default `max_connections=100` → docker-compose'da `postgres -c max_connections=200` veya `DB_POOL_SIZE` düşürülür. README'ye formül yazılır.

## Tahmini Efor

**M** — 1–1.5 gün.
