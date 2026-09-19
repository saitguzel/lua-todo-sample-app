# ═══ FAZ 8 — AUDIT LOG + MIDDLEWARE ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — audit olayları + maskelenen alanlar (§8),
> `ngx.ctx.audit` (§10), `TRUSTED_PROXIES` (§6), yanıt zarfı (§15), teknik düzeltmeler #7, #16,
> `collectgarbage` kuralı (§14).

## Amaç

Denetim kaydı altyapısının tamamlanması: F5'teki minimal `audit_service.record` doğrudan INSERT'ten
`audit_repo`'ya taşınır, maskeleme recursive ve eksiksiz hale gelir, `audit_context` middleware'i
güvenilir proxy farkındalığıyla IP/UA'yı toplar ve admin için dört okuma endpoint'i (liste, detay,
istatistik, CSV export) yayınlanır. Faz sonunda 00 §8'deki **her** olayın ilgili serviste üretildiği
bir entegrasyon matrisiyle doğrulanır.

## Önkoşullar

| Faz | Neden |
|---|---|
| F2 | `audit_logs` tablosu + `idx_audit_created`, `idx_audit_user` |
| F3 | `query`, `router.chain`, `error_handler`, `logger` (`req_id`) |
| F4 | `models/audit.lua` (`mask`, `serialize` iskeleti) |
| F5 | `audit_service.record` sözleşmesi (imza değişmez) |
| F6, F7 | `todo.*`, `user.*`, `rbac.matrix.update`, `access.denied` çağrıları |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `api/src/middleware/audit_context.lua` | IP (güvenilir proxy zinciri) + User-Agent → `ngx.ctx.audit` |
| `api/src/repositories/audit_repo.lua` | insert, list (filtre), find, stats sorguları, export için keyset batch okuma |
| `api/src/services/audit_service.lua` | (genişletme) `record` → repo; `list`, `get`, `stats`, `export` |
| `api/src/models/audit.lua` | (genişletme) recursive `mask`, `serialize`, CSV satır dönüşümü |
| `api/src/handlers/audit.lua` | 4 endpoint: logs, logs/:id, stats, export (CSV streaming) |
| `api/src/router.lua` | (güncelleme) `/audit/*` route'ları, `audit.logs` page key |
| `api/spec/integration/audit_spec.lua` | (iskelet) entegrasyon matrisi testi; F11'de tamamlanır |

---

## Endpoint Özeti

| Metot | Yol | Page key | Başarı | Hatalar |
|---|---|---|---|---|
| GET | `/api/v1/audit/logs` | `audit.logs` | 200 | 401, 403, 422 |
| GET | `/api/v1/audit/logs/:id` | `audit.logs` | 200 | 401, 403, 404 `NOT_FOUND` |
| GET | `/api/v1/audit/stats` | `audit.logs` | 200 | 401, 403, 422 |
| GET | `/api/v1/audit/export` | `audit.logs` | 200 `text/csv` | 401, 403, 422 |

---

## Dosya Bazlı Tasarım

### 1. `api/src/middleware/audit_context.lua`

