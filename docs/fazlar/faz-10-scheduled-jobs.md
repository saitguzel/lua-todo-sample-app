# ═══ FAZ 10 — SCHEDULED JOBS ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) — env değişkenleri (§6), shared dict'ler (§9), teknik düzeltme #13.

## 1. Amaç

Audit log tablosunun sınırsız büyümesini engelleyen, saatlik kontrol edip günde bir kez `AUDIT_CLEANUP_HOUR` (UTC) saatinde çalışan, 1000'erli batch'lerle eski kayıtları silen ve her çalıştırmayı `cleanup_logs` tablosuna meta-log olarak yazan bir zamanlanmış iş (`log_cleanup`) kurulur. İş çok worker'lı ve çok instance'lı ortamda **tek kez** çalışır, nginx reload/stop sırasında yarım batch bırakmadan düzgün kapanır.

Faz sonunda:
- `AUDIT_CLEANUP_ENABLED=true` iken job otomatik başlar, `false` iken hiç timer kurulmaz.
- `make job.cleanup` (manuel tetik) ile job anında çalıştırılabilir.
- `cleanup_logs` her çalıştırma için bir satır içerir (`success` / `failure` / `partial`).

## 2. Önkoşullar

| Faz | Neden |
|---|---|
| F2 | `audit_logs` tablosu, `idx_audit_created` indeksi; `007_cleanup_logs` migration iskeleti |
| F3 | `config.lua` (AUDIT_* değişkenleri), `db/query.lua`, `logger`, nginx.conf'ta `job_locks` dict |
| F8 | Audit tablosu gerçekten doluyor (test için veri) |

