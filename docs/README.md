# todo-lua — Plan Dokümantasyonu

Bu klasör, OpenResty/Lapis API + Wasmoon (Lua 5.4/WASM) frontend + ortak Lua kütüphanesinden oluşan
**todo-lua** monoreposunun uygulama planını içerir. Kod henüz yazılmadı; her faz, ilgili dokümandaki
**Kabul kriterleri (DoD)** tamamlandığında kapanır ve bir sonraki faza geçilir.

## Nasıl okunur

1. Önce **[00 — Genel Bakış](fazlar/00-genel-bakis.md)**: mimari, katman kuralları ve tüm fazların uyduğu
   kanonik listeler (error kodları, env değişkenleri, audit olayları, RBAC sayfaları, shared dict'ler)
   ile orijinal prompt'taki teknik düzeltmeler (§11).
2. Sonra fazları sırayla uygula. Her faz dokümanı aynı şablonu izler:
   Amaç → Önkoşullar → Çıktılar → Dosya bazlı tasarım → Teknik kararlar → Kabul kriterleri (DoD) → Doğrulama → Riskler → Efor.

## Faz İndeksi

| Faz | Doküman | Kapsam |
|---|---|---|
| — | [00-genel-bakis](fazlar/00-genel-bakis.md) | Mimari, sözleşmeler, teknik düzeltmeler |
| 0 | [faz-00-monorepo-altyapi](fazlar/faz-00-monorepo-altyapi.md) | Dizin yapısı, docker-compose, `.env.example`, Makefile, git hooks |
| 1 | [faz-01-shared-kutuphane](fazlar/faz-01-shared-kutuphane.md) | `types`, `validation`, `protocol`, rockspec |
| 2 | [faz-02-veritabani-migration](fazlar/faz-02-veritabani-migration.md) | 7 migration, seed'ler, pool |
| 3 | [faz-03-backend-core](fazlar/faz-03-backend-core.md) | config, nginx, Lapis app, router, query, error/cors/logger, `/health` |
| 4 | [faz-04-security](fazlar/faz-04-security.md) | UUID, Argon2id, JWT, user/audit modelleri |
| 5 | [faz-05-auth-endpointleri](fazlar/faz-05-auth-endpointleri.md) | login/logout/refresh/forgot/reset/me, SMTP |
| 6 | [faz-06-todos-crud-stats](fazlar/faz-06-todos-crud-stats.md) | Todo CRUD, filtre/sayfalama, stats |
| 7 | [faz-07-users-rbac](fazlar/faz-07-users-rbac.md) | Kullanıcı yönetimi, RBAC matrisi, authorization |
| 8 | [faz-08-audit-log-middleware](fazlar/faz-08-audit-log-middleware.md) | Audit repo/handler, CSV export, maskeleme |
| 9 | [faz-09-swagger-openapi](fazlar/faz-09-swagger-openapi.md) | OpenAPI 3.1 spec, Swagger UI, lint |
| 10 | [faz-10-scheduled-jobs](fazlar/faz-10-scheduled-jobs.md) | Audit log temizliği, graceful shutdown |
| 11 | [faz-11-backend-test-load-test](fazlar/faz-11-backend-test-load-test.md) | busted unit/integration, wrk, CI |
| 12 | [faz-12-frontend-iskelet](fazlar/faz-12-frontend-iskelet.md) | Wasmoon yükleyici, glue.js, index.html |
| 13 | [faz-13-frontend-core](fazlar/faz-13-frontend-core.md) | dom, fetch, storage, store/reducer, router |
| 14 | [faz-14-frontend-views-auth-todos](fazlar/faz-14-frontend-views-auth-todos.md) | Auth ekranları, dashboard, todos, profil |
| 15 | [faz-15-frontend-views-admin](fazlar/faz-15-frontend-views-admin.md) | Kullanıcılar, RBAC matrisi, audit log ekranları |
| 16 | [faz-16-frontend-ux-polish](fazlar/faz-16-frontend-ux-polish.md) | Toast, modal, tema, skeleton, klavye, a11y |
| 17 | [faz-17-frontend-test-wasm-opt](fazlar/faz-17-frontend-test-wasm-opt.md) | Web testleri, Playwright E2E, yük optimizasyonu |
| 18 | [faz-18-deployment-dokumantasyon](fazlar/faz-18-deployment-dokumantasyon.md) | Docker prod, CI/CD, monitoring, backup, güvenlik |

## Bağımlılık Grafiği

```
F0 ─► F1 ─► F2 ─► F3 ─► F4 ─► F5 ─► F6 ─► F7 ─► F8 ─► F9 ─► F10 ─► F11 ──┐
                                 │                                         ├─► F18
                                 └─► F12 ─► F13 ─► F14 ─► F15 ─► F16 ─► F17 ┘
```

Frontend hattı (F12+) auth API'si (F5) hazır olunca backend ile paralel ilerleyebilir.

## Yerel Portlar

Geliştirme makinesinde 80/443, 3000 ve 8080 başka projelerde dolu olduğundan host portları 28xxx bloğundan seçildi
(ayrıntı: [00-genel-bakis §6.1](fazlar/00-genel-bakis.md#61-host-port-eşlemeleri-yalnızca-docker-compose)).
`make up` önce `make ports.check` çalıştırır; çakışma varsa `.env` içinden değiştirilir.

| Servis | Adres | Env |
|---|---|---|
| API + Swagger | http://localhost:28080/api/v1 · `/api/v1/swagger` | `API_HOST_PORT` |
| Web | http://localhost:28000 | `WEB_HOST_PORT` |
| PostgreSQL | `127.0.0.1:25432` | `DB_HOST_PORT` |
| MailHog UI | http://127.0.0.1:28025 | `MAILHOG_UI_HOST_PORT` |

## Prompt ağacına eklenen dosyalar

Orijinal dizin ağacında olmayan, fazlarda gerekçesiyle eklenen dosyalar:

| Yol | Faz | Neden |
|---|---|---|
| `.editorconfig`, `.luacheckrc`, `.githooks/pre-commit` | F0 | Kod stili, lint, luacheck pre-commit hook'u |
| `api/bench/` | F0, F11 | wrk yük testi script'leri |
| `redocly.yaml`, `api/spec/openapi_spec.lua` | F9 | OpenAPI 3.1 lint kuralları + spec ↔ route tutarlılık testi |
| `.github/workflows/` | F11, F17, F18 | CI/CD |
| `web/js/boot.js`, `web/public/bundle.*.json` | F12 | Tema flaş önleme; paketlenmiş Lua kaynakları (build çıktısı) |
| `web/src/json.lua` | F13 | `js.json` sarmalayıcısı + `null` sentinel |
| `web/spec/` | F13, F17 | Frontend busted testleri |
| `web/src/shortcuts.lua` | F16 | Klavye kısayolu kaydı |
| `web/e2e/` | F17 | Playwright senaryoları |
| `deploy/`, `docs/operations.md`, `docs/security-checklist.md` | F18 | Prod nginx/TLS, işletim runbook'u, güvenlik kontrol listesi |

Ek endpoint: `GET /api/v1/health/ready` (readiness, F18).

## Orijinal prompt'tan önemli sapmalar (özet)

Ayrıntı ve gerekçe: [00-genel-bakis §11](fazlar/00-genel-bakis.md#11-teknik-düzeltmeler-promptaki-sorunlar-ve-karar).

- Wasmoon hazır Lua 5.4 WASM VM'i getirir → Emscripten derlemesi yok.
- Shared kod LuaJIT (5.1) ve Lua 5.4 ortak alt kümesinde yazılır.
- SMTP için `lua-resty-http` değil `lua-resty-mail`; Argon2 için LuaRocks `argon2`.
- Gerçek bind parametresi için DB erişimi Lapis `db.query` yerine pgmoon `$1` sorgularıyla.
- Middleware sırası: `cors → logger → audit_context → auth → authorization → handler`.
- JWT'ye `jti` + `typ` eklenir (logout/refresh iptali için).
- `swagger-cli` yerine `@redocly/cli lint`.
