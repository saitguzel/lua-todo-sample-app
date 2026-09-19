# ═══ FAZ 7 — USERS + RBAC ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — error kodları `USER_NOT_FOUND`, `EMAIL_TAKEN`,
> `LAST_ADMIN`, `SELF_ACTION_FORBIDDEN`, `FORBIDDEN`, `CONFLICT` (§5), `RBAC_CACHE_TTL` (§6),
> page key'ler + kilit kuralı (§7), audit `user.*`, `rbac.matrix.update`, `access.denied` (§8),
> `rbac_cache` dict (§9), teknik düzeltme #8.

## Amaç

Admin'in kullanıcıları yönetebildiği (listele, görüntüle, oluştur, güncelle, sil) ve rol-sayfa
izin matrisini düzenleyebildiği API'nin çalışır hale gelmesi. `authorization` middleware'i
aktifleşir: her korumalı route bir `page_key` ister, izin `role_page_permissions` tablosundan
okunur, 60 sn shared dict cache'te tutulur; ret `403 FORBIDDEN` + `access.denied` audit üretir.
F6'daki todo route'larının yer tutucu `authz(...)` çağrıları bu fazda gerçek kontrole dönüşür.

## Önkoşullar

| Faz | Neden |
|---|---|
| F1 | `types.ROLES`, `types.PAGES`, parola politikası şeması |
| F2 | `users`, `role_page_permissions` tabloları + `rbac_defaults` seed |
| F3 | `query`, `with_transaction`, `router.chain`, `error_handler`, `lua_shared_dict rbac_cache` (nginx.conf) |
| F4 | `security/password.lua`, `models/user.lua` (`serialize`, maskeleme) |
| F5 | `auth` middleware, `audit_service.record`, minimal `user_repo` |
| F6 | `authz(...)` yer tutucuları bulunan todo route'ları |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `api/src/repositories/user_repo.lua` | (tamamlanır) list/count/insert/update/delete/count_active_admins_for_update |
| `api/src/repositories/rbac_repo.lua` | `role_page_permissions` okuma/upsert |
| `api/src/services/user_service.lua` | User CRUD iş kuralları: e-posta normalize, parola hash, self/last-admin korumaları, audit |
| `api/src/services/rbac_service.lua` | `can(role, page_key)`, matris okuma/yazma, cache (TTL 60 sn) + invalidation, kilit kuralı, audit |
| `api/src/models/rbac.lua` | Matris veri yapısı: satırlar → `{ role = { page = bool } }`, diff hesaplama |
| `api/src/handlers/users.lua` | 5 endpoint |
| `api/src/handlers/rbac.lua` | 4 endpoint |
| `api/src/middleware/authorization.lua` | `requires(page_key)` → 403 + `access.denied` |
| `api/src/handlers/auth.lua` | (güncelleme) `/auth/me` yanıtına `permissions` eklenir |
| `api/src/router.lua` | (güncelleme) `/users*`, `/rbac*` route'ları; F6 stub'ı gerçek `authorization` ile değişir |

---

## Endpoint Özeti

| Metot | Yol | Page key | Başarı | Hatalar |
|---|---|---|---|---|
| GET | `/api/v1/users` | `users.list` | 200 | 401, 403, 422 |
| GET | `/api/v1/users/:id` | `users.list` | 200 | 401, 403, 404 `USER_NOT_FOUND` |
| POST | `/api/v1/users` | `users.create` | 201 | 401, 403, 409 `EMAIL_TAKEN`, 422 |
| PUT | `/api/v1/users/:id` | `users.create` | 200 | 401, 403, 404, 409 `EMAIL_TAKEN` / `LAST_ADMIN` / `SELF_ACTION_FORBIDDEN`, 422 |
| DELETE | `/api/v1/users/:id` | `users.create` | 204 | 401, 403, 404, 409 `LAST_ADMIN` / `SELF_ACTION_FORBIDDEN` |
| GET | `/api/v1/rbac/pages` | `rbac.matrix` | 200 | 401, 403 |
| GET | `/api/v1/rbac/matrix` | `rbac.matrix` | 200 | 401, 403 |
| PUT | `/api/v1/rbac/matrix` | `rbac.matrix` | 200 | 401, 403, 409 `CONFLICT`, 422 |
| PATCH | `/api/v1/rbac/matrix/:role/:page_key` | `rbac.matrix` | 200 | 401, 403, 404 `NOT_FOUND`, 409 `CONFLICT`, 422 |