## 3. Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/jobs/log_cleanup.lua` | Timer kurulumu, zaman kontrolü, kilit, batch DELETE döngüsü, meta-log, graceful çıkış |
| `api/migrations/007_cleanup_logs.lua` | `cleanup_logs` tablosu + `created_at` indeksi (F2'de oluşturulduysa doğrulanır) |
| `api/src/app.lua` (güncelleme) | `init_worker` kancasından `log_cleanup.start()` çağrısı |
| `api/conf/nginx.conf` (güncelleme) | `init_worker_by_lua_block`, `lua_shared_dict job_locks 1m;`, `worker_shutdown_timeout 30s;` |
| `api/spec/log_cleanup_spec.lua` | Saat hesabı, "bugün çalıştı mı" mantığı, batch döngüsü (DB mock'lu) birim testleri |
| `Makefile` (güncelleme) | `job.cleanup` hedefi |

## 4. Dosya Bazlı Tasarım

### 4.1 `api/migrations/007_cleanup_logs.lua`

F2 migration formatı (`{ version, name, up = {SQL...}, down = {SQL...} }` string listesi; Lapis migration'ı
değil), SQL prompt'taki şemanın birebir aynısı + indeks. Dosya F2'de oluşturulur; bu fazda içeriği job'un
ihtiyacına göre doğrulanır:

```lua
-- 007_cleanup_logs: temizlik işi meta-log tablosu
return {
  version = 7,
  name = "cleanup_logs",
  up = {
    [[CREATE TABLE cleanup_logs (
      id            BIGSERIAL PRIMARY KEY,
      job_name      VARCHAR(100) NOT NULL,
      table_name    VARCHAR(100),
      deleted_count INTEGER DEFAULT 0,
      batch_count   INTEGER DEFAULT 0,
      duration_ms   INTEGER,
      status        VARCHAR(20) DEFAULT 'success',
      error_message TEXT,
      created_at    TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX idx_cleanup_created ON cleanup_logs(created_at DESC)]],
  },
  down = {
    [[DROP TABLE IF EXISTS cleanup_logs]],
  },
}
```

`status` değerleri: `success` (tüm eski kayıtlar silindi), `partial` (graceful shutdown ile yarıda kesildi), `failure` (hata). `cleanup_logs` kendisi temizlenmez (günde 1 satır → yılda 365 satır; YAGNI).

### 4.2 `api/src/jobs/log_cleanup.lua`

**Public API**

```lua
local _M = {}

-- init_worker'dan çağrılır; yalnızca worker 0'da timer kurar.
-- Dönüş: true | nil, err
function _M.start() end

-- Zaman kontrolünü atlayıp işi hemen çalıştırır (CLI / test için).
-- Dönüş: result_tbl | nil, err
-- result_tbl = { deleted = n, batches = n, duration_ms = n, status = "success"|"partial" }
function _M.run_once(opts) end

-- Saf fonksiyon: bu tick'te çalışmalı mı? (test edilebilir)
-- now_utc: epoch saniye, hour: 0-23, last_run_day: "YYYY-MM-DD" | nil
function _M.should_run(now_utc, hour, last_run_day) end

return _M
```

**Sabitler / config** (hepsi `config.lua`'dan, yeni env yok):

| Kaynak | Kullanım |
|---|---|
| `AUDIT_CLEANUP_ENABLED` | `false` ise `start()` hiçbir şey yapmaz, `info` log yazar |
| `AUDIT_CLEANUP_HOUR` | 0–23 UTC |
| `AUDIT_LOG_RETENTION_DAYS` | Silme eşiği |
| `AUDIT_CLEANUP_BATCH_SIZE` | Default 1000 |
| Sabit `CHECK_INTERVAL = 3600` | Saatlik kontrol (prompt gereği) |
| Sabit `BATCH_PAUSE = 0.05` | Batch arası `ngx.sleep` (DB'ye nefes) |
| Sabit `ADVISORY_LOCK_KEY = 7310001` | `pg_try_advisory_lock` anahtarı |

**Akış**

```
init_worker_by_lua
  └─ log_cleanup.start()
       ├─ AUDIT_CLEANUP_ENABLED == false → return true
       ├─ ngx.worker.id() ~= 0           → return true   (diğer worker'lar kurmaz)
       ├─ ngx.timer.at(0, tick)          → ilk kontrol hemen (restart sonrası kaçırmayı önler)
       └─ ngx.timer.every(3600, tick)

tick(premature)
  ├─ premature == true → return                          (nginx kapanıyor)
  ├─ now = ngx.time(); today = os.date("!%Y-%m-%d", now)
  ├─ last = job_locks:get("last_run:log_cleanup")
  ├─ should_run(now, HOUR, last) == false → return
  ├─ ok = job_locks:add("lock:log_cleanup", worker_pid, 3600)   (aynı instance'ta çifte çalışmayı önler)
  │    └─ ok == false → return
  └─ pcall(run_once) → finally: job_locks:delete("lock:log_cleanup")
```

**`should_run` mantığı** — saatlik timer tam `HOUR:00`'da tetiklenmeyebilir (worker başlangıç saatine göre kayar). Bu yüzden "şu anki UTC saat == HOUR **ve** bugün henüz çalışmadı" kontrolü yapılır:

```lua
function _M.should_run(now_utc, hour, last_run_day)
  local t = os.date("!*t", now_utc)
  if t.hour ~= hour then return false end
  local today = os.date("!%Y-%m-%d", now_utc)
  return last_run_day ~= today
end
```

Saatlik tick her 60 dakikada bir → HOUR penceresinde (HOUR:00–HOUR:59) tam olarak bir tick düşer. `last_run:log_cleanup` (TTL 86400) çifte çalışmaya karşı ikinci güvence.

**`run_once` — batch döngüsü**

```lua
function _M.run_once(opts)
  opts = opts or {}
  local started = ngx.now()
  local deleted, batches, status = 0, 0, "success"

  -- Çok instance için: tek bir bağlantıda advisory lock
  local conn, err = pool.acquire()
  if not conn then return nil, err end

  local ok, res = pcall(function()
    local got = conn:query("SELECT pg_try_advisory_lock($1) AS ok", ADVISORY_LOCK_KEY)
    if not got[1].ok then status = "skipped"; return end

    while true do
      if ngx.worker.exiting() then status = "partial"; break end

      -- id bazlı batch: indeks kullanır, uzun kilit tutmaz
      local rows = conn:query([[
        DELETE FROM audit_logs
        WHERE id IN (
          SELECT id FROM audit_logs
          WHERE created_at < now() - make_interval(days => $1)
          ORDER BY created_at
          LIMIT $2
        )
        RETURNING 1
      ]], cfg.AUDIT_LOG_RETENTION_DAYS, cfg.AUDIT_CLEANUP_BATCH_SIZE)

      local n = #rows
      if n == 0 then break end
      deleted = deleted + n
      batches = batches + 1
      ngx.sleep(BATCH_PAUSE)          -- cosocket-dostu bekleme, worker'ı kilitlemez
    end
  end)

  conn:query("SELECT pg_advisory_unlock($1)", ADVISORY_LOCK_KEY)   -- pcall içinde, hata yutulur ve loglanır
  pool.release(conn)
  -- ... meta-log + job_locks:set("last_run:log_cleanup", today, 86400) + collectgarbage
end
```

Notlar:
- `RETURNING 1` + `#rows` yerine `pgmoon` `affected_rows` alanı da kullanılabilir; `RETURNING` ile satır sayısı kesin (yalnızca 1000 küçük satır). Uygulamada `res.affected_rows` tercih edilir, bellek kopyası oluşmaz.
- Advisory lock **oturum** seviyesindedir; aynı bağlantıda unlock zorunlu, bu yüzden tüm döngü tek `conn` üzerinde yürür ve havuza geri verilmeden önce unlock edilir.
- `ngx.sleep` timer bağlamında kullanılabilir (timer'lar light thread'dir).
- Döngü sonunda `collectgarbage("collect")` (00-genel-bakis §14'te izin verilen iki yerden biri).

**Meta-log yazımı** (her zaman, hata durumunda da):

```sql
INSERT INTO cleanup_logs (job_name, table_name, deleted_count, batch_count, duration_ms, status, error_message)
VALUES ($1, $2, $3, $4, $5, $6, $7)
```

`job_name = "log_cleanup"`, `table_name = "audit_logs"`. `status = "skipped"` (başka instance kilidi tutuyor) durumunda satır **yazılmaz**, sadece `debug` log.

**Loglama** (F3 logger formatı, JSON):

```json
{"level":"info","event":"job.log_cleanup.done","deleted":12450,"batches":13,"duration_ms":842,"status":"success"}
```

Hata durumunda `level=error`, `event=job.log_cleanup.failed`, `error=...`.

### 4.3 `api/src/app.lua` / `nginx.conf` güncellemeleri

```nginx
http {
  lua_shared_dict job_locks 1m;
  worker_shutdown_timeout 30s;   # graceful shutdown: çalışan batch'in bitmesine izin

  init_worker_by_lua_block {
    local ok, err = require("jobs.log_cleanup").start()
    if not ok then ngx.log(ngx.ERR, "log_cleanup başlatılamadı: ", err) end
  }
}
```

`app.lua` içinde ayrı bir `init_worker` fonksiyonu yoktur; kanca doğrudan nginx.conf'ta. Başka job eklenirse `jobs/init.lua` gibi bir toplayıcı düşünülür (şu an YAGNI).

### 4.4 Graceful Shutdown

| Senaryo | Davranış |
|---|---|
| `nginx -s quit` / reload, job çalışmıyor | Bekleyen timer `premature = true` ile çağrılır → hemen `return` |
| Job batch ortasında | Mevcut DELETE tamamlanır (tek statement, atomik); döngü başındaki `ngx.worker.exiting()` kontrolü döngüyü kırar; `status = "partial"` meta-log'a yazılır |
| `worker_shutdown_timeout` aşılırsa | nginx worker'ı öldürür; son DELETE ya commit edilmiş ya da Postgres tarafından rollback edilmiştir (autocommit tek statement) → veri tutarlı. Advisory lock bağlantı kapanınca Postgres tarafından serbest bırakılır |
| Shared dict kilidi kalırsa | `lock:log_cleanup` TTL 3600 sn → kendiliğinden düşer |

### 4.5 Manuel Tetik

`Makefile`:

```make
job.cleanup:
	docker compose exec api resty -I /app/src -e 'require("config").load(); local r, e = require("jobs.log_cleanup").run_once(); print(require("cjson").encode(r or {error=e}))'
```

`resty` CLI timer değil düz bir light thread'de çalışır; `ngx.worker.exiting` mevcuttur, `job_locks` dict ise `resty --shdict "job_locks 1m"` ile verilir.

## 5. Teknik Kararlar

| Karar | Neden |
|---|---|
| `ngx.timer.every(3600)` + ilk `timer.at(0)` | Prompt "ngx.timer.at ile her saat" diyor; `every` aynı işi tek satırda, yeniden kurma hatası olmadan yapar. İlk anlık tick restart sonrası HOUR penceresi kaçmasın diye |
| Yalnızca worker 0 | Teknik düzeltme #13; `init_worker` her worker'da koşar |
| `pg_try_advisory_lock` | Birden fazla API container'ı (prod replika) aynı anda silmesin; shared dict yalnızca tek instance'ı korur |
| `DELETE ... WHERE id IN (SELECT ... LIMIT)` | Postgres `DELETE ... LIMIT` desteklemez; alt sorgu `idx_audit_created` indeksini kullanır, her batch kısa transaction |
| UTC saat | Container TZ'sinden bağımsız, deterministik; `.env.example`'da "UTC" notu |
| `cleanup_logs` temizlenmez | Günde 1 satır; ihtiyaç doğarsa aynı job'a ikinci tablo eklenir |
| Audit kaydı yazılmaz | Sistem işi, kullanıcı aksiyonu değil; meta-log `cleanup_logs`'ta |

## Kabul kriterleri (DoD)

- [ ] `AUDIT_CLEANUP_ENABLED=false` → loglarda `job.log_cleanup.disabled`, hiçbir timer yok.
- [ ] `worker_processes 4` ile başlatıldığında `job.log_cleanup.scheduled` logu **yalnızca bir kez** görülür.
- [ ] `should_run` birim testleri: yanlış saat → false, doğru saat + bugün çalışmış → false, doğru saat + dün çalışmış → true, `last_run_day=nil` → true.
- [ ] 25.000 eski (+ 500 yeni) audit satırı ile `make job.cleanup` → 25 batch, 25.000 silinen, yeni 500 satır duruyor.
- [ ] `cleanup_logs`'ta ilgili satır: `deleted_count=25000`, `batch_count=25`, `status='success'`, `duration_ms > 0`.
- [ ] İki container aynı anda `run_once` çağırırsa biri `skipped` olur, toplam silinen sayı tek çalıştırmayla aynıdır.
- [ ] Batch ortasında `nginx -s quit` → `status='partial'` satırı yazılır, error log yok, sonraki gün kalan kayıtlar silinir.
- [ ] DB kapalıyken tick → `status='failure'` yazılamasa bile `error` log düşer, worker çökmez, bir sonraki tick yeniden dener.
- [ ] `luacheck api/src/jobs` temiz.

## 7. Doğrulama

```bash
# 1) Migration
make db.migrate
docker compose exec postgres psql -U todo -d todo -c '\d cleanup_logs'

# 2) Test verisi: 25.000 eski + 500 yeni audit kaydı
docker compose exec postgres psql -U todo -d todo -c "
  INSERT INTO audit_logs (action, created_at)
  SELECT 'test.old', now() - interval '40 days' FROM generate_series(1, 25000);
  INSERT INTO audit_logs (action, created_at)
  SELECT 'test.new', now() FROM generate_series(1, 500);"

# 3) Manuel çalıştırma
make job.cleanup
# Beklenen: {"deleted":25000,"batches":25,"duration_ms":...,"status":"success"}

# 4) Kontrol
docker compose exec postgres psql -U todo -d todo -c \
  "SELECT count(*) FILTER (WHERE action='test.old') AS old, count(*) FILTER (WHERE action='test.new') AS new FROM audit_logs"
# Beklenen: old=0, new=500
docker compose exec postgres psql -U todo -d todo -c \
  "SELECT job_name, deleted_count, batch_count, status FROM cleanup_logs ORDER BY id DESC LIMIT 1"

# 5) Zamanlama: saati şimdiki UTC saate ayarla, restart et
AUDIT_CLEANUP_HOUR=$(date -u +%H | sed 's/^0//') docker compose up -d api
docker compose logs api | grep job.log_cleanup

# 6) Tek worker kontrolü
docker compose logs api | grep -c 'job.log_cleanup.scheduled'   # Beklenen: 1

# 7) Birim testler
cd api && busted spec/log_cleanup_spec.lua
```

## 8. Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| Worker 0 crash olup yeniden doğarsa `init_worker` tekrar çalışır | Normal davranış; timer yeniden kurulur, `last_run` dict sayesinde aynı gün tekrar çalışmaz |
| Çok büyük backlog (ilk kurulum, milyonlarca satır) | Batch + sleep sayesinde DB kilitlenmez; süre uzun olabilir → `worker_shutdown_timeout` ile yarıda kesilirse `partial`, ertesi gün devam. Gerekirse manuel `make job.cleanup` birkaç kez |
| Autovacuum baskısı (çok DELETE) | Günlük küçük miktarlar sorun değil; ilk büyük temizlikten sonra `VACUUM (ANALYZE) audit_logs` önerisi README'de |
| Saat dilimi karışıklığı | Tüm hesap UTC, `.env.example` yorumunda açıkça yazılı |
| `resty` CLI'da shared dict yok | Makefile hedefi `--shdict` bayrağı ile çalıştırır |
| Partitioning ihtiyacı (çok yüksek hacim) | `-- ponytail:` notu: günlük > 10M satırda `audit_logs` aylık partition + `DROP PARTITION`'a geçilir |

## 9. Tahmini Efor

**S** — ~0.5–1 gün (job + migration doğrulama + testler + manuel senaryolar).
