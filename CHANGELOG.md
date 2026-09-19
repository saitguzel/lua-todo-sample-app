# Değişiklik Günlüğü

Format: [Keep a Changelog](https://keepachangelog.com/tr/1.1.0/) · Sürümleme: [SemVer](https://semver.org/lang/tr/)

## [Unreleased]

### Fixed

- Migration runner ve `with_transaction`: pgmoon'un başarılı sorguda döndürdüğü ikinci değer (`num_queries`)
  hata sanılıyordu → hiçbir migration/transaction çalışmıyordu
- Argon2 encoded hash'in sonundaki NUL byte Postgres'e yazılamıyordu (seed/kullanıcı oluşturma)
- NULL sütunlar `["NULL"]` olarak serileşiyordu (`convert_null` kaldırıldı)
- Geçersiz JSON gövdesi 400 yerine 500 dönüyordu; prod'da `CORS_ORIGINS=*` reddedilmiyordu
- Shared validation: `datetime` sonek/ay-gün kontrolü, `user_list_query.is_active`, `user_update` kısmi güncelleme,
  `tags` sınırları (≤50 karakter, ≤20, tekrarsız)
- Prod imajı ve compose: kodsuz tek aşamalı imaj, `/app/conf` tmpfs'i, okunmayan secret'lar,
  çalıştırılamayan backup betikleri, `restore.sh` `PGPASSWORD` hatası

## [0.1.0] - 2026-09-18

### Added

- **Monorepo altyapı:** docker-compose (postgres, mailhog, api, web), Makefile, port çakışma kontrolü,
  luacheck pre-commit hook'u
- **Ortak kütüphane (`todo_shared`):** tipler/enum'lar + RBAC matrisi, şema tabanlı validation,
  protokol (error kodları, HTTP eşlemesi, yanıt zarfı)
- **Veritabanı:** 7 migration (users, todos, audit_logs, RBAC, password_reset, trigger'lar, cleanup_logs),
  seed'ler, pgmoon tabanlı migration runner (advisory lock'lu)
- **Backend core:** config doğrulama (`_FILE` secrets desteği), nginx/Lapis, middleware zinciri
  (cors → logger → audit_context → auth → authorization), pgmoon keepalive havuzu
- **Güvenlik:** Argon2id parola hash'i, JWT (HS256, `jti` + `typ`), denylist, login rate limit
- **Auth endpoint'leri:** login/logout/refresh/forgot-password/reset-password/me, SMTP (lua-resty-mail)
- **Todos CRUD + stats:** filtre/sıralama/sayfalama, optimistic akışlara uygun PATCH
- **Users + RBAC:** kullanıcı yönetimi, izin matrisi (kilitli hücreler, LAST_ADMIN/SELF_ACTION korumaları)
- **Audit log:** repo/handler, CSV export (UTF-8 BOM + formül enjeksiyonu kaçışı), maskeleme, istatistik
- **OpenAPI 3.1:** spec + Swagger UI + redocly lint + spec ↔ route tutarlılık testi
- **Zamanlanmış işler:** audit log temizliği (worker 0 + pg_advisory_lock, graceful shutdown)
- **Backend testleri:** busted birim/integration, wrk yük testi script'leri, CI pipeline
- **Frontend (Wasmoon Lua 5.4):** sanal DOM + keyed diff, reducer store, hash router (guard'lı),
  tek-uçuş token refresh; auth/todos/dashboard/profil ve admin (users, RBAC matrisi, audit) ekranları
- **UX:** toast/modal bileşenleri, açık/koyu/sistem tema, skeleton'lar, klavye kısayolları,
  confetti (reduced-motion duyarlı), WCAG AA odak hedefi
- **Frontend testleri:** busted birim (reducer/router/fetch/dom) + Playwright E2E (çoklu tarayıcı, a11y, mobil)
- **Deploy:** çok aşamalı api Dockerfile'ı (`dev` / `prod` target; prod non-root, ~56 MB sıkıştırılmış),
  prod compose (`*_FILE` secrets, `read_only` + tmpfs, 2 api replikası, TLS proxy, sabit proxy IP'si → `TRUSTED_PROXIES`,
  healthcheck), `deploy/deploy.sh` (yedek → migration → rolling api → duman testi, `--rollback`),
  `release.yml` (GHCR push + SBOM/provenance + Trivy + onaylı deploy), backup imajı (age şifreleme),
  günlük/haftalık/aylık rotasyon, restore tatbikatı (`deploy/backup/verify.sh`), liveness/readiness ayrımı,
  runbook + işaretli güvenlik kontrol listesi, `.env.prod.example`