Prompt'taki `:page-key` → `:page_key` (00 §11 #8). URL'de gerçek değer yine `todos.edit` gibi noktalı
string'dir; Lapis `:param` varsayılan olarak `/` hariç her karakteri yakalar, nokta sorun değildir.

---

## Kullanıcı Yönetimi

### Validation şemaları (`shared/src/validation.lua` → `validation.schemas`)

| Şema | Alan | Kural |
|---|---|---|
| `user_create` | `email` | email, zorunlu, max 255 |
| | `password` | parola politikası (F5 ile aynı: 8–128, büyük+küçük+rakam), zorunlu |
| | `full_name` | string, opsiyonel, nullable, 1–255 |
| | `role` | enum `ROLES`, opsiyonel (default `todouser`) |
| | `is_active` | boolean, opsiyonel (default `true`) |
| `user_update` (PUT) | `email`, `full_name`, `role`, `is_active` zorunlu; `password` opsiyonel (verilirse değişir) |
| `user_list_query` | `q` (string ≤ 100, email/full_name araması), `role` (enum), `is_active` (`true`/`false`), `page`, `per_page`, `sort` (`created_at`, `email`, `full_name`, `last_login_at`, `role`) |

PUT'ta `password` opsiyoneldir: admin formunda parola alanı boş bırakılırsa değişmez. Bu,
"PUT = tam temsil" kuralının bilinçli istisnasıdır (parola okunabilir bir alan değildir).

### `api/src/repositories/user_repo.lua` (F5'e eklenenler)

| Fonksiyon | SQL |
|---|---|
| `list(filters, page, per_page, sort)` | `SELECT id, email, full_name, role, is_active, last_login_at, created_at, updated_at, COUNT(*) OVER() AS total_count FROM users {WHERE} ORDER BY {col} {dir}, id LIMIT $n OFFSET $m` |
| `insert(u)` | `INSERT INTO users (email, password_hash, full_name, role, is_active) VALUES ($1,$2,$3,$4::user_role,$5) RETURNING *` |
| `find_for_update(id)` | `SELECT * FROM users WHERE id = $1 FOR UPDATE` |
| `update(id, fields)` | Dinamik `SET` (F6 `SET_EXPR` kalıbı, sabit kolon whitelist'i) `RETURNING *` |
| `delete(id)` | `DELETE FROM users WHERE id = $1 RETURNING *` |
| `lock_active_admins()` | `SELECT id FROM users WHERE role = 'admin' AND is_active FOR UPDATE` → id listesi |

- `list` `password_hash` seçmez (savunma derinliği; model de zaten gizler).
- `q` filtresi: `(email ILIKE $n ESCAPE '\' OR full_name ILIKE $n ESCAPE '\')`, F6'daki kaçış fonksiyonu
  ortak yardımcıya (`db/query.lua` → `query.like_pattern(s)`) taşınır — iki repo aynı kodu kullanır.
- Unique ihlali (SQLSTATE `23505`, constraint `users_email_key`) → servis `EMAIL_TAKEN`'e çevirir.
  `db/query.lua` pgmoon hata mesajından SQLSTATE'i çıkarıp `err.sqlstate` olarak döner (F3).

### `api/src/services/user_service.lua`

**Public API:**

```lua
user_service.list(identity, query)          --> { items, meta } | nil, err
user_service.get(identity, id)              --> user | nil, err
user_service.create(identity, input)        --> user | nil, err
user_service.update(identity, id, input)    --> user | nil, err
user_service.delete(identity, id)           --> true | nil, err
```

#### Kurallar

| # | Kural | Hata |
|---|---|---|
| U1 | E-posta her zaman `lower(trim())` | — |
| U2 | Parola yalnızca argon2id hash olarak saklanır (F4 `password.hash`) | — |
| U3 | Admin kendini silemez | `SELF_ACTION_FORBIDDEN` |
| U4 | Admin kendi rolünü `todouser`'a düşüremez, kendini pasifleştiremez | `SELF_ACTION_FORBIDDEN` |
| U5 | Son aktif admin silinemez, düşürülemez, pasifleştirilemez | `LAST_ADMIN` |
| U6 | Aynı e-posta ikinci kez | `EMAIL_TAKEN` |
| U7 | Kullanıcı silinince todo'ları CASCADE silinir, audit kayıtlarında `user_id` NULL olur (şema), `user_email` korunur | — |

U3/U4 aslında U5'in özel hali değildir: iki admin varken de admin kendini düşüremez (yanlışlıkla
yetki kaybı). U5, başka bir admin'i son admin durumuna düşürmeyi engeller.