**Sorumluluk:** İsteğin gerçek istemci IP'sini ve UA'sını belirlemek. Zincirde `auth`'tan **önce**
(00 §11 #7), böylece `access.denied` ve `auth.login.failure` kayıtlarında da dolu olur.

**IP belirleme algoritması:**

```
remote = ngx.var.remote_addr
remote TRUSTED_PROXIES içinde DEĞİLSE → ip = remote        (X-Forwarded-For yok sayılır)
değilse:
   xff = ngx.var.http_x_forwarded_for  ("client, proxy1, proxy2")
   listeyi SAĞDAN sola gez:
      ilk "güvenilir olmayan" adres → ip
   hepsi güvenilirse → en soldaki
   geçerli IPv4/IPv6 değilse → remote
```

Sağdan sola gezmek, istemcinin sahte `X-Forwarded-For: 1.2.3.4` göndermesini etkisiz kılar (en
soldaki değer istemci kontrolündedir).

```lua
-- İstemci IP'si ve User-Agent'ı ngx.ctx.audit'e yazar (güvenilir proxy farkındalıklı).
local config = require("config")

local _M = {}

local UA_MAX = 512
local trusted = {}                                   -- modül yüklenirken bir kez kurulur
for ip in (config.TRUSTED_PROXIES or ""):gmatch("[^,%s]+") do trusted[ip] = true end

local function is_ip(s)
  return s and (s:match("^%d+%.%d+%.%d+%.%d+$") or s:match("^[%x:]+$")) ~= nil
end

local function client_ip()
  local remote = ngx.var.remote_addr
  if not trusted[remote] then return remote end
  local xff = ngx.var.http_x_forwarded_for
  if not xff then return remote end

  local hops = {}
  for part in xff:gmatch("[^,]+") do hops[#hops + 1] = part:match("^%s*(.-)%s*$") end
  for i = #hops, 1, -1 do
    if not trusted[hops[i]] then return is_ip(hops[i]) and hops[i] or remote end
  end
  return is_ip(hops[1]) and hops[1] or remote
end

function _M.handle(self)
  local ua = ngx.var.http_user_agent
  ngx.ctx.audit = {
    ip = client_ip(),
    user_agent = ua and ua:sub(1, UA_MAX) or nil,
  }
end

return _M
```

- `ponytail:` `TRUSTED_PROXIES` tam IP eşleşmesi; CIDR (`10.0.0.0/8`) gerekirse `resty.ipmatcher`.
- F5'teki login rate limit'i de `ngx.ctx.audit.ip`'yi kullanır → aynı güven modeli.
- nginx `real_ip_header` / `set_real_ip_from` modülü **kullanılmaz**: `remote_addr`'ı global değiştirir
  ve Lua tarafında tek bir doğruluk kaynağı daha anlaşılır. (Alternatif olarak seçilebilirdi; ikisi
  birden kullanılmaz.)

---

### 2. `api/src/models/audit.lua` (genişletme)

#### Maskeleme

```lua
-- Hassas alanları recursive olarak "***" ile değiştirir. Girdiyi DEĞİŞTİRMEZ, kopya döner.
local SENSITIVE = {
  password = true, password_hash = true, new_password = true,
  token = true, token_hash = true, refresh_token = true, access_token = true, secret = true,
}
local MAX_DEPTH = 10

local function mask(value, depth)
  if type(value) ~= "table" then return value end
  depth = depth or 0
  if depth >= MAX_DEPTH then return "[derinlik sınırı]" end
  local out = {}
  for k, v in pairs(value) do
    if type(k) == "string" and SENSITIVE[k:lower()] then
      out[k] = "***"
    else
      out[k] = mask(v, depth + 1)
    end
  end
  return setmetatable(out, getmetatable(value))   -- cjson.empty_array / array_mt korunur
end
_M.mask = mask
```

- Liste 00 §8 ile birebir aynıdır; yeni alan eklemek için önce 00 güncellenir.
- Diziler de gezilir (`pairs`), örn. `{ cells = [...] }`.
- `MAX_DEPTH` döngüsel tabloya karşı sigorta.

#### Serialize

```lua
function _M.serialize(row)
  return {
    id = tonumber(row.id),              -- BIGSERIAL → pgmoon string/number; JSON'da number
    user_id = row.user_id, user_email = row.user_email,
    action = row.action, entity_type = row.entity_type, entity_id = row.entity_id,
    old_value = row.old_value, new_value = row.new_value,   -- jsonb → pgmoon decode (json deserializer)
    ip_address = row.ip_address, user_agent = row.user_agent,
    status = row.status, error_message = row.error_message,
    created_at = row.created_at,
  }
end
```

- pgmoon'da `jsonb` otomatik decode için F3 pool'da `pg:set_type_deserializer(3802, "json")` ayarlı
  olmalı (değilse `SELECT ..., old_value::text` + `cjson.decode`). F3 ile teyit edilir.
- `BIGSERIAL` 2^53'ü aşmaz (pratikte); JSON number güvenli.

#### CSV satırı

```lua
_M.CSV_COLUMNS = { "id", "created_at", "user_email", "user_id", "action", "entity_type",
                   "entity_id", "status", "ip_address", "user_agent", "error_message",
                   "old_value", "new_value" }
```

---

### 3. `api/src/repositories/audit_repo.lua`

**Public API:**

```lua
audit_repo.insert(entry)                     --> true | nil, err
audit_repo.list(filters, page, per_page)     --> rows, total
audit_repo.find(id)                          --> row | nil
audit_repo.stats(filters)                    --> ...  (aşağıda, 4 ayrı fonksiyon)
audit_repo.batch_after(filters, before_id, limit)  --> rows   (export için keyset)
audit_repo.delete_older_than(days, limit)    --> deleted_count   (F10 kullanır)
```

#### Insert

```sql
INSERT INTO audit_logs
  (user_id, user_email, action, entity_type, entity_id,
   old_value, new_value, ip_address, user_agent, status, error_message)
VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8::inet, $9, $10, $11);
```

`old_value` / `new_value` `cjson.encode(mask(x))` string'i olarak gider (NULL için `nil` → `pg.NULL`).
`ip_address` geçersizse (`is_ip` false) NULL gönderilir — `::inet` cast hatası ana işlemi bozmasın.

#### Filtreler (liste, stats, export ortak)

| Parametre | SQL | Not |
|---|---|---|
| `user_id` | `user_id = $n` | uuid |
| `user_email` | `user_email ILIKE $n ESCAPE '\'` | `query.like_pattern` (F7) |
| `action` | `action = $n` veya `action LIKE $n` | `auth.*` → `auth.%` önek araması; başka joker yok |
| `entity_type` | `entity_type = $n` | |
| `entity_id` | `entity_id = $n` | |
| `status` | `status = $n` | `success\|failure` |
| `ip` | `ip_address = $n::inet` | |
| `from` | `created_at >= $n::timestamptz` | default: now − 7 gün |
| `to` | `created_at < $n::timestamptz` | default: now |

WHERE kurucu F6 `build_where` kalıbının aynısı (sabit SQL parçaları + `$n`). `from`/`to` her zaman
uygulanır → `idx_audit_created` indeksini kullanır, tam tablo taraması olmaz.

#### Liste

```sql
SELECT id, user_id, user_email, action, entity_type, entity_id, ip_address, user_agent,
       status, error_message, created_at,
       COUNT(*) OVER() AS total_count
FROM audit_logs {WHERE}
ORDER BY created_at DESC, id DESC
LIMIT $n OFFSET $m;
```

Listede `old_value` / `new_value` **seçilmez** (satır başı KB'lar olabilir); detay endpoint'inde gelir.
`total_count` büyük aralıklarda pahalıdır → `from`–`to` en fazla 90 gün (422 aksi halde).

#### Export için keyset batch

```sql
SELECT * FROM audit_logs
{WHERE} AND id < $k
ORDER BY id DESC
LIMIT $l;
```

İlk batch'te `$k = 9223372036854775807`. OFFSET yok → derin sayfada da sabit maliyet.

#### Stats sorguları

```sql
-- by_action
SELECT action, count(*)::int n FROM audit_logs {WHERE} GROUP BY action ORDER BY n DESC LIMIT 20;
-- by_status
SELECT status, count(*)::int n FROM audit_logs {WHERE} GROUP BY status;
-- by_day
SELECT date_trunc('day', created_at)::date AS day, count(*)::int n
FROM audit_logs {WHERE} GROUP BY 1 ORDER BY 1;
-- top_users
SELECT user_email, count(*)::int n FROM audit_logs {WHERE} AND user_email IS NOT NULL
GROUP BY user_email ORDER BY n DESC LIMIT 10;
-- failed_logins_24h (filtreden bağımsız, güvenlik göstergesi)
SELECT count(*)::int n FROM audit_logs
WHERE action = 'auth.login.failure' AND created_at > now() - interval '24 hours';
```

---

### 4. `api/src/services/audit_service.lua` (genişletme)

**Public API:**

```lua
audit_service.record(action, opts)       --> true | nil, err      (F5 sözleşmesi, değişmez)
audit_service.list(query)                --> { items, meta } | nil, err
audit_service.get(id)                    --> entry | nil, err
audit_service.stats(query)               --> stats | nil, err
audit_service.export(query, write_fn)    --> row_count | nil, err
```

#### `record`

```lua
function _M.record(action, opts)
  opts = opts or {}
  local ctx = ngx.ctx
  local identity = ctx.identity or {}
  local actx = ctx.audit or {}

  local entry = {
    user_id    = opts.user_id or identity.user_id,
    user_email = opts.user_email or identity.email,
    action = action,
    entity_type = opts.entity_type, entity_id = opts.entity_id and tostring(opts.entity_id),
    old_value = opts.old_value and cjson.encode(audit_model.mask(opts.old_value)),
    new_value = opts.new_value and cjson.encode(audit_model.mask(opts.new_value)),
    ip_address = actx.ip, user_agent = actx.user_agent,
    status = opts.status or "success",
    error_message = opts.error_message and opts.error_message:sub(1, 1000),
  }

  local ok, res, err = pcall(audit_repo.insert, entry)
  if not ok or not res then
    -- Audit hatası ana işlemi bozmaz ama kaybolmaz: tam kayıt ERR logunda (maskeli) kalır.
    ngx.log(ngx.ERR, "audit yazılamadı: ", tostring(err or res),
            " req_id=", ctx.req_id, " action=", action, " entry=", cjson.encode(entry))
    return nil, err or res
  end
  return true
end
```

- **Senkron** yazım (commit sonrası): audit uyumluluk kaydıdır; `ngx.timer.at(0)` ile asenkron
  yazmak yanıtı ~1 ms hızlandırır ama worker çökmesinde kayıp riski getirir → tercih edilmedi.
- DB hatasında tam kayıt error loguna düşer (log toplayıcıdan geri kazanılabilir).
- `action` 00 §8 listesinde değilse `ngx.WARN` loglanır (geliştirme hatasını erken yakalar;
  `APP_ENV=test`'te `error()` fırlatır → spec'ler yakalar).

#### `export`

```lua
-- Filtreye uyan kayıtları keyset batch'lerle okuyup write_fn'e CSV satırı olarak verir.
function _M.export(query, write_fn)
  local BATCH = 1000
  local MAX_ROWS = 100000
  local before, total = nil, 0
  local buf = table.new(BATCH, 0)                      -- satır tamponu tekrar kullanılır

  write_fn("\239\187\191")                             -- UTF-8 BOM (Excel Türkçe karakterler)
  write_fn(csv_line(audit_model.CSV_COLUMNS))

  repeat
    local rows, err = audit_repo.batch_after(query, before, BATCH)
    if not rows then return nil, err end
    table.clear(buf)
    for i, r in ipairs(rows) do buf[i] = csv_line(row_values(r)) end
    if #buf > 0 then write_fn(table.concat(buf)) end
    total = total + #rows
    before = rows[#rows] and rows[#rows].id
  until #rows < BATCH or total >= MAX_ROWS

  collectgarbage("collect")                            -- 00 §14: yoğun işlem sonrası
  return total
end
```

#### CSV kaçışı (RFC 4180 + formül enjeksiyonu)

```lua
local function csv_field(v)
  if v == nil or v == ngx.null then return "" end
  if type(v) == "table" then v = cjson.encode(v) end
  v = tostring(v)
  -- Excel/LibreOffice formül enjeksiyonu: = + - @ TAB CR ile başlayan hücreler metne zorlanır
  if v:find("^[=+%-@\t\r]") then v = "'" .. v end
  if v:find('[",\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
  return v
end

local function csv_line(values)
  local out = table.new(#values, 0)
  for i = 1, #values do out[i] = csv_field(values[i]) end
  return table.concat(out, ",") .. "\r\n"
end
```

---

### 5. `api/src/handlers/audit.lua`

```lua
-- Audit okuma endpoint'leri (yalnızca audit.logs yetkisi).
function _M.export(self)
  local q, err = parse_query(self.GET, { max_range_days = 90 })
  if not q then return errors.respond(err) end

  local fname = "audit-" .. os.date("!%Y%m%d-%H%M%S") .. ".csv"
  ngx.header["Content-Type"] = "text/csv; charset=utf-8"
  ngx.header["Content-Disposition"] = 'attachment; filename="' .. fname .. '"'
  ngx.header["Cache-Control"] = "no-store"
  ngx.header["X-Request-Id"] = ngx.ctx.req_id

  local count, serr = audit_service.export(q, function(chunk)
    ngx.print(chunk)
    ngx.flush(true)                               -- tamponu istemciye it, bellek sabit kalsın
  end)
  if not count then
    -- Header'lar gitti; status değiştirilemez. Dosya sonuna işaret yazılır + ERR logu.
    ngx.log(ngx.ERR, "audit export yarıda kaldı: ", tostring(serr), " req_id=", ngx.ctx.req_id)
    ngx.print("\r\n# HATA: export tamamlanamadı, req_id=", ngx.ctx.req_id, "\r\n")
  end
  return { layout = false, skip_render = true }
end
```

- Validation ve yetki hataları **ilk `ngx.print`'ten önce** oluşur → normal JSON hata yanıtı döner.
- `error_handler` xpcall'u: header gönderildikten sonra hata yakalanırsa JSON yazmaya çalışmaz
  (`ngx.headers_sent` kontrolü — F3'e eklenir).
- CSV export'un kendisi audit'lenmez (00 §8 listesinde yok). Gerekirse önce 00'a `audit.export`
  eklenir.

**Liste yanıtı:**

```json
{
  "data": [
    { "id": 1042, "created_at": "2026-09-18T10:12:00Z", "user_email": "user@todoapp.local",
      "action": "access.denied", "entity_type": "page", "entity_id": "users.list",
      "status": "failure", "ip_address": "172.18.0.1", "user_agent": "curl/8.5.0" }
  ],
  "meta": { "page": 1, "per_page": 50, "total": 1, "total_pages": 1 }
}
```

**Stats yanıtı:**

```json
{
  "data": {
    "range": { "from": "2026-09-11T00:00:00Z", "to": "2026-09-18T12:00:00Z" },
    "total": 523,
    "by_status": { "success": 498, "failure": 25 },
    "by_action": [ { "action": "todo.update", "count": 210 }, "..." ],
    "by_day": [ { "day": "2026-09-12", "count": 71 }, "..." ],
    "top_users": [ { "user_email": "user@todoapp.local", "count": 300 } ],
    "failed_logins_24h": 4
  }
}
```

Stats servisi F6'daki gibi 5 sorguyu `ngx.thread.spawn` ile paralel çalıştırır (00 §11 #16).

---

## Audit Entegrasyon Matrisi

Her satır F11'de `audit_spec.lua` / ilgili integration spec'te bir test vakasıdır.

| action | Üreten fonksiyon | Tetikleyen istek | status | Kontrol edilen alanlar |
|---|---|---|---|---|
| `auth.login.success` | `auth_service.login` | `POST /auth/login` (doğru) | success | user_id, user_email, ip, ua |
| `auth.login.failure` | `auth_service.login` | yanlış parola / pasif / rate limit | failure | `new_value.reason`, user_id NULL (olmayan e-posta) |
| `auth.logout` | `auth_service.logout` | `POST /auth/logout` | success | user_id |
| `auth.token.refresh` | `auth_service.refresh` | `POST /auth/refresh` | success | user_id |
| `auth.password.reset.request` | `auth_service.forgot_password` | `POST /auth/forgot-password` | success | `new_value.email`; kayıtsız e-postada user_id NULL |
| `auth.password.reset.success` | `auth_service.reset_password` | `POST /auth/reset-password` | success | user_id; `new_value`'da parola yok |
| `todo.create` | `todo_service.create` | `POST /todos` | success | entity_id, `new_value.title` |
| `todo.update` | `todo_service.replace/patch` | `PUT/PATCH /todos/:id` | success | old ≠ new |
| `todo.delete` | `todo_service.delete` | `DELETE /todos/:id` | success | `old_value` dolu |
| `user.create` | `user_service.create` | `POST /users` | success | `new_value.password_hash` yok veya `"***"` |
| `user.update` | `user_service.update` | `PUT /users/:id` | success | parola değişiminde `"***"` |
| `user.delete` | `user_service.delete` | `DELETE /users/:id` | success | `old_value.email` |
| `rbac.matrix.update` | `rbac_service.update_matrix/set_cell` | `PUT/PATCH /rbac/matrix` | success | yalnızca değişen hücreler |
| `access.denied` | `authorization.requires` | todouser → `GET /users` | failure | `new_value.page_key`, ip, ua |

Ek genel kontrol: `SELECT count(*) FROM audit_logs WHERE old_value::text ~* '"(password|password_hash|token|token_hash|refresh_token|access_token|secret|new_password)":\s*"[^*]'` → **0**.

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| audit_context auth'tan önce | 403 ve login failure kayıtlarında IP/UA dolu (00 §11 #7) |
| XFF sağdan sola + güvenilir proxy listesi | IP sahteciliği rate limit'i ve audit'i bozmasın |
| Senkron audit, commit sonrası, pcall | Kayıp riski en düşük; audit hatası iş hatasına dönüşmez |
| Maskeleme `record` içinde (tek nokta) | Çağıranın unutması imkânsız |
| Liste `old/new_value` seçmez | Yanıt boyutu ve sorgu maliyeti |
| Export: keyset + `ngx.flush` + tampon yeniden kullanımı | Sabit bellek, 100k satırda bile O(batch) |
| Tarih aralığı zorunlu (default 7 gün, max 90) | İndeks kullanımı garanti; `COUNT OVER` sınırlı |
| CSV formül enjeksiyonu kaçışı | Audit verisi kullanıcı girdisi içerir (e-posta, UA, başlık) |

## Kabul kriterleri (DoD)

- [ ] `TRUSTED_PROXIES` dışından gelen `X-Forwarded-For: 1.2.3.4` yok sayılır; kayıtta gerçek `remote_addr`.
- [ ] Güvenilir proxy arkasında `X-Forwarded-For: 1.2.3.4, 10.0.0.5` (10.0.0.5 güvenilir değil) → `10.0.0.5`.
- [ ] UA 512 karakterde kesilir.
- [ ] Entegrasyon matrisindeki 14 olayın her biri üretilir ve kontrol edilen alanlar doğrudur.
- [ ] Hassas alan regex kontrolü 0 satır döner.
- [ ] `GET /audit/logs` filtreleri (`action=auth.*`, `status=failure`, `user_email`, `from/to`) doğru; `from`–`to` > 90 gün → 422.
- [ ] `GET /audit/logs/:id` `old_value`/`new_value`'yu JSON nesne olarak döner (string değil); bilinmeyen id → 404; sayı olmayan id → 404.
- [ ] `GET /audit/stats` 5 bölümü döner; boş aralıkta sıfırlar/boş diziler.
- [ ] `GET /audit/export` `text/csv`, `attachment` header'ı, BOM, başlık satırı; `=HYPERLINK(...)` içeren alan `'=` ile başlar; virgül/tırnak/yeni satır içeren alanlar doğru tırnaklanır.
- [ ] 50 000 satırlık export sırasında worker RSS artışı < 20 MB (keyset + flush).
- [ ] audit_logs tablosu kilitliyken (`LOCK TABLE audit_logs IN ACCESS EXCLUSIVE MODE` başka oturumda, `DB_QUERY_TIMEOUT_MS` sonrası) `POST /todos` yine 201 döner; ERR logunda kayıt var.
- [ ] todouser tüm `/audit/*` → 403.

## Doğrulama

```bash
H_A="Authorization: Bearer $TOKEN_A"; H_U="Authorization: Bearer $TOKEN_U"

# access.denied üret
curl -s -o /dev/null localhost:28080/api/v1/users -H "$H_U" -H 'X-Forwarded-For: 6.6.6.6'

# Liste (sahte XFF kayda geçmemeli)
curl -s "localhost:28080/api/v1/audit/logs?action=access.denied&per_page=1" -H "$H_A" | jq '.data[0] | {action, ip_address, entity_id}'
# Beklenen: ip_address != "6.6.6.6"

# Önek filtresi
curl -s "localhost:28080/api/v1/audit/logs?action=auth.*&status=failure" -H "$H_A" | jq '[.data[].action] | unique'

# Detay
AID=$(curl -s "localhost:28080/api/v1/audit/logs?action=todo.update&per_page=1" -H "$H_A" | jq -r '.data[0].id')
curl -s localhost:28080/api/v1/audit/logs/$AID -H "$H_A" | jq '.data | {old_value, new_value}'

# Stats
curl -s "localhost:28080/api/v1/audit/stats?from=2026-09-01T00:00:00Z" -H "$H_A" | jq '.data | {total, by_status, failed_logins_24h}'

# Aralık sınırı
curl -s "localhost:28080/api/v1/audit/logs?from=2025-01-01T00:00:00Z" -H "$H_A" | jq -r .error.code   # VALIDATION_FAILED

# Export
curl -s -D - -o /tmp/audit.csv "localhost:28080/api/v1/audit/export?from=2026-09-01T00:00:00Z" -H "$H_A" | grep -i -E 'content-(type|disposition)'
head -c 3 /tmp/audit.csv | xxd | head -1        # ef bb bf
python3 -c "import csv;r=list(csv.reader(open('/tmp/audit.csv',encoding='utf-8-sig')));print(len(r), r[0][:4])"

# Formül enjeksiyonu
curl -s -X POST localhost:28080/api/v1/todos -H "$H_U" -H 'Content-Type: application/json' -d '{"title":"=HYPERLINK(\"http://x\")"}' >/dev/null
curl -s "localhost:28080/api/v1/audit/export?action=todo.create" -H "$H_A" | grep -c "'=HYPERLINK"   # ≥ 1

# Hassas alan taraması
docker compose exec postgres psql -U todo -tc \
  "SELECT count(*) FROM audit_logs WHERE coalesce(old_value::text,'') || coalesce(new_value::text,'') ~* '\"(password|password_hash|token|token_hash|refresh_token|access_token|secret|new_password)\": *\"[^*]';"
# Beklenen: 0

# Büyük export bellek testi
docker compose exec postgres psql -U todo -c \
  "INSERT INTO audit_logs (action, status, created_at) SELECT 'todo.update','success', now() - (random()*interval '6 days') FROM generate_series(1,50000);"
docker stats --no-stream todo-api & curl -s -o /dev/null "localhost:28080/api/v1/audit/export" -H "$H_A"; docker stats --no-stream todo-api
```

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| audit_logs hızlı büyür (her istek değil ama her yazma + 403) | F10 retention (30 gün, batch delete) |
| Senkron audit her yazmaya ~1 ms ekler | Kabul edildi; F11 wrk ile ölçülür |
| jsonb deserializer ayarlı değilse detay `old_value` string döner | F3 pool'da `set_type_deserializer`; DoD'de kontrol |
| Export yarıda kesilirse istemci eksik dosya alır | Sonda `# HATA` satırı + ERR logu; 100k satır tavanı |
| `COUNT(*) OVER()` büyük aralıklarda yavaş | 90 gün tavanı; gerekirse `total` yerine `has_more` (keyset) |
| Farklı saat dilimleri (`by_day`) | Oturum UTC; frontend yerel saate çevirir |
| Maskeleme listesi eksik kalırsa (yeni hassas alan) | Liste 00 §8'de; yeni alan eklerken DoD regex'i güncellenir |

## Tahmini Efor

**M** (1.5–2 gün): audit_context + maskeleme 0.5 gün, repo + liste/detay/stats 0.5 gün, CSV export 0.5 gün, entegrasyon matrisi testleri 0.5 gün.
