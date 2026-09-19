# ═══ FAZ 18 — DEPLOYMENT + DOKÜMANTASYON ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) — env değişkenleri §6, shared dict'ler §9 (`metrics`),
> teknik düzeltmeler §11 (#5 havuz boyutu, #12 Tailwind prod, #13 çok-instance job kilidi).
> Bu fazda **yeni env değişkeni eklenmez**; gerekirse önce 00 §6 güncellenir.

---

## Amaç

Uygulamayı production'a çıkarılabilir hale getirmek: küçük ve güvenli container imajları, prod compose
(TLS'li reverse proxy, secret yönetimi, kaynak limitleri, healthcheck), CI/CD ile otomatik imaj yayınlama ve
dağıtım, temel izleme (health, metrics, yapılandırılmış log), yedekleme/geri yükleme prosedürü ve güvenlik
kontrol listesi. Ayrıca README, CONTRIBUTING ve CHANGELOG tamamlanır. Faz sonunda yeni bir makinede
`docker compose -f docker-compose.prod.yml up -d` ile HTTPS üzerinden çalışan sistem ayağa kalkar ve
yedekten geri yükleme test edilmiştir.

## Önkoşullar

| Faz | Neden |
|---|---|
| F0–F11 | Backend + test + CI iskeleti |
| F12–F17 | Frontend + optimize build (`build-wasm.sh` hash'li çıktı) |
| F10 | Log cleanup job'u (çok instance kilidi prod'da kritik) |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `api/Dockerfile` | Çok aşamalı: rocks derleme → `openresty/openresty:1.25-alpine` runtime, non-root |
| `web/Dockerfile` | Çok aşamalı: Node (bundle + Tailwind CLI) → `nginx:alpine` statik servis |
| `docker-compose.prod.yml` | postgres + api + web + proxy (TLS) + backup; secrets, limitler, healthcheck |
| `deploy/proxy/nginx.conf` | TLS sonlandırma, güvenlik header'ları, `/api` → api, `/` → web, rate limit |
| `deploy/backup/backup.sh` | `pg_dump` + sıkıştırma + (opsiyonel) şifreleme + rotasyon |
| `deploy/backup/restore.sh` | Geri yükleme + doğrulama sorguları |
| `api/src/router.lua` *(güncelleme)* | `/api/v1/health` (liveness), `/api/v1/health/ready` (DB), `/api/v1/metrics` (Prometheus metin formatı) |
| `.github/workflows/ci.yml` *(güncelleme)* | Build + imaj tarama |
| `.github/workflows/release.yml` | Tag'de imajları GHCR'a push, SBOM, deploy |
| `README.md` | Tamamlanmış kullanım dokümanı |
| `CONTRIBUTING.md` | Geliştirme akışı, commit kuralları, test/lint |
| `CHANGELOG.md` | Keep a Changelog formatı, `0.1.0` |
| `docs/operations.md` | Runbook: deploy, rollback, backup/restore, sık sorunlar |
| `docs/security-checklist.md` | Güvenlik kontrol listesi (bu dokümandaki §7'nin yaşayan kopyası) |

> `deploy/` dizini prompt ağacında yok; prod'a özel config'ler kök dizini kirletmesin diye eklendi.
> `/health` handler'ı F3'te `router.lua` içinde yerel fonksiyondur; burada `ready` ve `metrics` de aynı yerde eklenir
> (prompt ağacında `handlers/health.lua` yok). **Davranış değişikliği:** F3'te `/api/v1/health` DB ping yapıyordu;
> bu fazda DB kontrolü `/api/v1/health/ready`'ye taşınır ve `/api/v1/health` saf liveness olur (F3 DoD'sindeki
> "DB durunca 503" maddesi artık `/ready` için geçerlidir).

---

## 1. `api/Dockerfile`

```dockerfile
# ---- 1. aşama: LuaRocks bağımlılıklarını derle ----
FROM openresty/openresty:1.25.3.2-alpine-fat AS build
RUN apk add --no-cache build-base git openssl-dev argon2-dev
WORKDIR /build
COPY rockspecs/ rockspecs/
COPY shared/ shared/
# Bağımlılıkları ayrı katmanda kur (kod değişince cache bozulmasın)
RUN luarocks install lapis 1.16.0 \
 && luarocks install pgmoon 1.16.0 \
 && luarocks install lua-resty-jwt 0.2.3 \
 && luarocks install argon2 3.0.1 \
 && luarocks install lua-resty-mail 1.1.0 \
 && luarocks install lua-cjson 2.1.0.10 \
 && luarocks make rockspecs/todo-shared-0.1.0-1.rockspec

# ---- 2. aşama: runtime ----
FROM openresty/openresty:1.25.3.2-alpine
RUN apk add --no-cache argon2-libs libgcc tini \
 && addgroup -S app && adduser -S -G app -H app
COPY --from=build /usr/local/openresty/luajit /usr/local/openresty/luajit
WORKDIR /app
COPY --chown=app:app api/conf/ conf/
COPY --chown=app:app api/src/ src/
COPY --chown=app:app api/migrations/ migrations/
COPY --chown=app:app api/seeds/ seeds/
COPY --chown=app:app api/public/ public/
RUN mkdir -p logs temp && chown app:app logs temp
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:8080/api/v1/health || exit 1
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["openresty", "-p", "/app", "-c", "conf/nginx.conf", "-g", "daemon off;"]
```

Notlar:
- Sürüm numaraları örnektir; gerçek sürümler F0'da `rockspecs/` ve lock dosyasına sabitlenir, Dockerfile oradan okur.
- `-fat` imaj yalnızca derleme aşamasında (perl, luarocks, gcc); runtime ~60 MB hedef.
- `nginx.conf`'ta `user` direktifi yok (non-root), port 8080 (< 1024 değil), `pid`/`temp` yolları `/app` altında.
- Migration imaj içinde ama **otomatik çalışmaz**: `docker compose run --rm api resty -I src migrations.lua up`
  ayrı bir deploy adımıdır (§4). Aynı anda iki instance migration koşmasın diye `pg_advisory_lock` (F2).
- `.dockerignore`: `**/spec`, `**/node_modules`, `.git`, `.env*`, `docs`, `web` (api imajı için).

## 2. `web/Dockerfile`

```dockerfile
# ---- 1. aşama: Lua bundle + Tailwind derleme ----
FROM node:20-alpine AS build
RUN apk add --no-cache bash brotli lua5.4
WORKDIR /build
COPY web/package.json web/package-lock.json web/
RUN cd web && npm ci
COPY shared/ shared/
COPY web/ web/
# Tailwind prod derlemesi (00 §11 #12): CDN yerine purge edilmiş CSS
RUN cd web && npx tailwindcss -i public/styles.css -o public/dist/tailwind.css --minify \
 && ./build-wasm.sh

# ---- 2. aşama: statik servis ----
FROM nginx:1.27-alpine
COPY deploy/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /build/web/public/ /usr/share/nginx/html/
HEALTHCHECK CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
```

`deploy/web/nginx.conf` özü:

```nginx
server {
  listen 80;
  root /usr/share/nginx/html;
  gzip_static on;                     # build-wasm.sh'in ürettiği .gz dosyaları
  # brotli_static için ngx_brotli modülü gerekir; yoksa gzip yeterli
  types { application/wasm wasm; }
  location /dist/ { add_header Cache-Control "public, max-age=31536000, immutable"; }
  location = /index.html { add_header Cache-Control "no-cache"; }
  location / { try_files $uri /index.html; }
}
```

`index.html` prod varyantında Tailwind CDN `<script>` kaldırılır, `dist/tailwind.<hash>.css` bağlanır
(`rewrite-index.mjs` — F17 — `APP_ENV=production` iken yapar).

## 3. `docker-compose.prod.yml`

```yaml
# Production compose — .env yerine Docker secrets + env_file (izinleri 600)
name: todo-prod

x-restart: &restart { restart: unless-stopped }
x-logging: &logging
  logging: { driver: json-file, options: { max-size: "20m", max-file: "5" } }

services:
  postgres:
    image: postgres:16-alpine
    <<: [*restart, *logging]
    environment:
      POSTGRES_DB: todo
      POSTGRES_USER: todo
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]
    volumes: [pgdata:/var/lib/postgresql/data]
    command: ["postgres", "-c", "max_connections=100", "-c", "shared_buffers=256MB",
              "-c", "log_min_duration_statement=500"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U todo -d todo"]
      interval: 10s
      retries: 5
    deploy: { resources: { limits: { cpus: "1.0", memory: 1g } } }
    networks: [backend]          # dışarıya port AÇILMAZ

  api:
    image: ghcr.io/OWNER/todo-api:${TAG:?TAG gerekli}
    <<: [*restart, *logging]
    env_file: .env.prod
    environment:
      APP_ENV: production
      DB_HOST: postgres
    secrets: [db_password, jwt_secret, smtp_password]
    depends_on: { postgres: { condition: service_healthy } }
    read_only: true
    tmpfs: [/app/temp, /app/logs]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    deploy: { replicas: 2, resources: { limits: { cpus: "1.0", memory: 512m } } }
    networks: [backend, frontend]

  web:
    image: ghcr.io/OWNER/todo-web:${TAG}
    <<: [*restart, *logging]
    read_only: true
    tmpfs: [/var/cache/nginx, /var/run]
    networks: [frontend]

  proxy:
    image: nginx:1.27-alpine
    <<: [*restart, *logging]
    ports: ["${HTTP_PORT:-80}:80", "${HTTPS_PORT:-443}:443"]   # host'a açılan tek servis; yerel denemede 28088/28443 (00 §6.1)
    volumes:
      - ./deploy/proxy/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./deploy/proxy/certs:/etc/nginx/certs:ro      # certbot / acme.sh ile yenilenir
    depends_on: [api, web]
    networks: [frontend]

  backup:
    image: postgres:16-alpine
    <<: [*restart, *logging]
    entrypoint: ["/bin/sh", "-c", "crond -f -l 8"]
    volumes:
      - ./deploy/backup:/scripts:ro
      - ./deploy/backup/crontab:/etc/crontabs/root:ro
      - backups:/backups
    secrets: [db_password]
    networks: [backend]

secrets:
  db_password:   { file: ./secrets/db_password }
  jwt_secret:    { file: ./secrets/jwt_secret }
  smtp_password: { file: ./secrets/smtp_password }

volumes: { pgdata: {}, backups: {} }
networks: { backend: { internal: true }, frontend: {} }
```

**Secret okuma:** `config.lua` (F3) her değişken için `<AD>_FILE` desteği ekler: `DB_PASSWORD_FILE` set ise dosyadan
okunur. Bu yeni bir değişken değil, mevcut 00 §6 değişkenlerinin `_FILE` varyantı konvansiyonudur
(Docker resmi imajlarıyla aynı). 00 §6'ya bu kural bir satır olarak eklenir.

**Bağlantı bütçesi (00 §11 #5):** `api` replikası × `worker_processes` × `DB_POOL_SIZE` ≤ `max_connections − 10`.
Örn. 2 replika × 2 worker × 20 = 80 ≤ 90 ✔. `worker_processes auto` prod'da CPU limitine göre sabitlenir.

**Log cleanup çok instance:** 2 api replikası var → F10'daki `pg_try_advisory_lock` sayesinde job yalnızca birinde koşar.

## 4. `deploy/proxy/nginx.conf` (öz)

```nginx
http {
  server_tokens off;
  limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;
  upstream api { server api:8080; keepalive 32; }
  upstream web { server web:80; }

  server { listen 80; return 301 https://$host$request_uri; }

  server {
    listen 443 ssl;
    http2 on;
    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    add_header X-Frame-Options DENY always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    # CSP: F12'deki politika; wasm için 'wasm-unsafe-eval', tema inline script'i için hash
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'sha256-<tema-scripti>'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" always;

    client_max_body_size 1m;          # 00 §5 PAYLOAD_TOO_LARGE ile uyumlu

    location /api/ {
      limit_req zone=api burst=40 nodelay;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Request-Id $request_id;
      proxy_set_header Host $host;
      proxy_http_version 1.1; proxy_set_header Connection "";
      proxy_pass http://api;
    }
    location = /api/v1/metrics { deny all; }  # yalnızca iç ağdan (Prometheus backend ağında)
    location /api/v1/swagger { proxy_pass http://api; }   # prod'da istenirse basic auth ile kapatılır
    location / { proxy_pass http://web; }
  }
}
```

- `TRUSTED_PROXIES` (00 §6) proxy container'ının alt ağına ayarlanır; aksi halde audit'teki IP proxy IP'si olur.
- Aynı origin (`/api` ve `/` aynı domain) → `CORS_ORIGINS` yalnızca bu domain; CORS preflight'ı pratikte hiç tetiklenmez.
- TLS sertifikası: `certbot certonly --webroot` + haftalık cron `certbot renew && docker compose exec proxy nginx -s reload`.

## 5. Deploy Akışı ve CI/CD

### 5.1 `release.yml` (tag `v*` push'unda)

```yaml
name: release
on: { push: { tags: ["v*"] } }
permissions: { contents: write, packages: write, id-token: write }
jobs:
  images:
    runs-on: ubuntu-latest
    strategy: { matrix: { app: [api, web] } }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - uses: docker/build-push-action@v6
        with:
          context: .
          file: ${{ matrix.app }}/Dockerfile
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/todo-${{ matrix.app }}:${{ github.ref_name }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          sbom: true
          provenance: true
      - uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ghcr.io/${{ github.repository_owner }}/todo-${{ matrix.app }}:${{ github.ref_name }}
          severity: CRITICAL,HIGH
          exit-code: "1"
  deploy:
    needs: images
    runs-on: ubuntu-latest
    environment: production            # GitHub environment onayı (manuel kapı)
    steps:
      - uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.PROD_HOST }}
          username: deploy
          key: ${{ secrets.PROD_SSH_KEY }}
          script: cd /srv/todo && TAG=${{ github.ref_name }} ./deploy.sh
```

### 5.2 Sunucudaki `deploy.sh` adımları

1. `docker compose pull` (yeni `TAG`).
2. **Yedek al** (`deploy/backup/backup.sh pre-deploy`).
3. **Migration**: `docker compose run --rm api resty -I src -e 'require("db.migrations").up()'`.
   Migration'lar **geriye uyumlu** yazılır (expand → contract): önce sütun ekle, sonraki sürümde eskiyi kaldır.
   Böylece eski ve yeni api aynı anda çalışabilir.
4. `docker compose up -d --no-deps api` → replikalar sırayla yenilenir; healthcheck geçmeden eski kapanmaz
   (`docker compose up --wait`).
5. `docker compose up -d --no-deps web proxy`.
6. Duman testi: `curl -fsS https://<domain>/api/v1/health/ready` ve login isteği.
7. Hata → **rollback**: `TAG=<önceki> docker compose up -d api web`. Migration geri alınmaz (expand-only olduğu için
   eski kod yeni şemayla çalışır); veri bozulmuşsa §6 restore.

### 5.3 CI'a eklenenler (`ci.yml`)

- `docker build` her PR'da (push yok) — Dockerfile kırılmalarını erken yakalar.
- `hadolint` Dockerfile lint.
- `trivy fs` bağımlılık taraması.
- `gitleaks` secret taraması.

## 6. İzleme (Monitoring)

### 6.1 Endpoint'ler

| Endpoint | Amaç | İçerik | Erişim |
|---|---|---|---|
| `GET /api/v1/health` | Liveness | `{ status: "ok" }` — DB'ye dokunmaz | Açık |
| `GET /api/v1/health/ready` | Readiness | DB `SELECT 1` (timeout 1 sn), shared dict'ler erişilebilir → 200 / 503 | Açık |
| `GET /api/v1/metrics` | Prometheus | `metrics` shared dict (00 §9) | Proxy'de `deny all`; yalnızca backend ağı |

`/health/ready` prompt'ta yok; container orkestrasyonunda liveness ile readiness'ın ayrılması için eklendi
(liveness DB'ye bağlı olursa DB kesintisinde tüm api container'ları yeniden başlatılır — yanlış davranış).

### 6.2 `/metrics` formatı

`logger` middleware'i (F3) log fazında `metrics` dict'ine `incr` yapar (00 §9 anahtarları). Handler:

```lua
-- Prometheus metin formatında sayaçları döner; worker'lar arası toplam shared dict'ten gelir
local dict = ngx.shared.metrics
local lines = {
  "# TYPE todo_http_requests_total counter",
  ("todo_http_requests_total %d"):format(dict:get("req_total") or 0),
  ("todo_http_requests_by_class_total{class=\"2xx\"} %d"):format(dict:get("req:2xx") or 0),
  ("todo_http_requests_by_class_total{class=\"4xx\"} %d"):format(dict:get("req:4xx") or 0),
  ("todo_http_requests_by_class_total{class=\"5xx\"} %d"):format(dict:get("req:5xx") or 0),
  "# TYPE todo_http_latency_ms_sum counter",
  ("todo_http_latency_ms_sum %d"):format(dict:get("latency_sum_ms") or 0),
}
```

Histogram, route bazlı etiketler yok — ponytail: sayaçlar + ortalama gecikme ilk sürüm için yeterli;
p95 gerekince `nginx-lua-prometheus` kütüphanesi eklenir (00 §9'a `prometheus_metrics` dict'i ile).

### 6.3 Loglar

- API `LOG_FORMAT=json` (00 §6) → stdout/stderr → Docker json-file (rotasyonlu) → isteğe bağlı Loki/Promtail
  veya Vector ile toplama. Her satırda `req_id` → proxy logu ile eşleştirilebilir (proxy `X-Request-Id` iletir).
- Postgres `log_min_duration_statement=500` → yavaş sorgular.

### 6.4 Uyarılar (Prometheus/Alertmanager veya Uptime Kuma kullanılıyorsa)

| Uyarı | Koşul |
|---|---|
| API kapalı | `/health/ready` 2 dk başarısız |
| 5xx artışı | `rate(5xx) / rate(total) > %2` 5 dk |
| Backup eksik | Son başarılı backup dosyası > 26 saat |
| Log cleanup başarısız | `cleanup_logs` tablosunda son kayıt `status='failure'` veya > 26 saat önce (SQL exporter) |
| Disk | `pgdata` / `backups` volume %80 |
| Sertifika | Bitişe < 14 gün |

Minimum kurulum (tek sunucu): Uptime Kuma ile `/health/ready` + sertifika takibi; Prometheus opsiyonel.

## 7. Yedekleme Stratejisi

| Katman | Yöntem | Sıklık | Saklama |
|---|---|---|---|
| Mantıksal yedek | `pg_dump -Fc` (custom format, sıkıştırılmış) | Günlük 02:00 UTC (log cleanup'tan önce, `AUDIT_CLEANUP_HOUR=3`) | 7 günlük + 4 haftalık + 6 aylık |
| Deploy öncesi | `backup.sh pre-deploy` | Her deploy | Son 5 |
| Site dışı kopya | `rclone copy` → S3 uyumlu depolama, `age` ile şifreli | Günlük | Depolama lifecycle kuralı |
| (Opsiyonel) PITR | WAL arşivleme (`wal-g`) | Sürekli | RPO < 5 dk gerekirse |

Hedefler: **RPO 24 saat** (günlük dump), **RTO 1 saat**. Daha sıkı RPO iş gereksinimi olursa PITR açılır.

`deploy/backup/backup.sh` özü:

```sh
#!/bin/sh
# Günlük PostgreSQL yedeği: custom format dump + şifreleme + rotasyon
set -eu
TAG=${1:-daily}
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT=/backups/$TAG/todo-$TS.dump
mkdir -p /backups/$TAG
PGPASSWORD=$(cat /run/secrets/db_password) \
  pg_dump -h postgres -U todo -d todo -Fc -Z 6 -f "$OUT"
pg_restore -l "$OUT" > /dev/null            # dump okunabilir mi (bozuk dosya tespiti)
# Rotasyon: günlük 7, pre-deploy 5
KEEP=$([ "$TAG" = "pre-deploy" ] && echo 5 || echo 7)
ls -1t /backups/$TAG/*.dump | tail -n +$((KEEP + 1)) | xargs -r rm -f
echo "{\"job\":\"backup\",\"file\":\"$OUT\",\"status\":\"success\",\"ts\":\"$TS\"}"
```

`restore.sh`: boş veritabanına `pg_restore --clean --if-exists --no-owner`, ardından doğrulama:
`SELECT count(*) FROM users; SELECT max(created_at) FROM audit_logs; SELECT version FROM lapis_migrations ORDER BY 1 DESC LIMIT 1;`

**Geri yükleme tatbikatı:** ayda bir, en son yedek ayrı bir container'a restore edilip doğrulama sorguları koşulur
(`make backup.verify`). Test edilmemiş yedek yedek sayılmaz.

## 8. Güvenlik Kontrol Listesi

Canlıya çıkıştan önce ve her minor sürümde gözden geçirilir. (`docs/security-checklist.md` olarak da yayımlanır.)

**Kimlik doğrulama ve oturum**
- [ ] `JWT_SECRET` ≥ 32 byte rastgele (`openssl rand -base64 48`), secret dosyasında, repoda yok.
- [ ] Access TTL 900 sn, refresh TTL 604800 sn (00 §6); refresh rotasyonu + denylist aktif (F5).
- [ ] JWT `alg` sabit HS256; `none` ve diğer algoritmalar reddediliyor (F4 testi).
- [ ] Login rate limit aktif (`LOGIN_RATE_LIMIT`), proxy'de genel `limit_req`.
- [ ] Hatalı giriş mesajı e-posta varlığını ifşa etmiyor; forgot-password her zaman 202.
- [ ] Reset token: tek kullanımlık, SHA-256 hash'i saklanıyor, `PASSWORD_RESET_TTL` sonrası geçersiz.
- [ ] Argon2id parametreleri: `ARGON2_M_COST` prod'da ≥ 15 (19 MiB, OWASP) önerilir — sunucu RAM'ine göre ayarlandı mı? (00 §11 #4)
- [ ] `SEED_DEFAULTS=false` prod'da; varsayılan `admin@todoapp.local` hesabı yok veya parolası değiştirildi.

**Yetkilendirme**
- [ ] Her korumalı route'ta `authorization(page_key)` var (router testi ile tüm route'lar taranır — F11).
- [ ] todouser başka kullanıcının todo'sunu göremiyor/değiştiremiyor (404) — integration testi.
- [ ] Son admin / kendini silme korumaları aktif.
- [ ] Admin'in `rbac.matrix` izni kilitli.

**Girdi ve veri**
- [ ] Tüm SQL parametreli (`$1`); string birleştirmeli sorgu yok (`grep -rn '\.\. *"' api/src/repositories` boş).
- [ ] Sıralama/filtre alanları whitelist'ten.
- [ ] `client_max_body_size 1m`.
- [ ] CSV export'ta formül enjeksiyonu kaçışı (`=`, `+`, `-`, `@` ile başlayan hücreler — F8).
- [ ] Audit'te hassas alanlar maskeli (00 §8); loglarda parola/token yok (`grep -i password` log örneğinde boş).

**Taşıma ve tarayıcı**
- [ ] Yalnızca HTTPS, HSTS; TLS 1.2+.
- [ ] CSP aktif, `unsafe-inline`/`unsafe-eval` yok (yalnızca `wasm-unsafe-eval` + tema script hash'i).
- [ ] `CORS_ORIGINS` tam domain, `*` değil.
- [ ] Frontend'de `innerHTML` kullanımı yok (F17 XSS regresyon testi).
- [ ] Token `localStorage`'da: CSP ile XSS yüzeyi küçültüldü. *Bilinen sınır:* httpOnly cookie + CSRF token'a
      geçiş daha güçlüdür; tehdit modeli gerektirirse ayrı faz olarak planlanır.

**Altyapı**
- [ ] Container'lar non-root, `read_only`, `cap_drop: ALL`, `no-new-privileges`.
- [ ] Postgres dışarıya port açmıyor (`backend` ağı `internal`).
- [ ] `/metrics` dışarıdan erişilemiyor.
- [ ] Trivy: CRITICAL/HIGH açık yok; gitleaks temiz.
- [ ] Bağımlılık sürümleri sabit (rockspec + `package-lock.json`); Dependabot/Renovate açık.
- [ ] Yedekler şifreli ve site dışında; geri yükleme son 30 günde test edildi.
- [ ] `server_tokens off`; hata yanıtlarında stack trace yok (`APP_ENV=production`).

## 9. Dokümantasyon

### 9.1 `README.md` (tamamlanmış hali) bölümleri

1. Proje özeti + ekran görüntüsü (açık/koyu)
2. Mimari diyagram (00 §2'den) + bileşen tablosu
3. Hızlı başlangıç: `cp .env.example .env && make up && make db.migrate db.seed` → URL'ler (web, API, Swagger, MailHog)
4. Varsayılan hesaplar (yalnızca geliştirme, `SEED_DEFAULTS=true`)
5. Makefile hedefleri tablosu
6. Ortam değişkenleri → 00 §6'ya link (tablo kopyalanmaz — tek kaynak)
7. API dokümantasyonu → `/api/v1/swagger`
8. Test: birim, integration, E2E, yük testi komutları
9. Production deploy özeti → `docs/operations.md`
10. Güvenlik → `docs/security-checklist.md`, güvenlik açığı bildirimi (e-posta / GitHub Security Advisory)
11. Tarayıcı desteği (evergreen; Safari 15.4+ — `<dialog>`, `wasm-unsafe-eval`)
12. Lisans

### 9.2 `CONTRIBUTING.md`

- Gereksinimler: Docker, OpenResty (opsiyonel yerel), Lua 5.4 + LuaJIT, Node 20.
- Kurulum ve `git config core.hooksPath .githooks` (F0 pre-commit: luacheck).
- Dal stratejisi: `main` korumalı; `feat/…`, `fix/…`; PR zorunlu, 1 onay + yeşil CI.
- Commit: Conventional Commits (`feat(api): ...`, `fix(web): ...`) → CHANGELOG üretimi.
- Kod kuralları: 00 §4 katman kuralları, 00 §14 konvansiyonlar; yorumlar Türkçe.
- Yeni endpoint kontrol listesi: route + `authorization(page_key)` + validation şeması (shared) + service + audit olayı
  (00 §8'e ekle) + OpenAPI spec + integration testi + gerekiyorsa frontend view.
- Yeni env değişkeni: önce 00 §6, sonra `.env.example` ve `config.lua`.
- Migration kuralı: yalnızca ileri, geriye uyumlu (expand/contract).

### 9.3 `CHANGELOG.md`

[Keep a Changelog](https://keepachangelog.com/tr/1.1.0/) + SemVer. İlk giriş `## [0.1.0] - YYYY-AA-GG` altında
`Added` bölümü: faz başlıkları özetle. Sonraki sürümler Conventional Commits'ten `git-cliff` ile üretilir (opsiyonel).

### 9.4 `docs/operations.md` (runbook)

Deploy, rollback, migration, backup/restore, sertifika yenileme, log inceleme (`req_id` ile), sık sorunlar:
"DB bağlantı sayısı doldu" (havuz bütçesi §3), "log cleanup çalışmadı" (`cleanup_logs` sorgusu),
"kullanıcı yetkisi yansımadı" (RBAC cache TTL), "rate limit'e takılan kullanıcı" (shared dict TTL 60 sn — beklemek
veya api reload).

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Docker Compose (Kubernetes değil) | Tek sunucu hedefi; K8s gereksinimi yok. Manifest'ler ihtiyaç olunca yazılır |
| Migration ayrı adım, otomatik değil | Birden fazla replika aynı anda koşmasın; deploy öncesi yedek alınabilsin |
| Expand/contract migration | Rollback'te şema geri almaya gerek kalmaz |
| Secrets `_FILE` konvansiyonu | Docker/Swarm standardı; env'de düz parola yok |
| Liveness ≠ readiness | DB kesintisinde gereksiz container restart döngüsü olmasın |
| Basit sayaç metrikleri | İlk sürüm için yeterli; kütüphane ihtiyaç halinde |
| Aynı origin (`/api` + `/`) | CORS karmaşası ve preflight gecikmesi yok |
| `pg_dump` günlük (PITR opsiyonel) | RPO 24 saat bu uygulama için kabul edilebilir varsayımı; iş gereksinimi değişirse wal-g |

## Kabul kriterleri (DoD)

- [ ] `docker build` her iki Dockerfile için başarılı; api imajı < 120 MB, web imajı < 40 MB; ikisi de non-root.
- [ ] Temiz bir sunucuda `docker compose -f docker-compose.prod.yml up -d` + migration ile HTTPS üzerinden login yapılabiliyor.
- [ ] Postgres portu host'tan erişilemiyor; `/metrics` internetten 403.
- [ ] `securityheaders.com` / Mozilla Observatory skoru A veya üstü.
- [ ] 2 api replikasında log cleanup job'u tek bir replikada çalışıyor (`cleanup_logs` günde 1 kayıt).
- [ ] Tag push'unda imajlar GHCR'a gidiyor, Trivy CRITICAL/HIGH = 0, deploy onay kapısından sonra otomatik.
- [ ] Rollback prosedürü denendi (önceki tag'e dönüş < 5 dk).
- [ ] Günlük yedek oluşuyor, rotasyon çalışıyor; restore tatbikatı başarılı ve süresi ölçüldü (RTO < 1 saat).
- [ ] `/health`, `/health/ready`, `/metrics` beklenen çıktıyı veriyor; DB durdurulunca `/health/ready` 503, `/health` 200.
- [ ] Güvenlik kontrol listesinin tüm maddeleri işaretli veya bilinçli istisna olarak gerekçelendirilmiş.
- [ ] README'deki hızlı başlangıç, repoyu ilk kez klonlayan biri tarafından (veya temiz bir VM'de) adım adım doğrulandı.
- [ ] CONTRIBUTING, CHANGELOG (`0.1.0`), `docs/operations.md`, `docs/security-checklist.md` mevcut.

## Doğrulama

```bash
# İmajlar
docker build -f api/Dockerfile -t todo-api:local . && docker build -f web/Dockerfile -t todo-web:local .
docker images | grep todo-
docker run --rm todo-api:local id          # uid != 0
hadolint api/Dockerfile web/Dockerfile
trivy image --severity CRITICAL,HIGH todo-api:local

# Prod stack (staging sunucusunda)
TAG=local docker compose -f docker-compose.prod.yml up -d --wait
docker compose -f docker-compose.prod.yml run --rm api resty -I src -e 'require("db.migrations").up()'
curl -fsS https://staging.example.com/api/v1/health/ready
curl -s -o /dev/null -w '%{http_code}\n' https://staging.example.com/metrics      # 403
nc -zv staging.example.com 5432                                                    # bağlantı reddedilmeli
curl -sI https://staging.example.com | grep -Ei 'strict-transport|content-security|x-frame'

# Readiness davranışı
docker compose -f docker-compose.prod.yml stop postgres
curl -s -o /dev/null -w '%{http_code}\n' https://staging.example.com/api/v1/health         # 200
curl -s -o /dev/null -w '%{http_code}\n' https://staging.example.com/api/v1/health/ready   # 503
docker compose -f docker-compose.prod.yml start postgres

# Yedek + restore tatbikatı
docker compose -f docker-compose.prod.yml exec backup /scripts/backup.sh daily
make backup.verify        # en son dump'ı geçici container'a restore + doğrulama sorguları
```

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| `argon2` C kütüphanesinin alpine'de derlenmesi | Build aşamasında `argon2-dev`, runtime'da `argon2-libs`; CI'da imaj build'i her PR'da |
| Replika × worker × pool > `max_connections` | §3 formülü README'de; `DB_POOL_SIZE` buna göre |
| `read_only` container'da nginx'in yazma ihtiyacı | `tmpfs` ile `temp`/`logs`; `client_body_temp_path` vb. `/app/temp` altına |
| Migration'ın geri alınamaz olması | Deploy öncesi yedek + expand/contract kuralı |
| Sertifika yenilemesinin unutulması | Cron + bitişe 14 gün kala uyarı |
| CSP hash'inin tema script'i değişince bozulması | `rewrite-index.mjs` hash'i hesaplayıp proxy config'ine şablonla yazar veya script `dist/theme-init.<hash>.js` harici dosyaya taşınır (tercih: harici dosya → hash gerekmez) |
| Yedeklerin aynı disk üzerinde olması | Site dışı şifreli kopya zorunlu |

## Tahmini Efor

**L** — ~3–4 gün (Dockerfile + prod compose + proxy ~1, CI/CD ~0.5, monitoring ~0.5, backup + tatbikat ~0.5,
dokümantasyon ~1, güvenlik denetimi ~0.5).
