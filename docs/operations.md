# Operasyon Runbook

todo-lua prod ortamı işletim kılavuzu. Mimari ve sözleşmeler için [00-genel-bakis](fazlar/00-genel-bakis.md).

## 1. Deploy

### İlk kurulum (temiz sunucu)

Tüm compose komutları `--env-file .env.prod` ile çalışır (compose `${TAG}`, `${GHCR_OWNER}` gibi değerleri
yalnızca `.env`'den otomatik okur). Kısaltma: `C="docker compose --env-file .env.prod -f docker-compose.prod.yml"`.

```bash
git clone <repo> /srv/todo && cd /srv/todo && git checkout v0.1.0
cp .env.prod.example .env.prod && chmod 600 .env.prod    # TAG, GHCR_OWNER, domain, SMTP düzenleyin
mkdir -p secrets
openssl rand -hex 24      > secrets/db_password
openssl rand -base64 48   > secrets/jwt_secret
printf '%s' '<smtp parolası>' > secrets/smtp_password
# api container'ı uid 100 (app) ile koşar: secret dosyaları onun okuyabileceği izinde olmalı
chmod 640 secrets/* && sudo chown 100:101 secrets/*     # ya da chmod 644 (sunucuda tek kullanıcı varsa)
# TLS: önce yalnızca proxy'yi 80'de kaldırıp certbot webroot ile sertifika alın
certbot certonly --webroot -w deploy/proxy/certbot -d <domain>
cp /etc/letsencrypt/live/<domain>/{fullchain,privkey}.pem deploy/proxy/certs/
$C build backup                                          # postgres:16-alpine + age (yerel imaj)
$C up -d --wait
$C run --rm --no-deps api resty -I /app/src -I /app/lib /app/src/db/migrations.lua up   # ayrı adım
$C run --rm --no-deps api resty -I /app/src -I /app/lib /app/src/db/migrations.lua seed # yalnızca RBAC varsayılanları
```

İlk admin: `SEED_DEFAULTS=false` iken varsayılan kullanıcı oluşturulmaz. Bir kereliğine
`$C run --rm --no-deps -e SEED_DEFAULTS=true api resty ... migrations.lua seed` ile oluşturup **hemen** parolasını
değiştirin (checklist: varsayılan hesap).

### Sıradaki deploy'lar

`TAG=<yeni> sh deploy/deploy.sh` (release.yml onay kapısından sonra bunu SSH ile çağırır). Adımlar:

1. `pull api web`
2. **Yedek:** `exec backup sh /scripts/backup.sh pre-deploy`
3. **Migration:** `run --rm --no-deps api resty … migrations.lua up`
   Migration'lar geriye uyumlu yazılır (expand → contract); eski ve yeni api aynı anda çalışabilir.
4. `up -d --wait api` (healthcheck geçmeden eski replika kapanmaz)
5. `up -d --wait web proxy`
6. Duman testi: `curl -fsS $APP_BASE_URL/api/v1/health/ready`

### Rollback

```bash
TAG=<önceki> sh deploy/deploy.sh --rollback        # hedef: < 5 dk
```

Migration geri alınmaz (expand-only); eski kod yeni şemayla çalışır. Veri bozulduysa §3 restore.

## 2. Sağlık ve izleme

| Endpoint | Anlamı | Beklenen |
|---|---|---|
| `GET /api/v1/health` | Liveness (DB'ye dokunmaz) | 200 `{"status":"ok"}` |
| `GET /api/v1/health/ready` | Readiness (DB `SELECT 1`) | 200 / DB yoksa 503 |
| `GET /api/v1/metrics` | Prometheus sayaçları | proxy'de `deny all`; iç ağdan erişilir |

Uyarılar (minimum kurulum: Uptime Kuma):

| Uyarı | Koşul |
|---|---|
| API kapalı | `/health/ready` 2 dk başarısız |
| 5xx artışı | `rate(5xx)/rate(total) > %2` 5 dk |
| Backup eksik | son `todo-*.dump*` > 26 saat (`/backups/backup.log`) |
| Log cleanup | `cleanup_logs` son kaydı failure veya > 26 saat |
| Disk | `pgdata` / `backups` %80 |
| Sertifika | bitişe < 14 gün |

## 3. Yedekleme ve geri yükleme

- Günlük `pg_dump -Fc` 02:00 UTC'de (log cleanup 03:00'ten önce). Saklama: 7 günlük + 4 haftalık (pazar)
  + 6 aylık (ayın 1'i) + son 5 pre-deploy. Her dump `pg_restore -l` ile okunabilirlik kontrolünden geçer.
- **Şifreleme:** `.env.prod` içinde `BACKUP_AGE_RECIPIENT=age1…` set edilirse dump `age` ile şifrelenir
  (`.dump.age`), düz dosya silinir. Özel anahtar sunucuda **tutulmaz**; kasada saklanır.
- **Site dışı kopya:** `backups` volume'ü `rclone copy` ile S3 uyumlu depoya (cron, sunucu tarafında).
  Aynı diskteki yedek yedek sayılmaz.
- **Elle yedek:** `$C exec backup sh /scripts/backup.sh pre-deploy`
- **Geri yükleme (prod DB'yi EZER):**

```bash
$C exec backup sh /scripts/restore.sh /backups/daily/<dosya>.dump
# şifreliyse: -e BACKUP_AGE_IDENTITY=/yol/age.key (anahtarı container'a geçici bağlayarak)
```

- **Aylık tatbikat (`make backup.verify`):** `sh deploy/backup/verify.sh` en son yedeği geçici bir postgres
  container'ına restore eder, doğrulama sorgularını koşar ve süreyi yazar; prod DB'ye dokunmaz.
  Şifreli yedek için `BACKUP_AGE_IDENTITY=<anahtar> BACKUP_IMAGE=todo-backup:<TAG>`.
  Hedefler: RPO 24 saat, RTO 1 saat (ölçülen: boş-orta DB'de ~10 sn uçtan uca).

## 4. Sık sorunlar

| Belirti | Neden | Çözüm |
|---|---|---|
| `DB_UNAVAILABLE` / bağlantı reddi | Havuz bütçesi: replika × worker × `DB_POOL_SIZE` > `max_connections` | api replikalarını veya `DB_POOL_SIZE`'ı düşürün; postgres `max_connections`'ü artırmayın |
| Log cleanup çalışmıyor | Çok instance kilidi veya `AUDIT_CLEANUP_ENABLED=false` | `SELECT created_at, status, deleted_count, error_message FROM cleanup_logs ORDER BY created_at DESC LIMIT 5;` kontrol edin |
| Kullanıcı yetkisi yansımadı | RBAC shared dict cache | `RBAC_CACHE_TTL` (60 sn) kadar bekleyin veya `docker compose exec api openresty -s reload` |
| Login `RATE_LIMITED` | IP+email başına dakikada `LOGIN_RATE_LIMIT` deneme | shared dict TTL 60 sn — bekleyin; acil durumda api reload |
| 413 Payload Too Large | `client_max_body_size 1m` | Beklenen davranış; istemci tarafını küçültün |
| Sertifika yenileme | certbot webroot | haftalık cron: `certbot renew --webroot -w deploy/proxy/certbot --deploy-hook 'cp … deploy/proxy/certs/ && docker compose -f docker-compose.prod.yml exec proxy nginx -s reload'` |

## 5. Log inceleme

- API JSON log yazar (`LOG_FORMAT=json`), her satırda `req_id` var.
- Proxy `X-Request-Id` iletir → proxy logu ile API logu `req_id` üzerinden eşleşir:

```bash
$C logs api | grep '"req_id":"<id>"'
```
