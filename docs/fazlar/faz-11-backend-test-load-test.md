# ═══ FAZ 11 — BACKEND TEST + LOAD TEST ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) — error kodları (§5), page key'ler (§7), audit olayları (§8), teknik düzeltme #2 (iki yorumlayıcı).

## 1. Amaç

Backend'in doğruluğunu üç katmanda güvenceye alan bir test ve performans altyapısı kurulur: (1) DB'siz **birim testleri** (security, validation, RBAC mantığı), (2) gerçek PostgreSQL ve çalışan OpenResty'ye karşı **entegrasyon testleri** (auth akışı, todo CRUD, admin kullanıcı yönetimi, audit), (3) **wrk** ile yük testleri. Hepsi GitHub Actions'ta her push/PR'da otomatik koşar.

Faz sonunda:
- `make test` → luacheck + birim + entegrasyon testleri yeşil.
- `make bench` → wrk raporları `api/bench/results/` altında; hedef eşikler README'de.
- `.github/workflows/ci.yml` → lint → unit → integration → spec lint aşamaları.

## 2. Önkoşullar

| Faz | Neden |
|---|---|
| F1 | `shared/spec/shared_spec.lua` zaten var; CI'da iki yorumlayıcıda koşar |
| F3–F10 | Test edilecek tüm backend kodu |
| F9 | `swagger.json` lint adımı |
| F0 | `docker-compose.yml`, Makefile, `.luacheckrc` |