#### Update akışı

```
update(identity, id, input)
  ├─ new_hash = input.password and password.hash(input.password)     ← argon2 tx DIŞINDA
  ├─ with_transaction:
  │     old = user_repo.find_for_update(id)            → yoksa USER_NOT_FOUND
  │     demoting    = old.role == "admin" and input.role ~= "admin"
  │     deactivating = old.is_active and input.is_active == false
  │     if id == identity.user_id and (demoting or deactivating) → SELF_ACTION_FORBIDDEN
  │     if (demoting or deactivating) and old.role == "admin" and old.is_active then
  │        admins = user_repo.lock_active_admins()     ← FOR UPDATE: eşzamanlı düşürmeleri sıralar
  │        if #admins <= 1 → LAST_ADMIN
  │     end
  │     new = user_repo.update(id, fields + password_hash?)
  │           23505 → EMAIL_TAKEN
  ├─ audit user.update  old_value=mask(serialize(old))  new_value=mask(serialize(new))
  │     (parola değiştiyse new_value.password = "***" işaretiyle değişiklik görünür, değer görünmez)
  └─ return serialize(new)
```

**Yarış koşulu:** İki admin A ve B aynı anda birbirini düşürürse, `lock_active_admins()` satır
kilitleri iki transaction'ı sıralar; ikinci transaction güncel sayımı (1) görür → `LAST_ADMIN`.

#### Delete akışı

```
delete(identity, id)
  ├─ id == identity.user_id → SELF_ACTION_FORBIDDEN
  ├─ with_transaction:
  │     old = find_for_update(id)                 → USER_NOT_FOUND
  │     old admin+aktif ise lock_active_admins(); #admins <= 1 → LAST_ADMIN
  │     user_repo.delete(id)
  ├─ audit user.delete old_value=mask(serialize(old))
  └─ 204
```

Silinen kullanıcının geçerli access token'ı ≤15 dk kalır (F5 bilinen sınır); refresh `find_by_id`
boş döndüğü için reddedilir. Token'la yapılan istekler FK/404 ile başarısız olur (ör. todo create →
`USER_NOT_FOUND`).

### `api/src/handlers/users.lua`

F6 handler kalıbının aynısı: `valid_id` (UUID) → değilse `USER_NOT_FOUND`; list query parse;
create 201 + `Location`; delete 204. Yanıt `data` = `models/user.lua` `serialize()` (parola hash yok).

---

## RBAC

### Veri modeli

`role_page_permissions (role, page_key, can_access)`; `UNIQUE(role, page_key)`.
Satır yoksa izin **yok** (deny-by-default). Seed (F2 `rbac_defaults.lua`) tüm `ROLES × PAGES`
kombinasyonlarını yazar (00 §7 tablosu).

### `api/src/models/rbac.lua`

```lua
-- RBAC matris yardımcıları: DB satırları <-> { role = { page_key = bool } } dönüşümü ve diff.
local types = require("todo_shared.types")

local _M = {}

-- Satırlardan tam matris kurar; eksik hücreler false ile doldurulur.
function _M.from_rows(rows)
  local m = {}
  for _, role in ipairs(types.ROLES) do
    m[role] = {}
    for _, page in ipairs(types.PAGES) do m[role][page] = false end
  end
  for _, r in ipairs(rows) do
    if m[r.role] and m[r.role][r.page_key] ~= nil then m[r.role][r.page_key] = r.can_access end
  end
  return m
end

-- İki matris arasındaki değişen hücreleri döner: { { role, page_key, old, new }, ... }
function _M.diff(old, new) --[[ ... ]] end

-- Kilit kuralı: admin rolünün rbac.matrix izni kapatılamaz
function _M.violates_lock(role, page_key, value)
  return role == types.ROLES.ADMIN and page_key == "rbac.matrix" and value == false
end

return _M
```

`types.ROLES` / `types.PAGES`: F1'de tanımlanan sıralı diziler.

### `api/src/repositories/rbac_repo.lua`

