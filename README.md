# todo-lua

OpenResty/Lapis API + Wasmoon (Lua 5.4/WASM) frontend + ortak Lua kütüphanesinden oluşan RBAC'li Todo uygulaması.

## Mimari

| Bileşen | Teknoloji | Sorumluluk |
|---|---|---|
| `todo-api` | OpenResty 1.25+ / LuaJIT / Lapis / pgmoon | REST API, auth, RBAC, audit, zamanlanmış işler, Swagger |
| `todo-web` | Lua 5.4 (Wasmoon, WASM) + ince JS glue | SPA: kendi render motoru, reducer state, hash router |
| `todo-shared` | Saf Lua (5.1 ∩ 5.4 ortak alt kümesi) | Tipler/enum'lar, validation, protokol |

Ayrıntılı mimari diyagramı ve katman kuralları: [00-genel-bakis](docs/fazlar/00-genel-bakis.md).

## Dizin yapısı

```
api/            OpenResty + Lapis backend
  conf/         nginx.conf, lua.conf, env.conf
  src/          handlers → services → repositories → db (katman kuralları: 00 §4)
  migrations/   001…007 (kendi runner'ımız: src/db/migrations.lua)
  seeds/        rbac_defaults, default_users
  spec/         busted birim + integration/
  bench/        wrk senaryoları
shared/src/     todo_shared.{types,validation,protocol} — backend ve frontend aynı kod
web/            Wasmoon (Lua 5.4) SPA: src/ (views, components), js/glue.js, public/, e2e/
deploy/         prod: proxy/ (TLS nginx), web/ (statik nginx), backup/ (dump/restore/tatbikat), deploy.sh
docs/           fazlar/ (spesifikasyon), operations.md (runbook), security-checklist.md
```

> Repo git ile başlatılmadıysa: `git init && make setup` (pre-commit hook `core.hooksPath` ister).

## Gereksinimler

- Docker 24+, Docker Compose v2, GNU Make, git
- (opsiyonel yerel) LuaRocks + luacheck + busted, Node 20+

## Hızlı başlangıç

```bash
make setup && make up && make db.migrate db.seed
# API:     http://localhost:28080/api/v1/health
# Web:     http://localhost:28000
# Swagger: http://localhost:28080/api/v1/swagger
# MailHog: http://localhost:28025
```

Varsayılan kullanıcılar (yalnızca `SEED_DEFAULTS=true`, geliştirme):

- `admin@todoapp.local / Admin123!`
- `user@todoapp.local / User123!`

## Make komutları

| Hedef | Açıklama |
|---|---|
| `make up` / `make down` | Tüm servisleri ayağa kaldır / durdur |
| `make logs` | API logları |
| `make db.migrate` / `db.rollback` / `db.status` | Migration uygula / geri al / durum |
| `make db.seed` / `db.reset` | Seed verisi / DB sıfırla + migrate + seed |
| `make db.psql` | psql kabuğu |
| `make lint` | luacheck (api, shared, web) |
| `make test` | Tüm testler (shared + api + web) |
| `make test.integration` | Integration testleri (API çalışırken) |
| `make web.build` / `web.dev` | Frontend bundle / dev sunucu |
| `make web.test` / `web.e2e` | Frontend birim testleri / Playwright E2E |
| `make bench` | wrk yük testi |
| `make spec.lint` | OpenAPI redocly lint |
| `make job.cleanup` | Log temizlik job'unu elle koştur |
| `make backup.verify` | Backup doğrulama (F18) |

## Ortam değişkenleri

Kanonik liste: [00-genel-bakis §6](docs/fazlar/00-genel-bakis.md). `.env.example` bu listeyle birebir aynıdır.
Gizli değerler `_FILE` varyantıyla Docker secrets'tan okunabilir (`DB_PASSWORD_FILE`, `JWT_SECRET_FILE`, `SMTP_PASSWORD_FILE`).

## API dokümantasyonu

Swagger UI: `/api/v1/swagger` · OpenAPI 3.1 JSON: `/api/v1/swagger.json`