## 3. Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/spec/security_spec.lua` | random, password, jwt birim testleri |
| `api/spec/validation_spec.lua` | Todo/user/auth şemaları (shared validation'ın API'deki kullanımı) |
| `api/spec/rbac_spec.lua` | `rbac_service.can`, cache, admin kilit kuralı, authorization middleware (mock'lu) |
| `api/spec/helpers/init.lua` | Ortak test yardımcıları: `ngx` stub, HTTP client, login helper, DB reset |
| `api/spec/integration/auth_flow_spec.lua` | Login → me → refresh → logout → revoked; forgot/reset; rate limit |
| `api/spec/integration/todos_crud_spec.lua` | CRUD, sahiplik, filtre/sayfalama, stats |
| `api/spec/integration/users_admin_spec.lua` | Admin user CRUD, son admin/self koruması, RBAC 403 |
| `api/spec/integration/audit_spec.lua` | Olayların yazılması, maskeleme, liste/detay/stats/CSV |
| `api/.busted` | busted profilleri: `unit`, `integration` |
| `api/bench/login.lua` | wrk script: POST /auth/login |
| `api/bench/todos_list.lua` | wrk script: GET /todos (token ile) |
| `api/bench/todos_mixed.lua` | wrk script: %70 okuma / %20 create / %10 patch |
| `api/bench/run.sh` | Token alır, wrk'leri sırayla koşturur, sonucu dosyaya yazar |
| `.github/workflows/ci.yml` | CI pipeline |
| `Makefile` (güncelleme) | `test`, `test.unit`, `test.integration`, `bench`, `lint` hedefleri |

## 4. Test Stratejisi

| Katman | Nerede koşar | DB | nginx | Hız | Kapsam |
|---|---|---|---|---|---|
| Unit (shared) | `lua5.1`/`luajit` + `lua5.4` | ❌ | ❌ | ms | types, validation, protocol |
| Unit (api) | `resty` + busted (`resty-busted` runner) | ❌ (repo mock) | ❌ (ngx API var) | ms | security, validation şemaları, rbac mantığı, log_cleanup.should_run |
| Integration | busted (host veya CI container) → HTTP → api container | ✅ gerçek PG | ✅ | sn | uçtan uca endpoint davranışı |
| Load | wrk → api container | ✅ | ✅ | dk | throughput / latency |

**Neden `resty` ile busted?** `security/*.lua` `resty.random`, `ngx.encode_base64`, `ngx.hmac_sha1` vb. kullanır; düz `luajit` altında yoktur. Runner:

```bash
# api/bin/busted (küçük sarmalayıcı)
#!/usr/bin/env resty
require("busted.runner")({ standalone = false })
```

`api/.busted`:

```lua
return {
  _all = { lpath = "src/?.lua;src/?/init.lua;../shared/src/?.lua;spec/?.lua" },
  unit = { ROOT = { "spec" }, exclude_pattern = "integration" },
  integration = { ROOT = { "spec/integration" } },
}
```

**Mock yaklaşımı** — ayrı mock kütüphanesi yok; busted'ın `stub`/`mock` + `package.loaded` değişimi yeterli:

```lua
-- Repo'yu sahte bir tabloyla değiştir
package.loaded["repositories.rbac_repo"] = {
  get_matrix_for_role = function(role) return { dashboard = true, ["todos.list"] = true } end,
}
package.loaded["services.rbac_service"] = nil
local rbac_service = require("services.rbac_service")
```

## 5. Birim Test Senaryoları

### 5.1 `api/spec/security_spec.lua`

**random**
- `uuid4()` 36 karakter, `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` desenine uyar.
- 10.000 üretimde çakışma yok.
- `token_hex(32)` 64 hex karakter; iki çağrı farklı.

**password**
- `hash("Admin123!")` → `$argon2id$v=19$m=4096,t=3,p=1$` ile başlar (`m_cost=12` → 4096 KiB).
- Aynı parola iki kez hash → farklı çıktı (random salt).
- `verify(hash, "Admin123!")` → true; `verify(hash, "admin123!")` → false.
- Bozuk hash string → `nil, err` (panik yok).
- Boş parola → `nil, "empty_password"`.

**jwt**
- `sign_access(user)` payload'unda `sub, user_id, email, role, iat, exp, jti, typ="access", iss` var; `exp - iat == JWT_ACCESS_TTL`.
- `sign_refresh` → `typ="refresh"`, `exp - iat == JWT_REFRESH_TTL`.
- `verify(token)` → payload; imza 1 byte değiştirilince → `UNAUTHORIZED`.
- `alg: none` header'lı sahte token → reddedilir.
- `alg: HS512` header → reddedilir (algoritma sabitlenmiş).
- Süresi geçmiş token (`ngx.time` stub'lanarak) → `TOKEN_EXPIRED`.
- Farklı `iss` → reddedilir.
- `verify_access(refresh_token)` → `UNAUTHORIZED` (typ uyuşmazlığı).

### 5.2 `api/spec/validation_spec.lua`

Todo create şeması:
| Girdi | Beklenen |
|---|---|
| `{ title = "Süt al" }` | ok, default `status=pending`, `priority=medium` |
| `{}` | `details.title = {"zorunlu alan"}` |
| `title` 256 karakter | uzunluk hatası |
| `status = "done"` | enum hatası |
| `priority = "urgent"` | enum hatası |
| `due_date = "2026-13-01"` | datetime hatası |
| `tags = { "a", 5 }` | `tags[2]` tip hatası |
| `tags` 21 eleman | max eleman hatası |
| `user_id` geçerli uuid | kabul edilir (opsiyonel alan); sahiplik kuralı service katmanında (F6 §`create`) |
| Bilinmeyen alan (ör. `owner`) | `VALIDATION_FAILED` (şemalar strict; mass-assignment koruması) |

PATCH şeması: tüm alanlar opsiyonel; en az bir alan zorunlu (`{}` → `VALIDATION_FAILED`).

User şeması: geçersiz email, `role = "root"`, zayıf parola (<8, harf+rakam yok) hataları.

Auth şemaları: login (email+password zorunlu), reset (token + new_password), forgot (email).

Türkçe karakterli başlık (`"Çalışma planı ğüşiöç"`) ok; uzunluk byte değil karakter bazlı (LuaJIT'te `utf8` yok → shared'daki kendi `utf8_len` fonksiyonu test edilir).

### 5.3 `api/spec/rbac_spec.lua`

- `can("admin", p)` her `PAGES` elemanı için true (default seed).
- `can("todouser", "users.list")` → false; `can("todouser", "todos.edit")` → true.
- Bilinmeyen page key → false (fail-closed).
- Bilinmeyen rol → false.
- Cache: ilk çağrı repo'ya gider, ikinci çağrı gitmez (stub çağrı sayısı = 1); TTL dolunca (dict stub'ında zaman ilerletilerek) tekrar gider.
- `update_matrix` sonrası cache invalidate edilir.
- `set_cell("admin", "rbac.matrix", false)` → `CONFLICT`.
- authorization middleware: izin yok → `403 FORBIDDEN` + `audit_service.record` stub'ı `access.denied` ile çağrıldı mı, `new_value.page_key` doğru mu.
- Identity yoksa (auth çalışmamış) → `401` (programlama hatasına karşı savunma).

### 5.4 Diğer birim testler (önceki fazlardan toplanır)

- `api/spec/log_cleanup_spec.lua` (F10) — `should_run`.
- `api/spec/audit_mask_spec.lua` (F8, varsa) — recursive maskeleme.
- `shared/spec/shared_spec.lua` (F1) — hem `luajit` hem `lua5.4`.

## 6. Entegrasyon Test Senaryoları

### 6.1 Altyapı: `api/spec/helpers/init.lua`

```lua
local http = require("socket.http")   -- ponytail: luasocket; resty dışı ortamda çalışsın diye
local ltn12 = require("ltn12")
local cjson = require("cjson")

local _M = { base = os.getenv("API_URL") or "http://localhost:28080/api/v1" }

-- JSON istek at, { status, body, headers } döndür
function _M.request(method, path, body, token) end

-- Seed kullanıcısıyla login, access + refresh döndür
function _M.login(email, password) end
function _M.login_admin() return _M.login("admin@todoapp.local", "Admin123!") end
function _M.login_user()  return _M.login("user@todoapp.local",  "User123!")  end

-- Test izolasyonu: todos/audit/reset tablolarını TRUNCATE, seed kullanıcıları dışındaki user'ları sil
function _M.reset_db() end   -- psql ile: docker compose exec -T postgres psql ...

-- Rate limit sayaçlarını sıfırla (test ortamında) — özel endpoint YOK, API restart yerine
-- her testte farklı X-Forwarded-For IP'si kullanılır (TRUSTED_PROXIES test ortamında 0.0.0.0/0)
function _M.unique_ip() end

return _M
```

Test ortamı `APP_ENV=test`, `SEED_DEFAULTS=true`, `SMTP_HOST=mailhog` → e-postalar MailHog API'sinden (`GET http://mailhog:8025/api/v2/messages`) okunur.

### 6.2 `auth_flow_spec.lua`

1. **Başarılı login**: 200, `data.access_token`, `data.refresh_token`, `data.user.email`, `password_hash` yanıtta **yok**.
2. **Yanlış parola** → 401 `INVALID_CREDENTIALS`; **olmayan email** → aynı kod ve aynı mesaj (numaralandırma yok).
3. **Pasif kullanıcı** → 403 `ACCOUNT_DISABLED`.
4. **Rate limit**: aynı IP+email ile 6. deneme → 429 `RATE_LIMITED` + `Retry-After` header.
5. **`/auth/me`**: token ile 200; tokensız 401 `UNAUTHORIZED`; bozuk token 401.
6. **Refresh rotasyonu**: `/auth/refresh` yeni çift döner; **eski refresh token tekrar kullanılırsa** 401 `TOKEN_REVOKED`.
7. **Access token ile refresh denemesi** → 401.
8. **Logout**: 204; sonra aynı access token ile `/auth/me` → 401 `TOKEN_REVOKED`; refresh de reddedilir.
9. **Forgot password (var olan email)** → 202; MailHog'da 1 mesaj, içinde `WEB_BASE_URL/#/reset-password?token=`.
10. **Forgot password (olmayan email)** → 202, MailHog'da mesaj yok, yanıt süresi farkı < 200 ms (kaba zamanlama kontrolü).
11. **Reset password**: e-postadaki token ile yeni parola → 200; eski parola ile login 401, yeni ile 200.
12. **Aynı reset token ikinci kez** → 400 `RESET_TOKEN_INVALID`.
13. **Süresi dolmuş reset token** (DB'de `expires_at` geçmişe çekilerek) → 400.
14. **Last login**: login sonrası `users.last_login_at` güncellenmiş.
15. **Audit**: `auth.login.success`, `auth.login.failure`, `auth.logout`, `auth.token.refresh`, `auth.password.reset.request`, `auth.password.reset.success` satırları oluştu.

### 6.3 `todos_crud_spec.lua`

1. user olarak `POST /todos` → 201, `user_id` = kendi id'si; body'de **başkasının** `user_id`'si gönderilirse
   `403 FORBIDDEN` (F6 `create` akışı). admin başka kullanıcı adına oluşturabilir; olmayan `user_id` → `404 USER_NOT_FOUND`.
2. `GET /todos/:id` kendi todo'su → 200.
3. **Başkasının todo'su** (admin'in oluşturduğu) user için → 404 `TODO_NOT_FOUND` (403 değil).
4. Admin `GET /todos` → herkesin todo'ları; user → yalnızca kendi.
5. Filtreler: `?status=completed`, `?priority=high`, `?tag=work`, `?q=süt`, `?due_before=...`.
6. Sayfalama: 45 todo, `?per_page=20&page=3` → 5 eleman, `meta.total=45`, `meta.total_pages=3`.
7. `per_page=500` → 422 veya 100'e kırpma (F6 kararına göre) — test F6 dokümanındaki davranışı doğrular.
8. Sıralama: `?sort=-due_date`; whitelist dışı `?sort=password_hash` → 422.
9. **PUT** yalnızca `title` ile → 200 ve eksik alanlar varsayılana döner (`status=pending`, `priority=medium`,
   `description`/`due_date` NULL, `tags={}` — F6 PUT/PATCH semantiği); `title` olmadan PUT → 422.
   **PATCH** tek alan → 200, diğerleri değişmedi.
10. `status → completed` → `completed_at` dolu; `completed → pending` → `completed_at = null`.
11. `DELETE` → 204; tekrar `GET` → 404; başkasınınkini silme → 404.
12. Geçersiz UUID `/todos/abc` → 404 (veya 400, F6 kararı) — 500 **değil**.
13. `/todos/stats` → `{ total, by_status, by_priority, overdue }`, user için yalnızca kendi verisi.
14. SQL injection denemeleri: `?q='; DROP TABLE todos; --`, `?status=pending' OR '1'='1` → 422 veya boş sonuç; tablo sağlam.
15. 1 MiB üstü body → 413 `PAYLOAD_TOO_LARGE`.
16. Bozuk JSON → 400 `BAD_REQUEST`.
17. `updated_at` trigger: PATCH sonrası `updated_at > created_at`.

### 6.4 `users_admin_spec.lua`

1. user rolü `GET /users` → 403 `FORBIDDEN` + `access.denied` audit.
2. admin `POST /users` → 201; yanıtta `password_hash` yok; DB'de hash `$argon2id$` ile başlıyor.
3. Aynı email → 409 `EMAIL_TAKEN` (büyük/küçük harf farklı olsa da).
4. `PUT /users/:id` rol değişimi; `is_active=false` → o kullanıcı login olamaz.
5. Admin kendini silme → 409 `SELF_ACTION_FORBIDDEN`; kendi rolünü `todouser` yapma → 409.
6. Son admin'i silme/düşürme (ikinci admin yokken) → 409 `LAST_ADMIN`.
7. Kullanıcı silinince todo'ları CASCADE silinir; audit kayıtlarında `user_id` NULL, `user_email` korunur.
8. `GET /users?q=user&role=todouser&page=1` filtreleri.
9. RBAC: `PATCH /rbac/matrix/todouser/users.list` true → user artık `GET /users` 200 alır (cache invalidate doğrulaması, 60 sn beklemeden).
10. `PATCH /rbac/matrix/admin/rbac.matrix` false → 409 `CONFLICT`.
11. `GET /rbac/pages` → `PAGES` listesi; `GET /rbac/matrix` → 2×9 matris.

### 6.5 `audit_spec.lua`

1. Todo create/update/delete sonrası `GET /audit/logs?entity_type=todo` 3 kayıt, doğru `action`, `old_value`/`new_value`.
2. User create kaydında `new_value.password_hash == "***"`; reset akışında token alanları `"***"`.
3. `ip_address` ve `user_agent` dolu (test `User-Agent: busted-it` gönderir).
4. Filtreler: `?action=auth.login.failure`, `?user_id=`, `?from=&to=`, `?status=failure`.
5. `GET /audit/logs/:id` detay; olmayan id → 404.
6. `GET /audit/stats` → action bazlı sayımlar, son 24 saat/7 gün.
7. `GET /audit/export` → `Content-Type: text/csv`, `Content-Disposition: attachment`, başlık satırı doğru; `=cmd|...` ile başlayan değer `'=` ile kaçırılmış (CSV injection).
8. user rolü `/audit/*` → 403.

## 7. Yük Testi (wrk)

### 7.1 Script'ler

`api/bench/login.lua`:

```lua
-- Login endpoint'ine sabit gövdeyle POST
wrk.method = "POST"
wrk.path   = "/api/v1/auth/login"
wrk.headers["Content-Type"] = "application/json"
wrk.body   = '{"email":"user@todoapp.local","password":"User123!"}'

-- Rate limit'e takılmamak için her istekte farklı sahte IP (TRUSTED_PROXIES bench ortamında açık)
local counter = 0
request = function()
  counter = counter + 1
  wrk.headers["X-Forwarded-For"] = "10.0." .. (counter % 250) .. "." .. (counter % 200 + 1)
  return wrk.format()
end
```

`api/bench/todos_list.lua`:

```lua
-- TOKEN ortam değişkeninden okunur (run.sh üretir)
local token = os.getenv("TOKEN")
wrk.headers["Authorization"] = "Bearer " .. token
wrk.path = "/api/v1/todos?per_page=20"

local statuses = {}
response = function(status) statuses[status] = (statuses[status] or 0) + 1 end
done = function()
  for s, n in pairs(statuses) do io.write(string.format("status %d: %d\n", s, n)) end
end
```

`api/bench/todos_mixed.lua`: `request()` içinde `math.random(100)` ile %70 `GET /todos`, %20 `POST /todos`, %10 `PATCH /todos/<id>` (id'ler `init` fazında `setup` ile oluşturulmuş listeden).

`api/bench/run.sh`:

```bash
#!/usr/bin/env bash
# Token al, her senaryoyu koştur, sonuçları tarihli dosyaya yaz
set -euo pipefail
BASE=${BASE:-http://localhost:28080}
OUT=api/bench/results/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$OUT"
TOKEN=$(curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"user@todoapp.local","password":"User123!"}' | jq -r .data.access_token)
export TOKEN
wrk -t4 -c50  -d30s --latency -s api/bench/login.lua      "$BASE" | tee "$OUT/login.txt"
wrk -t4 -c100 -d30s --latency -s api/bench/todos_list.lua "$BASE" | tee "$OUT/todos_list.txt"
wrk -t4 -c100 -d60s --latency -s api/bench/todos_mixed.lua "$BASE" | tee "$OUT/todos_mixed.txt"
wrk -t2 -c50  -d15s --latency "$BASE/api/v1/health"                | tee "$OUT/health.txt"
```

### 7.2 Hedef Eşikler (4 vCPU, `worker_processes auto`, yerel PG)

| Senaryo | Hedef RPS | p99 | Hata oranı | Not |
|---|---|---|---|---|
| `/health` | ≥ 10.000 | < 10 ms | 0 | DB ping dahil |
| `GET /todos` (20 kayıt) | ≥ 3.000 | < 50 ms | 0 | |
| mixed | ≥ 1.500 | < 100 ms | 0 | |
| `/auth/login` | ≥ 100 | < 300 ms | 0 | Argon2 CPU sınırlı; bu **beklenen** darboğaz |

Eşikler ilk ölçümden sonra README'de gerçek değerlerle güncellenir; CI'da yük testi **koşmaz** (gürültülü runner), yalnızca `workflow_dispatch` ile manuel.

### 7.3 Profilleme İpuçları

- Yük altında `docker stats` → DB bağlantı sayısı `worker_processes × DB_POOL_SIZE` aşmamalı.
- `SELECT count(*) FROM pg_stat_activity WHERE datname='todo'` ile havuz doğrulaması.
- Yavaşlıkta `LOG_LEVEL=debug` yerine OpenResty `stapxx`/`orbit` flame graph (README'ye link, kurulum bu fazda değil).

## 8. CI Pipeline — `.github/workflows/ci.yml`

```yaml
name: ci
on:
  push: { branches: [main] }
  pull_request:
  workflow_dispatch:
    inputs:
      bench: { type: boolean, default: false, description: "Yük testini de koş" }

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: leafo/gh-actions-lua@v10
        with: { luaVersion: "luajit-openresty" }
      - uses: leafo/gh-actions-luarocks@v4
      - run: luarocks install luacheck
      - run: luacheck api/src shared/src web/src api/spec shared/spec

  shared-unit:
    runs-on: ubuntu-latest
    strategy:
      matrix: { lua: ["luajit-openresty", "5.4"] }   # teknik düzeltme #2
    steps:
      - uses: actions/checkout@v4
      - uses: leafo/gh-actions-lua@v10
        with: { luaVersion: "${{ matrix.lua }}" }
      - uses: leafo/gh-actions-luarocks@v4
      - run: luarocks install busted
      - run: busted shared/spec

  api-unit:
    runs-on: ubuntu-latest
    container: openresty/openresty:1.25.3.2-jammy
    steps:
      - uses: actions/checkout@v4
      - run: apt-get update && apt-get install -y build-essential libargon2-dev git
      - run: luarocks install busted && luarocks install lua-resty-jwt && luarocks install argon2 && luarocks install pgmoon
      - run: cd api && ./bin/busted --run=unit

  integration:
    runs-on: ubuntu-latest
    needs: [lint, shared-unit, api-unit]
    steps:
      - uses: actions/checkout@v4
      - run: cp .env.example .env && echo "APP_ENV=test" >> .env && echo "SEED_DEFAULTS=true" >> .env
      - run: docker compose up -d --build --wait postgres mailhog api
      - run: make db.migrate db.seed
      - uses: leafo/gh-actions-lua@v10
        with: { luaVersion: "5.1" }
      - uses: leafo/gh-actions-luarocks@v4
      - run: luarocks install busted && luarocks install luasocket && luarocks install lua-cjson
      - run: cd api && API_URL=http://localhost:28080/api/v1 busted --run=integration
      - if: failure()
        run: docker compose logs api postgres

  spec-lint:
    runs-on: ubuntu-latest
    needs: integration
    steps:
      - uses: actions/checkout@v4
      - run: docker compose up -d --build --wait postgres api
      - run: curl -sf http://localhost:28080/api/v1/swagger.json -o swagger.json
      - run: npx --yes @redocly/cli@latest lint swagger.json   # teknik düzeltme #10

  bench:
    if: github.event_name == 'workflow_dispatch' && inputs.bench
    runs-on: ubuntu-latest
    needs: integration
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y wrk jq
      - run: docker compose up -d --build --wait && make db.migrate db.seed
      - run: bash api/bench/run.sh
      - uses: actions/upload-artifact@v4
        with: { name: bench-results, path: api/bench/results }
```

Not: Docker Compose'ta `mailhog` servisi F0'da tanımlı değilse bu fazda `docker-compose.yml`'e eklenir (dev/test için; `SMTP_HOST=mailhog` default'u zaten 00-genel-bakis §6'da).

## 9. Makefile Hedefleri

```make
lint:              ; luacheck api/src shared/src web/src api/spec shared/spec
test.unit:         ; busted shared/spec && cd api && ./bin/busted --run=unit
test.integration:  ; cd api && busted --run=integration
test: lint test.unit test.integration
bench:             ; bash api/bench/run.sh
```

## 10. Teknik Kararlar

| Karar | Neden |
|---|---|
| busted (prompt) + `resty` runner | ngx API'lerine bağlı modüller gerçek ortamda test edilir; mock'lanmış `ngx` yerine gerçek LuaJIT + OpenResty |
| Entegrasyon testi HTTP üzerinden, container dışından | Gerçek nginx konfigürasyonunu (CORS, body limit, route) da test eder; test kodu uygulamayla aynı süreçte değil |
| DB reset `TRUNCATE` + seed kullanıcıları korunur | Her spec dosyası bağımsız; migration tekrar koşmaz (hızlı) |
| Rate limit testleri için farklı IP | Test-only bypass endpoint'i açmamak için (güvenlik yüzeyi) |
| Coverage aracı yok | luacov OpenResty altında sınırlı; kritik yollar senaryo listesiyle kapsanır. Gerekirse `luacov` + `resty` ile eklenir |
| wrk CI'da varsayılan kapalı | Paylaşımlı runner'da ölçüm anlamsız ve flaky |

## Kabul kriterleri (DoD)

- [ ] `make lint` sıfır uyarı.
- [ ] `busted shared/spec` hem `luajit` hem `lua5.4` altında yeşil.
- [ ] `security_spec`, `validation_spec`, `rbac_spec` yukarıdaki tüm senaryoları içerir ve yeşil.
- [ ] 4 entegrasyon spec dosyası yeşil; her biri `reset_db` ile bağımsız koşabilir (`busted spec/integration/audit_spec.lua` tek başına geçer).
- [ ] 00-genel-bakis §5'teki her error kodu en az bir testte assert edilir (`MAIL_FAILED`, `DB_UNAVAILABLE`, `INTERNAL_ERROR` hariç — bunlar birim testte hata enjeksiyonuyla).
- [ ] 00-genel-bakis §8'deki her audit olayı en az bir entegrasyon testinde doğrulanır.
- [ ] `make bench` 4 senaryoyu koşturur, sonuç dosyaları oluşur, hata oranı %0.
- [ ] CI'da lint → unit → integration → spec-lint aşamaları bir PR üzerinde yeşil görülür.
- [ ] Başarısız entegrasyon testinde CI container loglarını basar.

## 12. Doğrulama

```bash
make lint
busted shared/spec                       # sistemdeki lua ile
docker run --rm -v $PWD:/w -w /w nickblah/lua:5.4-luarocks sh -c 'luarocks install busted && busted shared/spec'
make test.unit
docker compose up -d && make db.migrate db.seed
make test.integration
make bench && ls api/bench/results/*/
npx @redocly/cli lint http://localhost:28080/api/v1/swagger.json
# CI: bir branch aç, push et, Actions sekmesinde 5 job'u izle
```

## 13. Riskler

| Risk | Önlem |
|---|---|
| Entegrasyon testleri sıraya bağımlı hale gelir | Her `describe` başında `reset_db`; paylaşılan global değişken yok |
| Argon2 derleme bağımlılığı CI'da kırılır | `libargon2-dev` açıkça kurulur; Dockerfile ile aynı sürüm |
| Rate limit testleri flaky (shared dict TTL) | Her testte benzersiz IP; zaman bağımlı assert yok |
| MailHog asenkron teslimat | Mesaj okuma helper'ı 2 sn'ye kadar 100 ms aralıkla poll eder |
| Zamanlama testi (forgot email farkı) gürültülü | Eşik geniş (200 ms), CI'da `pending` olarak işaretlenebilir |
| Test verisi prod'a sızması | `reset_db` yalnızca `APP_ENV=test` iken çalışır, aksi halde `error()` |

## 14. Tahmini Efor

**L** — ~3 gün (birim testler 0.5, entegrasyon 1.5, wrk + eşik ölçümü 0.5, CI 0.5).
