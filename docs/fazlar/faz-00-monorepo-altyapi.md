# ═══ FAZ 0 — MONOREPO + ALTYAPI ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — env değişkenleri (§6), shared dict'ler (§9), teknik düzeltmeler (§11).

## Amaç

Tek bir `git clone` + `cp .env.example .env` + `make up` ile PostgreSQL, API (boş OpenResty) ve Web (statik sunucu) konteynerlerinin ayağa kalktığı, lint'in pre-commit'te zorunlu olduğu monorepo iskeletini kurmak. Bu fazın sonunda henüz iş mantığı yoktur; ama sonraki her fazın kullanacağı komutlar (`make db.migrate`, `make test`, `make api.dev` …) tanımlı ve (gövdesi boş olsa bile) çalışır durumdadır.

## Önkoşullar

- Yok (ilk faz).
- Geliştirici makinesinde: Docker 24+, Docker Compose v2, GNU Make, git, (opsiyonel yerel) `luarocks` + `luacheck`, Node 20+ (web tarafı için F12'de).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `todo-lua/` (repo kökü = bu proje dizini) | Monorepo kökü |
| `build.sh` | Tüm bileşenleri sırayla derleyen tek giriş noktası (CI ve yerel) |
| `Makefile` | Geliştirici komutları (`db.*`, `api.*`, `web.*`, `test`, `lint`, `bench`) |
| `scripts/check-ports.sh` | `make up` öncesi host port çakışma kontrolü (prompt ağacında yok; port çakışmasını erken ve okunur hatayla yakalamak için) |
| `README.md` | İskelet: hızlı başlangıç, dizin yapısı, komut listesi (F18'de tamamlanır) |
| `docker-compose.yml` | Dev ortamı: `postgres`, `mailhog`, `api`, `web` |
| `docker-compose.prod.yml` | Boş iskelet (yalnızca `version`/`services` başlığı + TODO yorumu); F18'de doldurulur |
| `.env.example` | 00-genel-bakis §6'daki **tüm** değişkenler, birebir |
| `.gitignore` | Lua/Node/Docker/OS çöpleri, `.env`, `web/public/app.wasm`, `web/public/bundle.json` |
| `.editorconfig` | 2 boşluk, LF, UTF-8, trim trailing whitespace |
| `.luacheckrc` | Lint kuralları (ngx_lua std, busted spec'ler için ayrı std) |
| `.githooks/pre-commit` | Staged `.lua` dosyalarında `luacheck` |
| `rockspecs/` | Boş dizin (F1'de rockspec girer) |
| `api/`, `web/`, `shared/` | Prompt'taki ağaca göre boş dizinler + `.gitkeep` |
| `api/Dockerfile` | Dev imajı (OpenResty + LuaRocks bağımlılıkları); F18'de çok aşamalıya dönüşür |
| `web/Dockerfile` | Dev imajı (nginx:alpine statik); F18'de çok aşamalı |
| `api/conf/nginx.conf` | Geçici: `/health` için sabit `200 ok` dönen minimal konfig (F3'te gerçek hali yazılır) |

## Dizin Ağacı (Bu Fazda Oluşturulacak)

Prompt'taki ağaç birebir oluşturulur; henüz içeriği olmayan dosyalar **oluşturulmaz**, yalnızca dizinler `.gitkeep` ile tutulur (boş `.lua` dosyası luacheck'i ve `require`'ı yanıltır).

```
todo-lua/
├── .editorconfig
├── .env.example
├── .gitignore
├── .githooks/pre-commit
├── .luacheckrc
├── build.sh
├── Makefile
├── README.md
├── docker-compose.yml
├── docker-compose.prod.yml
├── docs/                      (bu plan dokümanları)
├── rockspecs/.gitkeep
├── api/
│   ├── Dockerfile
│   ├── conf/nginx.conf         (geçici)
│   ├── src/{middleware,handlers,services,models,repositories,db,security,jobs,mail,openapi}/.gitkeep
│   ├── migrations/.gitkeep
│   ├── seeds/.gitkeep
│   ├── public/swagger/.gitkeep
│   ├── bench/.gitkeep
│   └── spec/integration/.gitkeep
├── web/
│   ├── Dockerfile
│   ├── src/{views,components}/.gitkeep
│   ├── public/.gitkeep
│   ├── js/.gitkeep
│   └── spec/.gitkeep
└── shared/
    ├── src/.gitkeep
    └── spec/.gitkeep
```

## Dosya Bazlı Tasarım

### `docker-compose.yml`

Servisler:

| Servis | İmaj | Port | Not |
|---|---|---|---|
| `postgres` | `postgres:15-alpine` | `127.0.0.1:${DB_HOST_PORT:-25432}:5432` | `healthcheck: pg_isready -U $DB_USER -d $DB_NAME`, volume `pgdata` |
| `mailhog` | `mailhog/mailhog:v1.0.1` | `1025` (SMTP, yalnızca iç ağ), `127.0.0.1:${MAILHOG_UI_HOST_PORT:-28025}:8025` (UI) | Reset e-postalarını dev'de yakalar |
| `api` | `build: { context: ., dockerfile: api/Dockerfile, target: dev }` | `${API_HOST_PORT:-28080}:8080` | `environment: TRUSTED_PROXIES` (web proxy IP'si, 00 §6.2); `depends_on: postgres: condition: service_healthy`; `env_file: .env`; volume mount: `./api/src`, `./api/conf`, `./api/migrations`, `./api/seeds`, `./shared/src` (→ `/app/lib/todo_shared`) → `make api.reload` ile anında yeniden yükleme (bkz. F3) |
| `web` | `nginx:1.27-alpine` | `${WEB_HOST_PORT:-28000}:80` | Volume: `./web/public` + `deploy/web/dev.conf` (`/api/` → api proxy); sabit IP `172.31.250.10` (00 §6.2). Prod imajı `web/Dockerfile` (F17/F18) |

Taslak:

```yaml
name: todo-lua          # proje adı sabit: konteyner/volume/ağ adları başka compose projeleriyle çakışmaz

services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    ports: ["127.0.0.1:${DB_HOST_PORT:-25432}:5432"]   # yalnızca loopback; psql/GUI için
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 3s
      retries: 20

  mailhog:
    image: mailhog/mailhog:v1.0.1
    ports: ["127.0.0.1:${MAILHOG_UI_HOST_PORT:-28025}:8025"]   # SMTP 1025 host'a açılmaz, api iç ağdan erişir

  api:
    build: { context: ., dockerfile: api/Dockerfile, target: dev }   # F18: çok aşamalı imaj
    env_file: .env
    ports: ["${API_HOST_PORT:-28080}:8080"]   # konteyner içi APP_PORT=8080 sabit
    environment:
      TRUSTED_PROXIES: "127.0.0.1,172.31.250.10"   # web nginx'i X-Forwarded-For iletir (00 §6.2)
    depends_on:
      postgres: { condition: service_healthy }
    volumes:
      - ./api/src:/app/src
      - ./api/conf:/app/conf
      - ./api/migrations:/app/migrations
      - ./api/seeds:/app/seeds
      - ./api/public:/app/public
      - ./shared/src:/app/lib/todo_shared

  web:
    image: nginx:1.27-alpine        # dev: yerel build çıktısı; prod imajı web/Dockerfile (kök context)
    ports: ["${WEB_HOST_PORT:-28000}:80"]
    volumes:
      - ./web/public:/usr/share/nginx/html:ro
      - ./deploy/web/dev.conf:/etc/nginx/conf.d/default.conf:ro   # /api/ → api:8080 (aynı origin)
    depends_on: [api]
    networks:
      default:
        ipv4_address: 172.31.250.10

networks:
  default:
    ipam:
      config: [{ subnet: 172.31.250.0/24 }]

volumes:
  pgdata:
```

Karar: API konteyneri içinde shared kütüphane `/app/lib/todo_shared` altına mount edilir (böylece `require("todo_shared.types")` çalışır, bkz. F1) ve `lua_package_path`'e eklenir (F3). LuaRocks ile kurulum F1 rockspec'i ile prod imajında yapılır (F18).

### `.env.example`

00-genel-bakis §6 tablosundaki **her satır**, aynı sırada, aynı default ile. Zorunlu ve default'suz olanlar açıkça "değiştir" yorumu taşır:

```dotenv
# === Uygulama ===
APP_ENV=development
APP_PORT=8080
APP_BASE_URL=http://localhost:28080
WEB_BASE_URL=http://localhost:28000

# === Host port eşlemeleri (yalnızca docker-compose okur; bkz. 00-genel-bakis §6.1) ===
API_HOST_PORT=28080
WEB_HOST_PORT=28000
DB_HOST_PORT=25432
MAILHOG_UI_HOST_PORT=28025

# === Veritabanı ===
DB_HOST=postgres
DB_PORT=5432
DB_NAME=todo
DB_USER=todo
DB_PASSWORD=change-me-dev-only        # DEĞİŞTİR: prod'da >= 16 karakter
DB_SSL=false
DB_POOL_SIZE=20
DB_POOL_IDLE_TIMEOUT_MS=60000
DB_CONNECT_TIMEOUT_MS=3000
DB_QUERY_TIMEOUT_MS=10000

# === JWT ===
JWT_SECRET=dev-secret-change-me-dev-secret-change-me   # DEĞİŞTİR: >= 32 byte, prod'da bu değer reddedilir
JWT_ISSUER=todo-api
JWT_ACCESS_TTL=900
JWT_REFRESH_TTL=604800

# === Argon2id ===
ARGON2_T_COST=3
ARGON2_M_COST=12
ARGON2_PARALLELISM=1

# === Auth ===
PASSWORD_RESET_TTL=3600
LOGIN_RATE_LIMIT=5

# === SMTP ===
SMTP_HOST=mailhog
SMTP_PORT=1025
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=no-reply@todoapp.local
SMTP_TLS=false

# === HTTP ===
CORS_ORIGINS=http://localhost:28000,http://127.0.0.1:28000
TRUSTED_PROXIES=127.0.0.1

# === Log ===
LOG_FORMAT=json
LOG_LEVEL=info

# === Audit temizlik ===
AUDIT_LOG_RETENTION_DAYS=30
AUDIT_CLEANUP_ENABLED=true
AUDIT_CLEANUP_HOUR=3
AUDIT_CLEANUP_BATCH_SIZE=1000

# === Seed / RBAC ===
SEED_DEFAULTS=true
RBAC_CACHE_TTL=60
```

Not: `.env.example`'da `SEED_DEFAULTS=true` (dev kolaylığı); kanonik default (`config.lua`) `false`'tur. Prod'da `.env.example` kopyalanmaz.

### `.gitignore`

```gitignore
.env
*.rock
/lua_modules/
/.luarocks/
luacov.*.out
node_modules/
web/public/app.wasm
web/public/bundle.json
web/dist/
api/logs/
api/*_temp/
playwright-report/
test-results/
.DS_Store
*.swp
```

### `.luacheckrc`

```lua
-- Tüm Lua kaynakları için ortak lint kuralları
std = "ngx_lua"
max_line_length = 120
codes = true
exclude_files = { "lua_modules/", ".luarocks/", "web/node_modules/" }

-- Shared kod hem LuaJIT hem Lua 5.4'te çalışır: sadece ortak alt küme
files["shared/src/"] = { std = "lua51+lua54" }
-- Frontend Wasmoon (Lua 5.4) + JS köprüsü global'i
files["web/src/"] = { std = "lua54", read_globals = { "js" } }
-- busted spec dosyaları
files["**/spec/"] = { std = "+busted" }
```

Not: `lua51+lua54` luacheck'te iki std'nin **kesişimi** değil birleşimidir; kesişim garantisi CI'da iki yorumlayıcıda spec koşturarak sağlanır (F1).

### `.githooks/pre-commit`

```sh
#!/usr/bin/env sh
# Staged Lua dosyalarını luacheck ile denetler; hata varsa commit'i durdurur.
set -eu
files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.lua$' || true)
[ -z "$files" ] && exit 0
if ! command -v luacheck >/dev/null 2>&1; then
  echo "luacheck bulunamadı: 'luarocks install luacheck' veya 'make lint' (docker) kullanın" >&2
  exit 1
fi
# shellcheck disable=SC2086
luacheck $files
```

Kurulum: `make hooks` → `git config core.hooksPath .githooks && chmod +x .githooks/pre-commit`. `make setup` bunu otomatik çağırır.

Karar: husky/pre-commit framework **yok**; `core.hooksPath` git'in yerleşik özelliği, sıfır bağımlılık.

### `Makefile`

| Hedef | Komut | Faz (gövdenin dolacağı) |
|---|---|---|
| `setup` | `cp -n .env.example .env; $(MAKE) hooks` | 0 |
| `hooks` | `git config core.hooksPath .githooks` | 0 |
| `ports.check` | `scripts/check-ports.sh` — `.env`'deki `*_HOST_PORT` değerlerinin host'ta boş olduğunu doğrular (aşağıda) | 0 |
| `up` / `down` / `logs` | `$(MAKE) ports.check && docker compose up -d --build` / `down` / `logs -f api` | 0 |
| `db.migrate` | `docker compose exec api resty -I /app/src -I /app/lib /app/src/db/migrations.lua up` | 2 |
| `db.rollback` | aynı, `down` | 2 |
| `db.seed` | aynı script, `seed` | 2 |
| `db.reset` | `down -v` + `up` + `db.migrate` + `db.seed` | 2 |
| `db.psql` | `docker compose exec postgres psql -U $$DB_USER $$DB_NAME` | 0 |
| `api.dev` | `docker compose up api postgres mailhog` (kod değişikliğinde `make api.reload`) | 3 |
| `api.reload` | `docker compose exec api openresty -s reload` | 3 |
| `lint` | `luacheck api/src api/spec shared web/src` | 0 |
| `test` | `$(MAKE) test.shared test.api test.web` | 1/11/17 |
| `test.shared` | `busted shared/spec` (LuaJIT + lua5.4 iki kez) | 1 |
| `test.api` | `busted api/spec --exclude-tags=integration` | 11 |
| `test.integration` | `busted api/spec/integration` | 11 |
| `test.web` | `busted web/spec` | 17 |
| `test.e2e` | `cd web && npx playwright test` | 17 |
| `bench` | `wrk -t4 -c64 -d30s -s api/bench/list_todos.lua http://localhost:$${API_HOST_PORT:-28080}` | 11 |
| `spec.lint` | `npx @redocly/cli lint http://localhost:$${API_HOST_PORT:-28080}/api/v1/swagger.json` | 9 |
| `web.build` | `cd web && ./build-wasm.sh` | 12 |
| `web.dev` | `cd web && npm run dev` | 12 |

Kural: henüz gövdesi olmayan hedefler `@echo "FAZ X'te eklenecek" && exit 1` değil, **tanımlanmaz**. Bu fazda yalnızca `setup, hooks, ports.check, up, down, logs, db.psql, lint` gerçekten çalışır. (YAGNI: yarım hedef yanlış güven verir.) Yukarıdaki tablo hangi fazın hangi hedefi ekleyeceğinin sözleşmesidir.

`.PHONY` tüm hedefleri listeler; `.env` `include .env` + `export` ile yüklenir (yoksa `-include`).

### `scripts/check-ports.sh` — Port Çakışma Kontrolü

Geliştirme makinesinde başka projeler de çalıştığı için (8080, 3000, 80/443 sık dolu) host portları 00-genel-bakis §6.1'deki
**28xxx bloğundan** seçildi ve `make up` her seferinde önce bu kontrolü çalıştırır.

```sh
#!/usr/bin/env bash
# .env içindeki *_HOST_PORT değerlerinin host'ta boş olduğunu doğrular.
# Kendi yığınımız zaten çalışıyorsa kontrolü atlar (portları biz tutuyoruz).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

if [ -n "$(docker compose ps -q --status running 2>/dev/null)" ]; then
  echo "todo-lua zaten çalışıyor, port kontrolü atlandı"; exit 0
fi

fail=0
for var in API_HOST_PORT WEB_HOST_PORT DB_HOST_PORT MAILHOG_UI_HOST_PORT; do
  port="${!var}"
  # ss yoksa (macOS) lsof'a düş
  if command -v ss >/dev/null; then used=$(ss -ltnH "sport = :$port" | wc -l)
  else used=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l); fi
  if [ "$used" -gt 0 ]; then
    owner=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E ":$port->" | cut -d' ' -f1 || true)
    echo "HATA: $var=$port dolu${owner:+ (konteyner: $owner)} → .env içinde başka bir port seçin" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "portlar boş: API=$API_HOST_PORT WEB=$WEB_HOST_PORT DB=$DB_HOST_PORT MAILHOG=$MAILHOG_UI_HOST_PORT"
exit "$fail"
```

Karar: Konteyner **içi** portlar (`api` 8080, `postgres` 5432, `mailhog` 1025/8025, `web` 80) sabittir ve çakışmaz — her
konteynerin kendi ağ namespace'i vardır. Çakışma yalnızca host'a yayınlanan portlarda olur; bu yüzden yalnızca onlar
env ile yapılandırılabilir. Postgres ve MailHog UI yalnızca `127.0.0.1`'e bağlanır (LAN'a açılmaz).

### `build.sh`

```sh
#!/usr/bin/env bash
# Tüm bileşenleri sırayla doğrular ve derler (CI ve yerel için tek giriş).
set -euo pipefail
cd "$(dirname "$0")"
echo "==> lint";         luacheck api/src shared/src web/src
echo "==> shared test";  busted shared/spec
echo "==> web build";    (cd web && ./build-wasm.sh)
echo "==> docker build"; docker compose build
```

Bu fazda yalnızca `lint` adımı anlamlıdır; diğer adımlar ilgili fazlarda eklenir (dosya faz ilerledikçe büyür).

### `api/Dockerfile` (dev)

```dockerfile
FROM openresty/openresty:1.25.3.2-alpine-fat
RUN apk add --no-cache build-base libargon2-dev openssl-dev git
RUN luarocks install lapis 1.16.0 \
 && luarocks install pgmoon 1.16.0 \
 && luarocks install lua-resty-jwt 0.2.3 \
 && luarocks install argon2 3.0.1 \
 && luarocks install lua-resty-mail 1.1.0 \
 && luarocks install lua-cjson 2.1.0.10-1 \
 && luarocks install busted \
 && luarocks install luacheck
WORKDIR /app
EXPOSE 8080
CMD ["openresty", "-p", "/app", "-c", "conf/nginx.conf", "-g", "daemon off;"]
```

Versiyonlar pinlenir; kesin sürümler F3 başında `luarocks search` ile doğrulanıp güncellenir. `lua-cjson` OpenResty ile zaten gelir (`cjson.safe`) — ayrıca kurulmaz; satır yalnızca referans olarak tabloda, Dockerfile'da **olmayacak**.

### `web/Dockerfile` (dev)

```dockerfile
FROM nginx:1.27-alpine
COPY public/ /usr/share/nginx/html/
```

### `api/conf/nginx.conf` (geçici)

```nginx
worker_processes 1;
error_log stderr info;
events { worker_connections 1024; }
http {
  server {
    listen 8080;
    location = /api/v1/health { default_type application/json; return 200 '{"status":"ok"}'; }
  }
}
```

F3 bu dosyayı tamamen değiştirir.

### `README.md` (iskelet)

Bölümler (başlıkları + kısa içerik): Proje nedir · Mimari (00-genel-bakis'e link) · Gereksinimler · Hızlı başlangıç (`make setup && make up && make db.migrate db.seed`) · Varsayılan kullanıcılar (`admin@todoapp.local / Admin123!`, `user@todoapp.local / User123!` — yalnızca `SEED_DEFAULTS=true`) · Make komutları tablosu · Dizin yapısı · Faz dokümanları linki · Lisans (TBD).

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Git hook için `core.hooksPath` | Sıfır bağımlılık; husky Node gerektirir, pre-commit Python gerektirir. |
| MailHog dev'de | Reset akışını gerçek SMTP olmadan uçtan uca test etmek için (F5). |
| Kaynak dizinleri volume mount | İmajı yeniden derlemeden `make api.reload` ile kod değişikliği alınır. |
| Boş `.lua` dosyası oluşturmamak | Boş modül `require`'da `true` döner, sessiz hata üretir. |
| Makefile'da henüz uygulanmamış hedef yok | Yarım hedef CI'da yanlış yeşil verir. |
| `postgres:15-alpine` | Prompt PG 15+ istiyor; alpine küçük. |

## Kabul kriterleri (DoD)

- [ ] Prompt'taki dizin ağacının tüm dizinleri mevcut (`.gitkeep` ile).
- [ ] `.env.example` 00-genel-bakis §6'daki tüm değişkenleri içeriyor, fazlası yok.
- [ ] `make setup` `.env` oluşturuyor ve `core.hooksPath` ayarlıyor.
- [ ] `make up` sonrası `docker compose ps` → `postgres` healthy, `api`, `web`, `mailhog` running.
- [ ] `make ports.check` boş portlarda `0`, dolu bir portta (ör. `API_HOST_PORT=8080` ve 8080 dinleniyorken) anlamlı mesajla `1` döner.
- [ ] `curl -s localhost:28080/api/v1/health` → `{"status":"ok"}`.
- [ ] `curl -sI localhost:28000` → `200` veya `403` (boş dizin) — nginx ayakta.
- [ ] `http://localhost:28025` MailHog UI açılıyor; `docker compose port postgres 5432` → `127.0.0.1:25432`.
- [ ] Hatalı bir `.lua` dosyası stage'lenince commit reddediliyor.
- [ ] `make lint` temiz çıkıyor.
- [ ] `.gitignore` `.env`'i dışlıyor (`git check-ignore .env` → `.env`).

## Doğrulama

```bash
make setup
make up
docker compose ps
curl -s localhost:28080/api/v1/health           # {"status":"ok"}
make ports.check                                # dolu port varsa hangisi olduğunu söyler
make db.psql <<< 'select version();'            # PostgreSQL 15.x

# .env.example ↔ kanonik liste karşılaştırması
grep -oE '^[A-Z_]+=' .env.example | tr -d '=' | sort > /tmp/env_example
grep -oE '^\| `[A-Z_]+`' docs/fazlar/00-genel-bakis.md | tr -d '|` ' | sort > /tmp/env_canon
diff /tmp/env_example /tmp/env_canon            # boş çıktı

# Hook testi
git init -q 2>/dev/null; make hooks
echo 'local x = ' > /tmp/bad.lua && cp /tmp/bad.lua api/src/bad.lua
git add api/src/bad.lua && git commit -m test   # reddedilmeli
git reset -q api/src/bad.lua && rm api/src/bad.lua
```

## Riskler / Dikkat Noktaları

- **Proje dizini henüz git reposu değil** → `make hooks` öncesi `git init` gerekir; README'de belirtilir.
- `argon2` rock'u `libargon2-dev` ister; Alpine'de paket adı doğrulanmalı (`argon2-dev` olabilir).
- Postgres volume'ü `make down` ile silinmez; şema değişikliği denemelerinde `make db.reset` kullanılmalı.
- Windows (WSL dışı) geliştiricilerde hook satır sonu (CRLF) sorunu → `.gitattributes`'a `*.sh text eol=lf` ve `.githooks/* text eol=lf` eklenir.
- Port çakışmaları (5432 yerel Postgres) → `.env`'den değiştirilebilir değil (compose'da sabit); gerekirse `docker-compose.override.yml` önerilir.

## Tahmini Efor

**S** — 0.5 gün.
