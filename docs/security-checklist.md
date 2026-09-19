# Güvenlik Kontrol Listesi

Canlıya çıkıştan önce ve her minor sürümde gözden geçirilir. Kaynak: [faz-18](fazlar/faz-18-deployment-dokumantasyon.md) §8.

İşaretler: `[x]` doğrulandı (kanıt yanında) · `[ ]` açık (sahibi/nedeni yanında) · **İstisna** = bilinçli, gerekçeli.
Son gözden geçirme: 2026-09-19 (v0.1.0 öncesi, staging denemesi `todo-prod-test`).

## Kimlik doğrulama ve oturum

- [x] `JWT_SECRET` ≥ 32 byte rastgele (`openssl rand -base64 48`), Docker secrets dosyasında (`JWT_SECRET_FILE`), repoda yok
      (`secrets/` `.gitignore`'da; prod'da `.env.example` değeri `config.lua` tarafından reddedilir).
- [x] Access TTL 900 sn, refresh TTL 604800 sn (`.env.prod.example`); refresh rotasyonu + denylist kodda (F5).
      Canlı rotasyon testi F11 integration kapsamında — açık.
- [x] JWT `alg` sabit HS256; `none`, HS512, farklı secret, yanlış `iss` reddediliyor (F4 denetimi, resty betiği).
- [x] Login rate limit aktif (5/dk → 429 + `Retry-After`, canlı doğrulandı); proxy'de `limit_req` 20r/s burst 40.
- [x] Hatalı giriş mesajı e-posta varlığını ifşa etmiyor (`INVALID_CREDENTIALS` + dummy verify); forgot-password 202.
- [ ] Reset token: SHA-256 hash saklanıyor, tek kullanımlık — `with_transaction` hatası düzeltildi; canlı akış
      (kullanım + süre dolumu) F11 integration testiyle doğrulanacak.
- [x] Argon2id: `.env.prod.example` `ARGON2_M_COST=15` (32 MiB, OWASP üstü). Ölçüm m=12: ~16.6 ms/hash;
      m=15 ≈ 8× bellek/süre → sunucu RAM'i × eşzamanlı login'e göre ayarlayın (README).
- [x] `SEED_DEFAULTS=false` prod'da (`.env.prod.example`); ilk admin tek seferlik seed + zorunlu parola değişimi (runbook).

## Yetkilendirme

- [ ] Her korumalı route'ta `authorization(page_key)` — route tarama testi F11'de (açık).
- [ ] todouser başka kullanıcının todo'sunu göremiyor (404) — service kodunda var; integration testi F11 (açık).
- [x] Son admin / kendini silme korumaları kodda (`LAST_ADMIN`, `SELF_ACTION_FORBIDDEN`); canlı test F11.
- [x] Admin'in `rbac.matrix` izni kilitli (`types.LOCKED_PERMISSIONS`, API `CONFLICT`).

## Girdi ve veri

- [x] Tüm değerler parametreli (`$n`). `grep -rn '\.\. *"' api/src/repositories` boş **değil**; incelendi: yalnızca
      `$n` yer tutucu numaraları ve whitelist'ten gelen sütun adları birleştiriliyor (`todo_repo` sort whitelist'i).
- [x] Sıralama/filtre alanları whitelist'ten (bilinmeyen sort → `created_at`).
- [x] `client_max_body_size 1m` (api nginx + proxy; 1.5 MiB → 413 JSON doğrulandı).
- [x] CSV formül enjeksiyonu kaçışı: `=`, `+`, `-`, `@`, TAB, CR ile başlayan hücreye `'` (`audit_service.lua`).
- [x] Audit'te hassas alanlar maskeli (`models/audit.mask`, 00 §8 listesi). Loglarda parola/token taraması: açık (F11).

## Taşıma ve tarayıcı

- [x] Yalnızca HTTPS (80 → 301, ACME hariç), HSTS 2 yıl; TLS 1.2+ (`deploy/proxy/nginx.conf`, `nginx -t` geçti).
- [x] CSP aktif; `unsafe-eval` ve script `unsafe-inline` yok, yalnızca `wasm-unsafe-eval`.
      **İstisna:** `style-src 'unsafe-inline'` — view'lar dinamik genişlik için `style` attribute yazar (skeleton,
      dashboard barları). Script çalıştıramaz; risk CSS ile veri sızdırma sınırında. Kaldırma yolu: `dom.lua`'nın
      `style` prop'unu `el.style.setProperty` (CSSOM, CSP'ye tabi değil) ile yazması → frontend backlog.
      Swagger UI kendi CSP'sini (jsDelivr) gönderir; proxy onu ayrı location'da geçirir.
- [x] `CORS_ORIGINS` tam domain (`.env.prod.example`); prod'da `*` config tarafından reddedilir (hata düzeltildi).
- [x] Frontend'de `innerHTML` yok (`dom.lua` tasarım gereği `textContent`/DOM API; grep boş).
- [x] **İstisna:** token `localStorage`'da. CSP ile XSS yüzeyi küçültüldü; httpOnly cookie + CSRF daha güçlüdür,
      tehdit modeli gerektirirse ayrı faz.

## Altyapı

- [x] api: non-root (uid 100), `read_only` (yazma denemesi "Read-only file system"), `cap_drop: ALL`,
      `no-new-privileges`. web: `read_only`; non-root nginx imajı frontend Dockerfile'ında (açık).
- [x] Postgres dışarıya port açmıyor (`backend` ağı `internal: true`, `ports` yok).
- [x] `/metrics` proxy'de `deny all` (403).
- [ ] Trivy: `release.yml` CRITICAL/HIGH'da kırar; ilk tag'de sonuç kaydedilecek. gitleaks: ci.yml'e eklenecek (TEST).
- [ ] Bağımlılık sürümleri: rock'lar Dockerfile'da sabit; `package-lock.json` henüz yok (frontend); Dependabot açık değil.
- [x] Yedekler: günlük + haftalık + aylık rotasyon, `BACKUP_AGE_RECIPIENT` ile age şifreleme, tatbikat
      (`deploy/backup/verify.sh`) 2026-09-19'da düz ve şifreli yedekle başarılı. Site dışı kopya (rclone): sunucu
      kurulumunda (runbook §3) — kurulana kadar açık.
- [x] `server_tokens off` (api + proxy); 500 yanıtlarında stack trace yok, yalnızca logda (F3 denetimi).

## Güvenlik açığı bildirimi

Lütfen açıkları herkese açık issue olarak bildirmeyin; GitHub Security Advisory veya e-posta ile bildirin.