Sağlık uçları: `GET /api/v1/health` (liveness), `GET /api/v1/health/ready` (readiness, DB), `GET /api/v1/metrics` (Prometheus; prod'da dışarıya kapalı).

## Production

```bash
cp .env.prod.example .env.prod && chmod 600 .env.prod     # TAG, GHCR_OWNER, domain, SMTP
mkdir -p secrets && openssl rand -hex 24 > secrets/db_password \
  && openssl rand -base64 48 > secrets/jwt_secret && printf '%s' '<smtp>' > secrets/smtp_password
C="docker compose --env-file .env.prod -f docker-compose.prod.yml"
$C build backup && $C up -d --wait
$C run --rm --no-deps api resty -I /app/src -I /app/lib /app/src/db/migrations.lua up
```

Sonraki sürümler: `TAG=vX.Y.Z sh deploy/deploy.sh` (yedek → migration → api → web/proxy → duman testi);
tag push'unda `release.yml` imajları GHCR'a iter, Trivy tarar, onaydan sonra bunu çağırır.
Deploy/rollback/yedek/sertifika: [docs/operations.md](docs/operations.md) ·
Canlıya çıkış kontrol listesi: [docs/security-checklist.md](docs/security-checklist.md)

### Kapasite notları

- **DB bağlantı bütçesi:** havuz worker başınadır (00 §11 #5):
  `api replikası × worker_processes × DB_POOL_SIZE ≤ max_connections − 10`.
  Örn. 2 × 2 × 20 = 80 ≤ 90 (prod compose `max_connections=100`). `worker_processes auto` çekirdek sayısını alır;
  CPU limiti düşükse sabitleyin.
- **Argon2id maliyeti:** `m_cost=12` (4 MiB) ile ~16.6 ms/hash ölçüldü; hash worker'ı bloklar. OWASP minimumu
  19 MiB ≈ `ARGON2_M_COST=15` (32 MiB) — prod örneği bunu kullanır; süre ve bellek ~8× artar.
  Eşzamanlı login × 32 MiB RAM'e sığmalı; login rate limit bu yüzden zorunlu.
- **VACUUM:** log cleanup her gün binlerce `audit_logs` satırı siler. Autovacuum açık kalmalı; büyük ilk temizlikten
  sonra `VACUUM (ANALYZE) audit_logs;` elle koşun. Disk geri kazanımı gerekiyorsa bakım penceresinde
  `VACUUM FULL audit_logs` (tabloyu kilitler).

## Tarayıcı desteği

Evergreen tarayıcılar; Safari 15.4+ (`<dialog>`, `wasm-unsafe-eval`). JavaScript ve WebAssembly zorunludur.

## Test

```bash
make lint && make test            # luacheck + shared/api/web birim
make test.integration             # API çalışırken
make up.e2e && make web.e2e       # Playwright (chromium/firefox/webkit/mobil)
make bench                        # wrk
```

### Yük testi eşikleri

| Senaryo | Hedef RPS | p99 | Hata oranı | Not |
|---|---|---|---|---|
| `/health` | ≥ 10.000 | < 10 ms | 0 | liveness |
| `GET /todos` (20 kayıt) | ≥ 3.000 | < 50 ms | 0 | |
| mixed (%70 GET / %20 POST / %10 PATCH) | ≥ 1.500 | < 100 ms | 0 | |
| `/auth/login` | ≥ 100 | < 300 ms | 0 | Argon2 CPU sınırlı, beklenen darboğaz |

4 vCPU, `worker_processes auto`, yerel PG varsayımıyla. İlk `make bench` ölçümünden sonra gerçek değerlerle
güncellenir; CI'da yalnızca `workflow_dispatch` + `bench=true` ile koşar.

## Güvenlik

Açıkları herkese açık issue olarak bildirmeyin; GitHub Security Advisory kullanın.
Kontrol listesi: [docs/security-checklist.md](docs/security-checklist.md)

## Lisans

MIT