| Fonksiyon | SQL |
|---|---|
| `all()` | `SELECT role, page_key, can_access FROM role_page_permissions ORDER BY role, page_key` |
| `by_role(role)` | `SELECT page_key, can_access FROM role_page_permissions WHERE role = $1::user_role` |
| `upsert(role, page_key, value)` | `INSERT INTO role_page_permissions (role, page_key, can_access) VALUES ($1::user_role, $2, $3) ON CONFLICT (role, page_key) DO UPDATE SET can_access = EXCLUDED.can_access` |
| `lock_all()` | `SELECT 1 FROM role_page_permissions FOR UPDATE` (matris yazımlarını sıralar) |

### `api/src/services/rbac_service.lua`

**Public API:**

```lua
rbac_service.can(role, page_key)                    --> bool          (sıcak path)
rbac_service.permissions_for(role)                  --> { [page_key] = bool } (9 anahtarın hepsi; cache'ten)
rbac_service.pages()                                --> [{ key, label, group }]
rbac_service.matrix()                               --> { roles, pages, matrix }
rbac_service.update_matrix(identity, matrix_input)  --> matrix | nil, err   (PUT)
rbac_service.set_cell(identity, role, page_key, v)  --> matrix | nil, err   (PATCH)
rbac_service.invalidate(role_or_nil)                --> nil
```

#### Cache (sıcak path)

```lua
local cjson  = require("cjson.safe")
local cache  = ngx.shared.rbac_cache
local config = require("config")

-- Rolün izin haritasını shared dict'ten okur; yoksa DB'den yükleyip TTL ile yazar.
local function role_map(role)
  local key = "rbac:" .. role
  local raw = cache:get(key)
  if raw then return cjson.decode(raw) end

  local rows, err = rbac_repo.by_role(role)
  if not rows then
    ngx.log(ngx.ERR, "rbac yüklenemedi: ", err)
    return nil                                   -- çağıran deny eder (fail-closed)
  end
  local map = {}
  for _, r in ipairs(rows) do map[r.page_key] = r.can_access end
  local ok, serr = cache:set(key, cjson.encode(map), config.RBAC_CACHE_TTL)
  if not ok then ngx.log(ngx.WARN, "rbac_cache set başarısız: ", serr) end
  return map
end

function _M.can(role, page_key)
  local map = role_map(role)
  return map ~= nil and map[page_key] == true
end
```

- **Fail-closed:** DB erişilemezse ve cache boşsa izin verilmez.
- JSON decode maliyeti istek başına ~µs; `ponytail:` per-worker LRU (`resty.lrucache`) katmanı
  ölçülürse eklenir, şu an gereksiz.
- İlk yüklemede birden fazla eşzamanlı istek aynı anda DB'ye gidebilir (cache stampede); rol sayısı
  2, sorgu ms altı → kilit (`resty.lock`) eklenmez.

#### Invalidation

```lua
function _M.invalidate(role)
  if role then cache:delete("rbac:" .. role)
  else for _, r in ipairs(types.ROLES) do cache:delete("rbac:" .. r) end end
end
```

- Shared dict tüm worker'larca paylaşıldığı için aynı instance'da değişiklik **anında** etkili.
- Çok instance'lı dağıtımda diğer instance'lar en geç `RBAC_CACHE_TTL` (60 sn) sonra görür — kabul
  edilen tutarlılık penceresi (prompt'taki 60 sn TTL'in amacı).

#### PUT `/rbac/matrix` akışı

```
update_matrix(identity, input)          input = { matrix = { admin = {...}, todouser = {...} } }
  ├─ doğrulama: bilinmeyen rol/page → VALIDATION_FAILED; değerler boolean
  ├─ kısmi matris kabul edilir (yalnızca gönderilen hücreler yazılır); eksik hücre = değişmez
  ├─ herhangi bir hücre violates_lock → CONFLICT ("Admin rolünün rbac.matrix izni kapatılamaz")
  ├─ with_transaction:
  │     rbac_repo.lock_all()
  │     old = rbac_model.from_rows(rbac_repo.all())
  │     changes = rbac_model.diff(old, merge(old, input.matrix))
  │     for each change: rbac_repo.upsert(role, page_key, new)
  ├─ commit sonrası: invalidate(nil)
  ├─ #changes > 0 ise audit rbac.matrix.update
  │     old_value = { cells = [ {role, page_key, value=old} ] }
  │     new_value = { cells = [ {role, page_key, value=new} ] }
  └─ return matrix()
```

