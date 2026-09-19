# ═══ FAZ 6 — TODOS CRUD + STATS ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — error kodları (§5), page key'ler ve veri
> kapsamı (§7), audit olayları `todo.*` (§8), yanıt zarfı ve sayfalama (§15), teknik düzeltmeler #6, #14, #16.

## Amaç

Todo kaynağı için tam CRUD, filtreleme/sayfalama/sıralama ve istatistik endpoint'inin çalışır hale
gelmesi. `todouser` yalnızca kendi todo'larını görür ve değiştirir; `admin` tüm todo'ları görür,
başka kullanıcı adına todo oluşturabilir. Her yazma işlemi `todo.create/update/delete` audit kaydı
üretir. Bu fazda RBAC middleware'i henüz yoktur (F7); route'lar `authorization.requires(...)`
çağrısı için yer tutucu ile kaydedilir ve F7'de aktifleşir.

## Önkoşullar

| Faz | Neden |
|---|---|
| F1 | `types.TODO_STATUS`, `types.TODO_PRIORITY`, `validation` DSL (`uuid`, `datetime`, `array_of`, `enum`) |
| F2 | `todos` tablosu, `todos_updated` trigger'ı, `todos(user_id, status)` indeksi |
| F3 | `db/query.lua` (`query`, `with_transaction`), `router.lua` (`chain`), `error_handler` |
| F5 | `middleware/auth.lua` (`ngx.ctx.identity`), `services/audit_service.lua` (`record`) |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `api/src/models/todo.lua` | `from_row(row)`, `serialize(todo)`, alan listeleri (sıralama whitelist'i, güncellenebilir alanlar) |
| `api/src/repositories/todo_repo.lua` | Parametreli SQL: list (dinamik filtre), find, find_for_update, insert, update, delete, stats sorguları |
| `api/src/services/todo_service.lua` | Sahiplik/kapsam, PUT/PATCH semantiği, `completed_at` kuralı, transaction + audit |
| `api/src/handlers/todos.lua` | 7 endpoint: query/body parse, validation, service çağrısı, yanıt zarfı |
| `api/src/router.lua` | (güncelleme) `/todos*` route'ları — `/todos/stats` **önce** |
| `api/spec/integration/todos_crud_spec.lua` | (iskelet) F11'de genişletilir |

---

## Endpoint Özeti

| Metot | Yol | Page key (F7'de aktif) | Başarı | Hatalar |
|---|---|---|---|---|
| GET | `/api/v1/todos/stats` | `dashboard` | 200 | 401, 403, 422 |
| GET | `/api/v1/todos` | `todos.list` | 200 | 401, 403, 422 |
| GET | `/api/v1/todos/:id` | `todos.list` | 200 | 401, 403, 404 `TODO_NOT_FOUND` |
| POST | `/api/v1/todos` | `todos.create` | 201 | 401, 403, 404 `USER_NOT_FOUND`, 422 |
| PUT | `/api/v1/todos/:id` | `todos.edit` | 200 | 401, 403, 404, 422 |
| PATCH | `/api/v1/todos/:id` | `todos.edit` | 200 | 401, 403, 404, 422 |
| DELETE | `/api/v1/todos/:id` | `todos.edit` | 204 | 401, 403, 404 |

`:id` UUID formatında değilse `404 TODO_NOT_FOUND` döner (PG `invalid input syntax for type uuid`
hatasına hiç ulaşılmaz; geçersiz id ile var olmayan id ayırt edilemez).

---

## Veri Modeli

### `api/src/models/todo.lua`

```lua
-- Todo modeli: DB satırını public JSON görünümüne çevirir. I/O yapmaz.
local cjson = require("cjson.safe")

local _M = {}

-- Sıralamaya izin verilen alanlar (SQL'e yalnızca bu whitelist'ten kolon adı girer)
_M.SORTABLE = {
  created_at = true, updated_at = true, due_date = true,
  priority = true, status = true, title = true,
}

-- PATCH ile güncellenebilir alanlar
_M.MUTABLE = { "title", "description", "status", "priority", "due_date", "tags" }

function _M.serialize(row)
  return {
    id = row.id, user_id = row.user_id,
    title = row.title,
    description = row.description,          -- NULL → cjson.null (pgmoon convert_null)
    status = row.status, priority = row.priority,
    due_date = row.due_date,
    tags = row.tags or cjson.empty_array,   -- NULL veya {} → [] (JSON'da hiçbir zaman {})
    created_at = row.created_at, updated_at = row.updated_at,
    completed_at = row.completed_at,
    owner_email = row.owner_email,          -- yalnızca admin listesinde JOIN ile gelir
  }
end

return _M
```

- pgmoon `convert_null = true` (F3 pool ayarı) → NULL kolonlar `pg.NULL` (= `cjson.null`) olur,
  JSON'da `null` yazılır.
- `text[]` → pgmoon varsayılan array deserializer'ı ile Lua dizisi; boş dizi `cjson.empty_array`
  ile işaretlenir (cjson aksi halde `{}` yazar).
- Zaman damgaları PG'den ISO-8601 string gelir; oturum `SET TIME ZONE 'UTC'` (F3 pool) → `...Z`.

**JSON örneği:**

```json
{
  "id": "6f1c1a4e-2b7d-4c3e-9f0a-7c5b2e1d9a33",
  "user_id": "0b9c1e7a-4d2f-4a8b-b6c1-2e3f4a5b6c7d",
  "title": "Sunum hazırla",
  "description": "Q3 raporu için",
  "status": "in_progress",
  "priority": "high",
  "due_date": "2026-09-25T17:00:00Z",
  "tags": ["iş", "rapor"],
  "created_at": "2026-09-18T09:00:00Z",
  "updated_at": "2026-09-18T10:30:00Z",
  "completed_at": null
}
```

---

## Validation Şemaları

F1 DSL ile; frontend de aynısını kullanır → `shared/src/validation.lua` → `validation.schemas`.

| Şema | Alan | Kural |
|---|---|---|
| `todo_create` | `title` | string, zorunlu, trim, 1–255 |
| | `description` | string, opsiyonel, nullable, max 10 000 |
| | `status` | enum `TODO_STATUS`, opsiyonel (default `pending`) |
| | `priority` | enum `TODO_PRIORITY`, opsiyonel (default `medium`) |
| | `due_date` | datetime (ISO-8601, zaman dilimi zorunlu), opsiyonel, nullable |
| | `tags` | array_of(string 1–30, trim), max 10 eleman, opsiyonel |
| | `user_id` | uuid, opsiyonel (yalnızca admin anlamlı) |
| `todo_replace` (PUT) | `todo_create` ile aynı, `user_id` hariç |
| `todo_patch` | tüm alanlar opsiyonel; **en az bir alan** zorunlu; `title` null olamaz |
| `todo_list_query` | `status`, `priority` (enum), `q` (string ≤ 100), `tag` (string ≤ 30), `due_before`, `due_after` (datetime), `user_id` (uuid), `page` (int ≥ 1), `per_page` (int 1–100), `sort` (string) |

- Bilinmeyen alanlar **reddedilir** (`VALIDATION_FAILED`, `details.<alan> = ["bilinmeyen alan"]`)
  — yazım hatalı alanın sessizce yok sayılmasını önler.
- `tags` normalize: trim, boşları at, tekrarları kaldır (sıra korunur). Büyük/küçük harf korunur.
- Query string değerleri string gelir; `page`, `per_page` şemadan önce `tonumber` ile çevrilir.

---

## Dosya Bazlı Tasarım

### 1. `api/src/repositories/todo_repo.lua`

**Public API:**

```lua
todo_repo.list(filters, page, per_page, sort)  --> rows, total
todo_repo.find(id)                              --> row | nil
todo_repo.find_for_update(id)                   --> row | nil     (tx içinde, FOR UPDATE)
todo_repo.insert(fields)                        --> row
todo_repo.update(id, fields)                    --> row           (yalnızca verilen alanlar)
todo_repo.delete(id)                            --> row | nil     (RETURNING *)
todo_repo.stats_by_status(user_id_or_nil)       --> { pending = n, in_progress = n, completed = n }
todo_repo.stats_by_priority(user_id_or_nil)     --> { low = n, medium = n, high = n }
todo_repo.stats_due(user_id_or_nil)             --> { overdue = n, due_today = n, due_week = n }
todo_repo.stats_completed_daily(user_id_or_nil, days) --> { { day = "2026-09-12", count = 3 }, ... }
```

#### 1.1 Dinamik filtre — güvenli SQL kurucu

Kolon adları **yalnızca sabit string'lerden**, değerler **yalnızca `$n` parametre** olarak girer.

```lua
-- Filtrelere göre WHERE cümlesi ve parametre listesi kurar.
local function build_where(f)
  local clauses, params = {}, {}
  local function add(sql_fmt, value)
    params[#params + 1] = value
    clauses[#clauses + 1] = sql_fmt:format("$" .. #params)
  end

  if f.user_id    then add("t.user_id = %s", f.user_id) end
  if f.status     then add("t.status = %s::todo_status", f.status) end
  if f.priority   then add("t.priority = %s::todo_priority", f.priority) end
  if f.tag        then add("%s = ANY(t.tags)", f.tag) end
  if f.due_before then add("t.due_date < %s::timestamptz", f.due_before) end
  if f.due_after  then add("t.due_date >= %s::timestamptz", f.due_after) end
  if f.q then
    -- LIKE joker karakterleri kaçışlanır; kullanıcı % ve _ ile tarama yapamaz
    local escaped = f.q:gsub("[\\%%_]", "\\%0")
    add("(t.title ILIKE %s ESCAPE '\\')", "%" .. escaped .. "%")
  end

  local where = #clauses > 0 and ("WHERE " .. table.concat(clauses, " AND ")) or ""
  return where, params
end
```

#### 1.2 Liste sorgusu (tek sorguda toplam)

```sql
SELECT t.*, u.email AS owner_email, COUNT(*) OVER() AS total_count
FROM todos t
JOIN users u ON u.id = t.user_id
{WHERE}
ORDER BY {sort_col} {ASC|DESC} NULLS LAST, t.id
LIMIT ${n+1} OFFSET ${n+2};
```

- `sort` parametresi `-created_at` / `due_date` biçiminde; `model.SORTABLE`'da yoksa
  `VALIDATION_FAILED`. Varsayılan `-created_at`.
- `priority` sıralaması enum sırasıyla (`low < medium < high`) — PG enum doğal sırası yeterli.
- `COUNT(*) OVER()` ile ayrı `COUNT` sorgusu yok. Sayfa boşsa (`page` > son sayfa) `total` için
  ayrıca `SELECT count(*)` yapılır — nadir durum.
- `, t.id` tie-breaker: aynı `created_at`'lı satırlarda sayfalar arası kayma olmaz.

#### 1.3 Insert

```sql
INSERT INTO todos (user_id, title, description, status, priority, due_date, tags, completed_at)
VALUES ($1, $2, $3, $4::todo_status, $5::todo_priority, $6::timestamptz,
        ARRAY(SELECT jsonb_array_elements_text($7::jsonb)),
        CASE WHEN $4 = 'completed' THEN now() END)
RETURNING *;
```

`tags` JSON string olarak (`cjson.encode(tags)`) tek parametre ile gönderilir → `text[]`'e PG'de
dönüştürülür. Böylece dizi literal'i elle kurulmaz, injection yüzeyi yok.

#### 1.4 Update (yalnızca verilen alanlar)

```lua
-- fields: { title = ..., status = ..., description = cjson.null, ... }
-- Sabit kolon eşlemesi: alan adı → SQL ifadesi şablonu
local SET_EXPR = {
  title       = "title = %s",
  description = "description = %s",
  status      = "status = %s::todo_status",
  priority    = "priority = %s::todo_priority",
  due_date    = "due_date = %s::timestamptz",
  tags        = "tags = ARRAY(SELECT jsonb_array_elements_text(%s::jsonb))",
}
```

`status` alanı güncelleniyorsa ek olarak:

```sql
completed_at = CASE
  WHEN $k::todo_status = 'completed' THEN COALESCE(completed_at, now())
  ELSE NULL
END
```

- `cjson.null` değeri pgmoon'a `NULL` olarak geçer (açık null ile "alanı temizle").
- `updated_at` trigger'la (F2) güncellenir, uygulama yazmaz.
- `RETURNING *` → servis yeni değeri audit'e yazar.

#### 1.5 Stats sorguları

```sql
-- by_status
SELECT status, count(*)::int AS n FROM todos WHERE ($1::uuid IS NULL OR user_id = $1) GROUP BY status;

-- by_priority
SELECT priority, count(*)::int AS n FROM todos WHERE ($1::uuid IS NULL OR user_id = $1) GROUP BY priority;

-- due
SELECT
  count(*) FILTER (WHERE due_date < now() AND status <> 'completed')::int                          AS overdue,
  count(*) FILTER (WHERE due_date::date = current_date AND status <> 'completed')::int             AS due_today,
  count(*) FILTER (WHERE due_date >= now() AND due_date < now() + interval '7 days'
                   AND status <> 'completed')::int                                                  AS due_week
FROM todos WHERE ($1::uuid IS NULL OR user_id = $1);

-- completed_daily (son N gün, boş günler 0)
SELECT d::date AS day, count(t.id)::int AS count
FROM generate_series(current_date - ($2::int - 1), current_date, interval '1 day') d
LEFT JOIN todos t ON t.completed_at::date = d::date AND ($1::uuid IS NULL OR t.user_id = $1)
GROUP BY d ORDER BY d;
```

Eksik enum anahtarları servis katmanında `0` ile doldurulur (JSON'da her zaman üç anahtar).

---

### 2. `api/src/services/todo_service.lua`

**Public API** (her fonksiyon `identity`'yi ilk argüman alır):

```lua
todo_service.list(identity, query)          --> { items, meta } | nil, err
todo_service.get(identity, id)              --> todo | nil, err
todo_service.create(identity, input)        --> todo | nil, err
todo_service.replace(identity, id, input)   --> todo | nil, err   (PUT)
todo_service.patch(identity, id, input)     --> todo | nil, err   (PATCH)
todo_service.delete(identity, id)           --> true | nil, err
todo_service.stats(identity, query)         --> stats | nil, err
```

#### 2.1 Kapsam kuralı (tek yerde)

```lua
local ADMIN = types.ROLES.ADMIN

-- todouser için filtre her zaman kendi id'sine sabitlenir; admin isterse user_id ile daraltır.
local function scope_user_id(identity, requested)
  if identity.role == ADMIN then return requested end   -- nil = hepsi
  return identity.user_id
end

-- Tekil erişim: başkasının todo'su "yok" gibi davranır (varlık sızıntısı yok).
local function can_touch(identity, row)
  return row and (identity.role == ADMIN or row.user_id == identity.user_id)
end
```

`todouser` `?user_id=<başkası>` gönderirse sessizce kendi id'si kullanılır (403 değil — liste
davranışı öngörülebilir kalır, bilgi sızmaz).

#### 2.2 Create

```
create(identity, input)
  ├─ owner = identity.user_id
  ├─ input.user_id verildiyse:
  │     todouser ve input.user_id ~= identity.user_id → FORBIDDEN
  │     admin → owner = input.user_id
  ├─ row, err = todo_repo.insert({...defaults uygulanmış...})
  │     FK ihlali (SQLSTATE 23503) → USER_NOT_FOUND
  ├─ audit todo.create  entity_id=row.id  new_value=serialize(row)
  └─ return serialize(row)            → handler 201 + Location: /api/v1/todos/<id>
```

#### 2.3 Replace (PUT) ve Patch (PATCH)

| | PUT | PATCH |
|---|---|---|
| Anlam | Kaynağın tam temsili | Kısmi değişiklik |
| Eksik alan | Default'a döner: `description=NULL`, `status='pending'`, `priority='medium'`, `due_date=NULL`, `tags='{}'` | Dokunulmaz |
| `title` | Zorunlu | Opsiyonel, null olamaz |
| `user_id` | Değiştirilemez (sahiplik devri kapsam dışı) | Değiştirilemez |

Ortak akış:

```
with_transaction(function()
  old = todo_repo.find_for_update(id)
  if not can_touch(identity, old) then return nil, TODO_NOT_FOUND end
  fields = (PUT) full_fields(input) | (PATCH) pick(input, model.MUTABLE)
  if next(fields) == nil then return serialize(old) end      -- değişiklik yok, audit yok
  new = todo_repo.update(id, fields)
  return new, old
end)
→ commit sonrası: audit todo.update  old_value=serialize(old) new_value=serialize(new)
```

- `FOR UPDATE` ile eşzamanlı iki PATCH'in `old_value` audit'i tutarlı olur.
- Audit commit sonrası yazılır (F5 kararı).
- Optimistic concurrency (`If-Match`/ETag) **yok** — son yazan kazanır. Frontend optimistic UI
  (F14) için yeterli. Ekleme yolu: `updated_at`'ten ETag.

#### 2.4 Delete

```
row = todo_repo.find(id); can_touch? değilse TODO_NOT_FOUND
deleted = todo_repo.delete(id)          -- RETURNING *; nil ise yarış → TODO_NOT_FOUND
audit todo.delete old_value=serialize(deleted)
→ 204
```

#### 2.5 Stats (`ngx.thread.spawn` ile paralel)

```lua
function _M.stats(identity, query)
  local uid = scope_user_id(identity, query.user_id)
  local days = 7

  -- Bağımsız aggregate sorguları paralel; her light thread havuzdan kendi bağlantısını alır.
  local threads = {
    ngx.thread.spawn(todo_repo.stats_by_status, uid),
    ngx.thread.spawn(todo_repo.stats_by_priority, uid),
    ngx.thread.spawn(todo_repo.stats_due, uid),
    ngx.thread.spawn(todo_repo.stats_completed_daily, uid, days),
  }

  local results = {}
  for i, th in ipairs(threads) do
    local ok, res, err = ngx.thread.wait(th)
    if not ok or not res then
      for j = i + 1, #threads do ngx.thread.kill(threads[j]) end   -- kalanları temizle
      return nil, errors.new("INTERNAL_ERROR", "İstatistik alınamadı", nil, err or res)
    end
    results[i] = res
  end

  local by_status = results[1]
  local total = (by_status.pending or 0) + (by_status.in_progress or 0) + (by_status.completed or 0)
  return {
    total = total,
    by_status = fill_zero(by_status, types.TODO_STATUS),
    by_priority = fill_zero(results[2], types.TODO_PRIORITY),
    overdue = results[3].overdue, due_today = results[3].due_today, due_week = results[3].due_week,
    completion_rate = total > 0 and math.floor(by_status.completed * 1000 / total) / 10 or 0,
    completed_last_7_days = results[4],
    scope = uid and "user" or "all",
  }
end
```

- Transaction içinde **çağrılmaz** (thread'ler ayrı bağlantı kullanır; `ngx.ctx.tx_conn`
  paylaşılmamalı). `db/query.lua` tx dışı çağrıda bağlantıyı havuzdan alıp geri bırakır.
- Maliyet: 4 bağlantı eşzamanlı; `DB_POOL_SIZE=20` ile sorun yok.

**Yanıt örneği:**

```json
{
  "data": {
    "total": 42,
    "by_status": { "pending": 20, "in_progress": 12, "completed": 10 },
    "by_priority": { "low": 8, "medium": 24, "high": 10 },
    "overdue": 3, "due_today": 2, "due_week": 7,
    "completion_rate": 23.8,
    "completed_last_7_days": [ { "day": "2026-09-12", "count": 1 }, "..." ],
    "scope": "user"
  }
}
```

---

### 3. `api/src/handlers/todos.lua`

```lua
-- Todo HTTP handler'ları.
local _M = {}

local UUID_RE = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function valid_id(self)
  return type(self.params.id) == "string" and self.params.id:match(UUID_RE) ~= nil
end

function _M.get(self)
  if not valid_id(self) then
    return errors.respond(errors.new("TODO_NOT_FOUND", "Todo bulunamadı"))
  end
  local todo, err = todo_service.get(ngx.ctx.identity, self.params.id)
  if not todo then return errors.respond(err) end
  return { status = 200, json = { data = todo } }
end

function _M.list(self)
  local q, err = parse_list_query(self.GET)        -- tonumber + validation.todo_list_query
  if not q then return errors.respond(err) end
  local result, serr = todo_service.list(ngx.ctx.identity, q)
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result.items, meta = result.meta } }
end

function _M.create(self)
  -- ... validation.todo_create → service.create
  return { status = 201, json = { data = todo },
           headers = { Location = "/api/v1/todos/" .. todo.id } }
end

function _M.delete(self)
  -- ...
  return { status = 204, layout = false }
end

return _M
```

`meta` şekli 00 §15: `{ page, per_page, total, total_pages }`.

### 4. `api/src/router.lua` güncellemesi

```lua
local authz = authorization.requires      -- F7'de gerçek; bu fazda her zaman izin veren stub
local base  = { cors.handle, logger.handle, audit_context.handle, auth.required }

-- DİKKAT: /todos/stats, /todos/:id'den ÖNCE kaydedilir (00 §11 #14)
app:get   ("/api/v1/todos/stats", chain(with(base, authz("dashboard")),    todos_h.stats))
app:get   ("/api/v1/todos",       chain(with(base, authz("todos.list")),   todos_h.list))
app:post  ("/api/v1/todos",       chain(with(base, authz("todos.create")), todos_h.create))
app:get   ("/api/v1/todos/:id",   chain(with(base, authz("todos.list")),   todos_h.get))
app:put   ("/api/v1/todos/:id",   chain(with(base, authz("todos.edit")),   todos_h.replace))
app:patch ("/api/v1/todos/:id",   chain(with(base, authz("todos.edit")),   todos_h.patch))
app:delete("/api/v1/todos/:id",   chain(with(base, authz("todos.edit")),   todos_h.delete))
```

Lapis aynı path'e farklı metotlar için `app:match(path, respond_to{ GET=..., PUT=... })` de
kullanılabilir; hangisi F3'te seçildiyse o kalıp izlenir. `405 Method Not Allowed` Lapis
`respond_to` ile otomatik gelir → tercih edilen: `respond_to`.

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Başkasının todo'su → 404 (403 değil) | Varlık sızıntısı yok (00 §5 `TODO_NOT_FOUND`) |
| Kapsam kuralı serviste tek fonksiyon | RBAC (sayfa erişimi) ile veri kapsamı ayrı kavramlar (00 §7) |
| `tags` JSON parametresi → `jsonb_array_elements_text` | Dizi literal'i elle kurulmaz; tek `$n` ile güvenli |
| `COUNT(*) OVER()` | Liste + toplam tek round-trip |
| Offset sayfalama | Kullanıcı başına küçük veri; `per_page ≤ 100`. `ponytail:` derin sayfalarda keyset'e geçiş |
| `completed_at` SQL `CASE` ile | Kural tek yerde, yarış koşulu yok |
| Stats'ta `ngx.thread.spawn` | Prompt'taki "concurrent" gereksiniminin anlamlı tek kullanım yeri (00 §11 #16) |
| Bilinmeyen alan → 422 | Sessiz veri kaybını önler |
| `tags` için GIN indeks yok | `ponytail:` `tag` filtresi kullanıcı kapsamında seq-scan'e düşer; admin tüm-tablo filtresinde yavaşlarsa `CREATE INDEX ... USING gin(tags)` |

## Kabul kriterleri (DoD)

- [ ] `todouser` ile `GET /todos` yalnızca kendi todo'larını döner; `?user_id=<admin_id>` sonucu değiştirmez.
- [ ] `admin` ile `GET /todos` tüm kullanıcıların todo'larını `owner_email` ile döner; `?user_id=` ile daraltılabilir.
- [ ] `todouser` başka kullanıcının todo id'si ile GET/PUT/PATCH/DELETE → `404 TODO_NOT_FOUND`.
- [ ] Geçersiz UUID (`/todos/abc`) → 404, 500 değil.
- [ ] `POST /todos` 201 + `Location` header; default `status=pending`, `priority=medium`, `tags=[]`.
- [ ] Admin `user_id` ile başkası adına oluşturabilir; var olmayan `user_id` → `404 USER_NOT_FOUND`; todouser başkasının `user_id`'si ile → `403 FORBIDDEN`.
- [ ] PUT'ta gönderilmeyen `description` NULL olur; PATCH'te dokunulmaz.
- [ ] PATCH `{"description": null}` açıklamayı temizler.
- [ ] `status → completed`: `completed_at` dolar; tekrar `completed` PATCH'i `completed_at`'i değiştirmez; `→ pending`: NULL olur.
- [ ] `updated_at` her güncellemede değişir (trigger).
- [ ] Filtreler: `status`, `priority`, `q`, `tag`, `due_before`, `due_after` ayrı ayrı ve birlikte doğru sonuç verir; `q=%` literal `%` arar.
- [ ] `sort=-due_date` çalışır; `sort=password_hash` → 422.
- [ ] `per_page=101` → 422; `meta.total` ve `total_pages` doğru.
- [ ] `GET /todos/stats` üç status ve üç priority anahtarını her zaman döner (boş kullanıcıda `0`), `completed_last_7_days` 7 eleman.
- [ ] Her create/update/delete için `audit_logs`'ta `todo.*` kaydı; update'te `old_value` ve `new_value` farklı.
- [ ] Değişiklik içermeyen PATCH audit kaydı üretmez.
- [ ] Tüm SQL `$n` parametreli: `grep -nE '\.\.\s*(input|params|f)\.' api/src/repositories/todo_repo.lua` boş.

## Doğrulama

```bash
TOKEN_U=$(curl -s -X POST localhost:28080/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"user@todoapp.local","password":"User123!"}' | jq -r .data.access_token)
TOKEN_A=$(curl -s -X POST localhost:28080/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"admin@todoapp.local","password":"Admin123!"}' | jq -r .data.access_token)
H_U="Authorization: Bearer $TOKEN_U"; H_A="Authorization: Bearer $TOKEN_A"; J='Content-Type: application/json'

# Create
ID=$(curl -s -X POST localhost:28080/api/v1/todos -H "$H_U" -H "$J" \
  -d '{"title":"Süt al","priority":"high","tags":["market","ev"],"due_date":"2026-09-20T18:00:00Z"}' \
  | tee /dev/stderr | jq -r .data.id)
# Beklenen: 201, .data.status == "pending"

# List + filtre
curl -s "localhost:28080/api/v1/todos?priority=high&sort=-created_at&per_page=5" -H "$H_U" | jq '.meta, (.data | length)'

# Patch → completed
curl -s -X PATCH localhost:28080/api/v1/todos/$ID -H "$H_U" -H "$J" -d '{"status":"completed"}' | jq .data.completed_at
# Beklenen: ISO zaman damgası

# Put (eksik alanlar default'a döner)
curl -s -X PUT localhost:28080/api/v1/todos/$ID -H "$H_U" -H "$J" -d '{"title":"Süt al (2)"}' | jq '.data | {status, tags, due_date}'
# Beklenen: {"status":"pending","tags":[],"due_date":null}

# Admin başka kullanıcının todo'sunu görür
curl -s localhost:28080/api/v1/todos/$ID -H "$H_A" | jq .data.owner_email

# Admin'in todo'su todouser'a 404
AID=$(curl -s -X POST localhost:28080/api/v1/todos -H "$H_A" -H "$J" -d '{"title":"Admin işi"}' | jq -r .data.id)
curl -s -o /dev/null -w '%{http_code}\n' localhost:28080/api/v1/todos/$AID -H "$H_U"      # 404

# Geçersiz id
curl -s -o /dev/null -w '%{http_code}\n' localhost:28080/api/v1/todos/abc -H "$H_U"       # 404

# Validation
curl -s -X POST localhost:28080/api/v1/todos -H "$H_U" -H "$J" -d '{"title":"","priority":"urgent","foo":1}' | jq .error
# Beklenen: code VALIDATION_FAILED, details.title / details.priority / details.foo

# Stats
curl -s localhost:28080/api/v1/todos/stats -H "$H_U" | jq .data

# Delete
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE localhost:28080/api/v1/todos/$ID -H "$H_U"  # 204

# Audit
docker compose exec postgres psql -U todo -c \
  "SELECT action, entity_id, old_value->>'status' o, new_value->>'status' n FROM audit_logs WHERE action LIKE 'todo.%' ORDER BY id DESC LIMIT 5;"
```

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| Route sırası: `/todos/stats` `:id` olarak yakalanır | Önce kaydedilir + UUID kontrolü (stats UUID değil → yine de 404 olur, sessiz hata değil) |
| `cjson` boş tabloyu `{}` yazar (`tags`) | `cjson.empty_array`; spec'te `tags == []` kontrolü |
| `ILIKE '%q%'` büyük tabloda yavaş | Kullanıcı kapsamında küçük; gerekirse `pg_trgm` GIN indeks (F18 notu) |
| `ngx.thread.spawn` + transaction bağlantısı karışması | Stats tx dışında çağrılır; `query.lua` tx bağlantısını yalnızca `ngx.ctx.tx_conn` varsa ve aynı thread'deyse kullanır |
| Zaman dilimi: `due_date::date = current_date` sunucu TZ'ye bağlı | Oturum UTC; "bugün" UTC'ye göre — frontend kullanıcıya belirtir. İleride `?tz=` parametresi |
| Enum cast hatası (validation atlanırsa) | Handler her zaman validation'dan geçirir; PG hatası 500 olarak loglanır, istemciye detay sızmaz |

## Tahmini Efor

**M** (1.5–2 gün): repo + dinamik filtre 0.5 gün, servis + PUT/PATCH semantiği 0.5 gün, stats + handler + testler 0.5–1 gün.