> PUT'un "kısmi matris" kabul etmesi REST'te tam temsil beklentisinden sapmadır; frontend (F15) her
> zaman tam matrisi gönderir, API ise eksik hücreyi silmez (deny'a çevirmez) — yanlışlıkla eksik
> gövde gönderilmesinin herkesi kilitlemesini önler. Swagger'da (F9) belgelenir.

#### PATCH `/rbac/matrix/:role/:page_key`

Body `{ "can_access": true|false }`. Rol/page bilinmiyorsa `404 NOT_FOUND`; kilit ihlali `409 CONFLICT`;
aksi halde `update_matrix` ile aynı yol (tek hücreli matris). Değer aynıysa audit yazılmaz, 200 döner.

#### GET yanıtları

```json
// GET /rbac/pages
{ "data": [
  { "key": "dashboard",   "label": "Gösterge Paneli", "group": "genel" },
  { "key": "todos.list",  "label": "Görev Listesi",   "group": "todos" },
  { "key": "rbac.matrix", "label": "Yetki Matrisi",   "group": "admin", "locked_for": ["admin"] }
] }

// GET /rbac/matrix
{ "data": {
  "roles": ["admin", "todouser"],
  "pages": ["dashboard", "todos.list", "todos.create", "todos.edit", "users.list",
            "users.create", "rbac.matrix", "audit.logs", "settings"],
  "matrix": {
    "admin":    { "dashboard": true, "todos.list": true, "...": true },
    "todouser": { "dashboard": true, "todos.list": true, "users.list": false, "...": false }
  }
},
  "meta": { "cache_ttl": 60 } }
```

`meta.cache_ttl` = `RBAC_CACHE_TTL` (00 §6): matris değişikliğinin diğer worker'lara en geç kaç saniyede
yansıyacağını UI'da bilgi notu olarak göstermek için (F15). `PUT`/`PATCH` yanıtları da aynı zarfı döner.

`label` / `group` `shared/src/types.lua` → `PAGE_META` tablosundan gelir (F1; frontend menüsü de aynı kaynağı
kullanır). `locked_for` alanı frontend'in kilitli hücreyi devre dışı göstermesi içindir.

---

## `api/src/middleware/authorization.lua`

```lua
-- Sayfa bazlı yetki kontrolü: rol/page izni yoksa 403 döner ve access.denied audit'i yazar.
local rbac_service  = require("services.rbac_service")
local audit_service = require("services.audit_service")
local errors        = require("middleware.error_handler")

local _M = {}

-- Middleware fabrikası: route kaydında bir kez çağrılır, closure'ı her istekte çalışır.
function _M.requires(page_key)
  return function(self)
    local identity = ngx.ctx.identity            -- auth middleware'i önce çalışmış olmalı
    if identity and rbac_service.can(identity.role, page_key) then
      return                                     -- devam
    end

    audit_service.record("access.denied", {
      entity_type = "page", entity_id = page_key, status = "failure",
      new_value = { page_key = page_key, method = ngx.req.get_method(), path = ngx.var.uri },
    })
    return errors.respond(errors.new("FORBIDDEN", "Bu işlem için yetkiniz yok",
                                     { page_key = page_key }))
  end
end

return _M
```

- `identity` yoksa (zincir yanlış kurulmuşsa) yine 403 — fail-closed. Router testi (F11) her
  korumalı route'ta `auth.required`'ın `authorization`'dan önce geldiğini doğrular.
- `access.denied` yazımı `audit_context`'in doldurduğu IP/UA'yı kullanır (00 §11 #7 — zincir sırası).
- `ponytail:` access.denied için kayıt başına audit; saldırgan binlerce 403 üretirse tablo şişer.
  Retention (F10) bunu 30 günde temizler; gerekirse `rate_limit` dict ile dakikada IP başı 1 kayıt.

### `/auth/me` güncellemesi

```json
{ "data": { "user": { "id": "...", "email": "...", "role": "todouser", ... },
            "permissions": { "dashboard": true, "todos.list": true, "todos.create": true, "todos.edit": true,
                             "users.list": false, "users.create": false, "rbac.matrix": false,
                             "audit.logs": false, "settings": false } } }
```

`permissions = rbac_service.permissions_for(identity.role)` (F5'teki şekil; login/refresh yanıtı da aynı alanı
taşır — F5'te `types.default_permission` ile doldurulan geçici kaynak burada gerçek matrise bağlanır).
Frontend router guard'ı (F13) ve menü bu nesneyi kullanır; **yetki kararının asıl yeri yine API'dir**.

### `api/src/router.lua` güncellemesi

```lua
local requires = require("middleware.authorization").requires
local base = { cors.handle, logger.handle, audit_context.handle, auth.required }

app:match("/api/v1/users", respond_to({
  GET  = chain(with(base, requires("users.list")),   users_h.list),
  POST = chain(with(base, requires("users.create")), users_h.create),
}))
app:match("/api/v1/users/:id", respond_to({
  GET    = chain(with(base, requires("users.list")),   users_h.get),
  PUT    = chain(with(base, requires("users.create")), users_h.update),
  DELETE = chain(with(base, requires("users.create")), users_h.delete),
}))
app:get  ("/api/v1/rbac/pages",  chain(with(base, requires("rbac.matrix")), rbac_h.pages))
app:match("/api/v1/rbac/matrix", respond_to({
  GET = chain(with(base, requires("rbac.matrix")), rbac_h.matrix),
  PUT = chain(with(base, requires("rbac.matrix")), rbac_h.update_matrix),
}))
app:patch("/api/v1/rbac/matrix/:role/:page_key", chain(with(base, requires("rbac.matrix")), rbac_h.set_cell))
```

`with(base, mw)` yeni tabloyu route kaydında (modül yüklenirken) bir kez oluşturur.

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Admin'e "bypass" yok, admin de matristen geçer | Tek karar yolu; kilit kuralı admin'in kendini kilitlemesini önler |
| Deny-by-default + fail-closed | Eksik satır veya DB hatası yetki açmaz |
| Cache: shared dict JSON, TTL 60 sn, yazımda invalidate | Prompt gereksinimi; worker'lar arası tutarlı |
| `FOR UPDATE` ile son-admin kontrolü | Eşzamanlı düşürmelerde yarışsız |
| PUT matris kısmi | Eksik gövde kazara herkesi kilitlemez (belgelenmiş sapma) |
| Hard delete | Şema `ON DELETE CASCADE / SET NULL` ile tasarlanmış; soft delete kapsam dışı (`is_active` zaten var) |
| `permissions` `/auth/me`'de | Frontend guard için ek endpoint gerekmez |

## Kabul kriterleri (DoD)

- [ ] `todouser` token'ı ile `/users`, `/rbac/*`, `/audit/*` → `403 FORBIDDEN`; her biri için `access.denied` kaydı (IP ve UA dolu).
- [ ] Admin ile tüm `/users` ve `/rbac` endpoint'leri çalışır.
- [ ] `POST /users` parolayı argon2id olarak saklar (`password_hash` `$argon2id$` ile başlar); yanıtta hash yok.
- [ ] Büyük harfli e-posta ile oluşturma küçük harfe normalize edilir; aynı e-posta tekrar → `409 EMAIL_TAKEN`.
- [ ] PUT'ta `password` verilmezse eski parola geçerli kalır; verilirse yenisi.
- [ ] Admin kendini silemez / düşüremez / pasifleştiremez → `409 SELF_ACTION_FORBIDDEN`.
- [ ] Tek aktif admin başka bir admin tarafından düşürülemez → `409 LAST_ADMIN` (test: ikinci admin oluştur, birini düşür → OK; kalanı düşürme denemesi → 409).
- [ ] Kullanıcı silinince todo'ları silinir, audit kayıtlarında `user_id` NULL ama `user_email` dolu kalır.
- [ ] `GET /rbac/matrix` tüm rol × sayfa hücrelerini döner.
- [ ] `PATCH /rbac/matrix/todouser/todos.create {"can_access":false}` sonrası todouser `POST /todos` → 403 **anında** (aynı instance).
- [ ] `PATCH /rbac/matrix/admin/rbac.matrix {"can_access":false}` → `409 CONFLICT`.
- [ ] Bilinmeyen rol/sayfa ile PATCH → 404; PUT → 422.
- [ ] Matris değişikliği `rbac.matrix.update` audit'i üretir, `old_value`/`new_value` yalnızca değişen hücreleri içerir; değişmeyen PATCH audit üretmez.
- [ ] Cache: `rbac_cache` boşaltıldığında ilk istek DB'den yükler; DB kapalıyken cache boşsa korumalı route 403 (500 değil) döner ve ERR loglanır.
- [ ] `/auth/me` ve login yanıtı `permissions` nesnesini (`{ [page_key] = bool }`, 9 anahtar) matristen döner; matris değişince en geç `RBAC_CACHE_TTL` sn içinde yansır.
- [ ] `GET /rbac/matrix` yanıtında `meta.cache_ttl` var.

## Doğrulama

```bash
H_A="Authorization: Bearer $TOKEN_A"; H_U="Authorization: Bearer $TOKEN_U"; J='Content-Type: application/json'

# Todouser admin alanına giremez
curl -s localhost:28080/api/v1/users -H "$H_U" | jq -r .error.code             # FORBIDDEN

# Kullanıcı oluştur
NEW=$(curl -s -X POST localhost:28080/api/v1/users -H "$H_A" -H "$J" \
  -d '{"email":"Ayse@Todoapp.Local","password":"Ayse1234!","full_name":"Ayşe","role":"todouser"}' \
  | tee /dev/stderr | jq -r .data.id)
# Beklenen: 201, .data.email == "ayse@todoapp.local"

# Aynı e-posta
curl -s -X POST localhost:28080/api/v1/users -H "$H_A" -H "$J" \
  -d '{"email":"ayse@todoapp.local","password":"Ayse1234!"}' | jq -r .error.code  # EMAIL_TAKEN

# Liste + filtre
curl -s "localhost:28080/api/v1/users?role=todouser&q=ay&sort=-created_at" -H "$H_A" | jq '.meta.total'

# Kendini düşürme
ME=$(curl -s localhost:28080/api/v1/auth/me -H "$H_A" | jq -r .data.id)
curl -s -X PUT localhost:28080/api/v1/users/$ME -H "$H_A" -H "$J" \
  -d '{"email":"admin@todoapp.local","full_name":"Admin","role":"todouser","is_active":true}' \
  | jq -r .error.code                                                           # SELF_ACTION_FORBIDDEN

# RBAC matrisi
curl -s localhost:28080/api/v1/rbac/matrix -H "$H_A" | jq .data.matrix.todouser

# Todouser'ın todo oluşturma iznini kapat → anında 403
curl -s -X PATCH localhost:28080/api/v1/rbac/matrix/todouser/todos.create -H "$H_A" -H "$J" -d '{"can_access":false}' | jq .data.matrix.todouser
curl -s -X POST localhost:28080/api/v1/todos -H "$H_U" -H "$J" -d '{"title":"x"}' | jq -r .error.code   # FORBIDDEN
curl -s -X PATCH localhost:28080/api/v1/rbac/matrix/todouser/todos.create -H "$H_A" -H "$J" -d '{"can_access":true}' >/dev/null

# Kilit kuralı
curl -s -X PATCH localhost:28080/api/v1/rbac/matrix/admin/rbac.matrix -H "$H_A" -H "$J" -d '{"can_access":false}' | jq -r .error.code  # CONFLICT

# Me permissions
curl -s localhost:28080/api/v1/auth/me -H "$H_U" | jq .data.permissions

# Audit
docker compose exec postgres psql -U todo -c \
  "SELECT action, status, entity_id, host(ip_address) FROM audit_logs WHERE action IN ('access.denied','rbac.matrix.update','user.create') ORDER BY id DESC LIMIT 10;"

# Unit
busted api/spec/rbac_spec.lua
```

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| Admin kendini kilitler | Kilit kuralı + self-action kuralları |
| Rol değişikliği token'a ≤15 dk yansımaz (JWT'deki `role`) | Belgelenir. Yetki düşürme için kritikse: `auth` middleware'inde rolü DB/cache'ten okumak (ek sorgu) — bu fazda yapılmaz |
| Çok instance'da RBAC cache 60 sn eski | Prompt'un kabul ettiği TTL; belgelenir |
| `access.denied` flood | Retention + opsiyonel örnekleme (not) |
| Silinen kullanıcının token'ı | ≤15 dk; FK hataları 404'e çevrilir, 500 değil |
| Nokta içeren path parametresi (`todos.edit`) Lapis'te | Lapis `:param` `/` dışındaki karakterleri yakalar; spec ile doğrulanır |

## Tahmini Efor

**L** (2–3 gün): user repo/service + korumalar 1 gün, RBAC repo/service/cache 0.5 gün, handler'lar + middleware + router 0.5 gün, testler 0.5–1 gün.
