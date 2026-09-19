# ═══ FAZ 1 — SHARED KÜTÜPHANE ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — error kodları (§5), page key'ler (§7), teknik düzeltme #2 (5.1 ∩ 5.4 alt kümesi).

## Amaç

Backend (LuaJIT) ve frontend (Wasmoon / Lua 5.4) tarafından **aynı kaynak koddan** kullanılan `todo-shared` kütüphanesini yazmak: enum'lar ve sayfa anahtarları (`types`), şema tabanlı doğrulayıcı (`validation`), error kodları ve HTTP eşlemesi (`protocol`). Bu fazın sonunda kütüphane LuaRocks ile yerel olarak kurulabilir ve busted spec'leri **iki yorumlayıcıda** (LuaJIT 2.1 ve Lua 5.4) yeşildir.

## Önkoşullar

- FAZ 0 (dizinler, `.luacheckrc`, Makefile iskeleti).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `shared/src/types.lua` | `ROLES`, `TODO_STATUS`, `TODO_PRIORITY`, `PAGES`, `DEFAULT_PERMISSIONS`, yardımcı `is_member` |
| `shared/src/validation.lua` | Şema DSL'i + `validate(schema, input, opts)` |
| `shared/src/protocol.lua` | `ERR` sabitleri, `HTTP_STATUS` map, `http_status(code)`, `error_body(...)`, `API_PREFIX` |
| `rockspecs/todo-shared-0.1.0-1.rockspec` | Yerel LuaRocks paketi (`todo_shared.types` vb. modül adları) |
| `shared/spec/shared_spec.lua` | busted spec'leri |
| `Makefile` | `test.shared` hedefi eklenir |

## Modül Adlandırma

Rockspec modülleri şu adlarla kurar; hem backend hem frontend **aynı `require` yolunu** kullanır:

| require | Dosya |
|---|---|
| `todo_shared.types` | `shared/src/types.lua` |
| `todo_shared.validation` | `shared/src/validation.lua` |
| `todo_shared.protocol` | `shared/src/protocol.lua` |

Dev ortamında (rock kurulmadan) `lua_package_path` içine `/app/shared/?.lua` değil, `package.preload` veya bir `todo_shared/` symlink'i gerekir. Karar: `shared/src/` altında gerçek dizin adı `todo_shared` **değil**; bunun yerine API konteynerinde mount hedefi `/app/lib/todo_shared` yapılır ve `lua_package_path "/app/lib/?.lua;..."` (F3). Frontend bundle'ı modül adlarını manifestte `todo_shared.*` olarak yazar (F12). Böylece kaynak ağaç prompt'taki gibi kalır.

## Dosya Bazlı Tasarım

### Lua 5.1 ∩ 5.4 Uyumluluk Kuralları (tüm `shared/src/*`)

| Yasak | Neden | Alternatif |
|---|---|---|
| `//` tamsayı bölme | 5.1'de yok | `math.floor(a / b)` |
| `goto`, `::label::` | LuaJIT'te var ama 5.1 std değil; luacheck uyarır | erken `return` / flag |
| `<const>`, `<close>` | 5.4'e özgü | normal `local` |
| `&`, `|`, `~`, `<<` | 5.3+ | kullanılmaz (gerekmiyor) |
| `utf8.*` | 5.3+ | UTF-8 uzunluğu için yardımcı `utf8_len` (aşağıda) |
| `math.type`, `math.tointeger` | 5.3+ | `n == math.floor(n)` |
| `table.unpack` / `unpack` | 5.1'de global `unpack` | `local unpack = table.unpack or unpack` |
| `setfenv`, `getfenv`, `loadstring` | 5.4'te yok | kullanılmaz |
| `%g` pattern sınıfı | 5.2+ | `%S` |
| `string.format("%d", 3.0)` | 5.4'te float için hata | `string.format("%d", math.floor(x))` |

`#` operatörü yalnızca dizi tablolarında (hole'suz) kullanılır. Tüm modüller `ngx`, `js` veya herhangi bir global'e **dokunmaz** (saf Lua).

### `shared/src/types.lua`

```lua
-- Backend ve frontend'in paylaştığı enum'lar ve RBAC sayfa anahtarları.
-- Değerler veritabanı ENUM'ları (001/002 migration) ile birebir aynı olmalıdır.
local _M = {}

_M.ROLES         = { "admin", "todouser" }
_M.TODO_STATUS   = { "pending", "in_progress", "completed" }
_M.TODO_PRIORITY = { "low", "medium", "high" }

-- Sıra UI'daki (RBAC matrisi) sütun sırasıdır
_M.PAGES = {
  "dashboard", "todos.list", "todos.create", "todos.edit",
  "users.list", "users.create", "rbac.matrix", "audit.logs", "settings",
}

-- Sayfa görünen adları ve grupları (GET /rbac/pages, frontend menüsü, RBAC matris başlıkları)
_M.PAGE_META = {
  dashboard        = { label = "Gösterge Paneli",   group = "genel" },
  ["todos.list"]   = { label = "Görev Listesi",     group = "todos" },
  ["todos.create"] = { label = "Görev Oluşturma",   group = "todos" },
  ["todos.edit"]   = { label = "Görev Düzenleme",   group = "todos" },
  ["users.list"]   = { label = "Kullanıcı Listesi", group = "admin" },
  ["users.create"] = { label = "Kullanıcı Yönetimi", group = "admin" },
  ["rbac.matrix"]  = { label = "Yetki Matrisi",     group = "admin" },
  ["audit.logs"]   = { label = "Denetim Kayıtları", group = "admin" },
  settings         = { label = "Ayarlar",           group = "admin" },
}

-- Varsayılan izinler (seed ve "sıfırla" için); 00-genel-bakis §7
_M.DEFAULT_PERMISSIONS = {
  admin    = { ["*"] = true },
  todouser = { dashboard = true, ["todos.list"] = true,
               ["todos.create"] = true, ["todos.edit"] = true },
}

-- Değiştirilemez hücreler: { role, page_key }
_M.LOCKED_PERMISSIONS = { { role = "admin", page_key = "rbac.matrix" } }

-- Audit olay adları (00-genel-bakis §8 ile birebir, aynı sıra); audit filtre select'i ve spec enum'u için
_M.AUDIT_ACTIONS = {
  "auth.login.success", "auth.login.failure", "auth.logout", "auth.token.refresh",
  "auth.password.reset.request", "auth.password.reset.success",
  "todo.create", "todo.update", "todo.delete",
  "user.create", "user.update", "user.delete",
  "rbac.matrix.update", "access.denied",
}

-- Dizi → set dönüşümü (O(1) üyelik kontrolü için modül yüklenirken bir kez)
local function to_set(list) ... end
_M.ROLE_SET, _M.STATUS_SET, _M.PRIORITY_SET, _M.PAGE_SET = ...

function _M.is_member(set, value) return set[value] == true end

-- Rol + sayfa için varsayılan izin
function _M.default_permission(role, page_key) ... end  -- → boolean

-- ROLES × PAGES varsayılan matrisi; PUT /rbac/matrix gövdesi (schemas.rbac_matrix) şeklinde
function _M.default_matrix() ... end  -- → { permissions = { {role, page_key, can_access}, ... } }

return _M
```

**Sıralı diziler:** `ROLES`, `TODO_STATUS`, `TODO_PRIORITY`, `PAGES`, `AUDIT_ACTIONS` doğrudan sıralı dizilerdir (enum,
OpenAPI `enum`, UI select/sütun sırası için); ayrı `*_LIST` adları **yoktur**. Üyelik kontrolü için `*_SET` kullanılır.

API:

| Fonksiyon | Dönüş |
|---|---|
| `default_permission(role, page_key)` | `boolean` |
| `default_matrix()` | `{ permissions = { {role, page_key, can_access}, ... } }` (F15 "varsayılana sıfırla") |
| `is_locked(role, page_key)` | `boolean` |
| `is_member(set, value)` | `boolean` |

### `shared/src/protocol.lua`

```lua
-- API protokol sözleşmesi: error kodları, HTTP status eşlemesi, yanıt zarfı yardımcıları.
local _M = {}

_M.API_PREFIX = "/api/v1"

-- 00-genel-bakis §5 ile birebir; yeni kod eklemek o dokümanın güncellenmesini gerektirir
_M.ERR = {
  VALIDATION_FAILED     = "VALIDATION_FAILED",
  BAD_REQUEST           = "BAD_REQUEST",
  UNAUTHORIZED          = "UNAUTHORIZED",
  TOKEN_EXPIRED         = "TOKEN_EXPIRED",
  TOKEN_REVOKED         = "TOKEN_REVOKED",
  INVALID_CREDENTIALS   = "INVALID_CREDENTIALS",
  ACCOUNT_DISABLED      = "ACCOUNT_DISABLED",
  FORBIDDEN             = "FORBIDDEN",
  NOT_FOUND             = "NOT_FOUND",
  TODO_NOT_FOUND        = "TODO_NOT_FOUND",
  USER_NOT_FOUND        = "USER_NOT_FOUND",
  EMAIL_TAKEN           = "EMAIL_TAKEN",
  CONFLICT              = "CONFLICT",
  LAST_ADMIN            = "LAST_ADMIN",
  SELF_ACTION_FORBIDDEN = "SELF_ACTION_FORBIDDEN",
  RESET_TOKEN_INVALID   = "RESET_TOKEN_INVALID",
  RATE_LIMITED          = "RATE_LIMITED",
  PAYLOAD_TOO_LARGE     = "PAYLOAD_TOO_LARGE",
  INTERNAL_ERROR        = "INTERNAL_ERROR",
  MAIL_FAILED           = "MAIL_FAILED",
  DB_UNAVAILABLE        = "DB_UNAVAILABLE",
}

_M.HTTP_STATUS = {
  VALIDATION_FAILED = 422, BAD_REQUEST = 400,
  UNAUTHORIZED = 401, TOKEN_EXPIRED = 401, TOKEN_REVOKED = 401, INVALID_CREDENTIALS = 401,
  ACCOUNT_DISABLED = 403, FORBIDDEN = 403,
  NOT_FOUND = 404, TODO_NOT_FOUND = 404, USER_NOT_FOUND = 404,
  EMAIL_TAKEN = 409, CONFLICT = 409, LAST_ADMIN = 409, SELF_ACTION_FORBIDDEN = 409,
  RESET_TOKEN_INVALID = 400, RATE_LIMITED = 429, PAYLOAD_TOO_LARGE = 413,
  INTERNAL_ERROR = 500, MAIL_FAILED = 502, DB_UNAVAILABLE = 503,
}

-- Sıralı kod listesi (00 §5 tablo sırası); OpenAPI Error.code enum'u ve spec testleri için
_M.CODE_LIST = { "VALIDATION_FAILED", "BAD_REQUEST", "UNAUTHORIZED", ... }  -- 21 kod

-- Bilinmeyen kod 500'e düşer (fail-safe)
function _M.http_status(code) return _M.HTTP_STATUS[code] or 500 end

-- Varsayılan Türkçe kullanıcı mesajları (handler özel mesaj vermezse; frontend toast metni)
_M.DEFAULT_MESSAGES = { VALIDATION_FAILED = "Girdi doğrulanamadı", ... }

-- Kod → Türkçe mesaj; bilinmeyen kod → "Beklenmeyen bir hata oluştu"
function _M.message(code) ... end

-- Hata nesnesi: { code, message, details }
function _M.new_error(code, message, details) ... end

-- Yanıt gövdesi: { error = { code, message, details, req_id } }
function _M.error_body(err, req_id) ... end

-- Frontend: yanıtın hata olup olmadığını ve kodunu çıkarır
function _M.parse_error(body) ... end   -- → err | nil

-- Frontend: bu hata token yenilemeyi tetiklemeli mi?
function _M.is_refreshable(code) return code == _M.ERR.TOKEN_EXPIRED end

return _M
```

Tasarım notu: `HTTP_STATUS`, `CODE_LIST` ve `DEFAULT_MESSAGES` anahtarlarının `ERR` ile birebir örtüştüğü spec ile garanti edilir (her `ERR` için status + mesaj var, fazlası yok). Yalnızca istemci tarafı kodlar (`NETWORK_ERROR`, `INVALID_RESPONSE`) bu modüle eklenmez; `web/src/fetch.lua` kendi mesajlarını taşır (00 §5).

### `shared/src/validation.lua`

**Şema DSL'i** — şemalar düz Lua tablolarıdır; kural kurucular (builder) küçük tablolar döndürür:

```lua
local v = require("todo_shared.validation")
local types = require("todo_shared.types")

local todo_create = v.schema({
  title       = v.string({ min = 1, max = 255, trim = true }),
  description = v.optional(v.string({ max = 10000 })),
  status      = v.optional(v.enum(types.TODO_STATUS)),
  priority    = v.optional(v.enum(types.TODO_PRIORITY)),
  due_date    = v.optional(v.nullable(v.datetime())),
  tags        = v.optional(v.array_of(v.string({ min = 1, max = 50 }), { max = 20, unique = true })),
})

local clean, errors = v.validate(todo_create, input)
-- clean  : yalnızca şemada tanımlı alanlar, trim/normalize edilmiş kopya
-- errors : nil | { title = { "zorunlu alan" }, tags = { "[2]: en fazla 50 karakter" } }
```

**Kural kurucular:**

| Kurucu | Seçenekler | Hata mesajları (TR) |
|---|---|---|
| `string(opts)` | `min`, `max` (UTF-8 karakter), `pattern`, `trim`, `lower` | `metin olmalı`, `en az %d karakter`, `en fazla %d karakter`, `geçersiz biçim` |
| `integer(opts)` | `min`, `max` | `tamsayı olmalı`, `en az %d`, `en fazla %d` |
| `boolean()` | — | `true/false olmalı` |
| `enum(list)` | — | `geçersiz değer: %s (izinli: a, b, c)` |
| `email()` | `max = 255`, otomatik `lower` + `trim` | `geçerli bir e-posta olmalı` |
| `uuid()` | — | `geçerli bir UUID olmalı` |
| `datetime()` | ISO-8601 (`YYYY-MM-DDTHH:MM:SS(.sss)?(Z|±HH:MM)`) | `ISO-8601 tarih/saat olmalı` |
| `password()` | min 8, max 128; ≥1 büyük, ≥1 küçük, ≥1 rakam | `en az 8 karakter`, `en az bir büyük harf içermeli`, … |
| `array_of(rule, opts)` | `min`, `max`, `unique` | `dizi olmalı`, `en fazla %d eleman`, `tekrarlı değer`, eleman hataları `[i]: mesaj` |
| `optional(rule)` | alan yoksa atla | — |
| `nullable(rule)` | `nil`/`cjson.null`/`js null` → `NULL` sentinel | — |
| `schema(fields, opts)` | `strict = true` (bilinmeyen alan → hata) | `bilinmeyen alan` |

**Zorunluluk:** `optional` ile sarılmayan her alan zorunludur → `zorunlu alan`.

**`null` temsili:** Backend'de `cjson.null` (lightuserdata), frontend'de JS köprüsünden gelen null. Validator bu ikisini tanımak için `opts.null_values` alır; kütüphane içinde `_M.NULL` sentinel'i vardır ve `clean` tablosunda `NULL` olarak döner — repo bunu SQL `NULL`'a, serializer `cjson.null`'a çevirir. Böylece "alan gönderilmedi" (PATCH'te dokunma) ile "alan `null` gönderildi" (temizle) ayrışır.

**API:**

| Fonksiyon | İmza | Dönüş |
|---|---|---|
| `validate` | `(schema, input, opts?)` | `clean, nil` \| `nil, errors` |
| `validate_partial` | `(schema, input, opts?)` | PATCH için: tüm alanlar opsiyonel sayılır; ama en az bir alan olmalı (`{ _ = {"en az bir alan gönderilmeli"} }`) |
| `utf8_len` | `(s)` | UTF-8 karakter sayısı (5.1 uyumlu, `s:gsub("[\128-\191]", "")` ile) |
| `is_uuid` | `(s)` | boolean |
| `NULL` | sentinel | |

`opts`:
- `null_values = { cjson.null }` — girişte null sayılacak değerler.
- `strict` — şema seviyesindekini ezer.

**Algoritma (özet):**

```
validate(schema, input):
  input tablo değilse → nil, { _ = {"nesne olmalı"} }
  errors = {}; clean = {}
  strict ise: input'taki her k, schema.fields'te yoksa → errors[k] = {"bilinmeyen alan"}
  her (name, rule) in schema.fields:
    val = input[name]
    val null_values içindeyse → val = NULL
    val == nil:
      rule.optional değilse → errors[name] = {"zorunlu alan"}
      devam
    val == NULL:
      rule.nullable değilse → errors[name] = {"boş olamaz"}; değilse clean[name] = NULL
      devam
    ok, out_or_msgs = rule.check(val)
    ok → clean[name] = out ; değilse errors[name] = msgs
  next(errors) ~= nil → return nil, errors
  return clean
```

Her `rule` şu şekilde tablodur: `{ kind = "string", optional = false, nullable = false, check = function(val) ... end }`. `optional()` / `nullable()` kopyalayıp bayrağı set eder (orijinal kural değişmez → şemalar modül seviyesinde paylaşılabilir).

**Regex'ler (Lua pattern):**

- UUID: `^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$`
- E-posta: `^[%w%.%%%+%-_]+@[%w%.%-]+%.%a%a+$` (pragmatik; RFC 5322 değil — kasıtlı)
- Datetime: `^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)` + sonek kontrolü; ay 1–12, gün 1–31, saat 0–23 aralık kontrolü.

**Hazır şemalar nerede?** Endpoint şemaları shared'da **değil**, kullanan tarafta (backend handler'ları ve frontend view'ları aynı tanımı istiyorsa) `shared/src/validation.lua` içinde `_M.schemas` altında tutulur — frontend form validation'ı backend ile aynı kuralları kullanır:

| `schemas.*` | Kullanan |
|---|---|
| `login` (`email`, `password` string min 1) | auth handler, login view |
| `forgot_password` (`email`) | auth handler, forgot view |
| `reset_password` (`token` string 64 hex, `new_password` password()) | auth handler, reset view |
| `refresh` (`refresh_token`) | auth handler, fetch.lua |
| `todo_create`, `todo_update` (PUT: title zorunlu), `todo_patch` (validate_partial) | todos handler, todos view |
| `user_create` (`email`, `password`, `full_name?`, `role`, `is_active?`) | users handler, users view |
| `user_update` (hepsi opsiyonel, `password?`) | users handler, users view |
| `rbac_cell` (`can_access` boolean) | rbac handler |
| `rbac_matrix` (`permissions` array_of `{role, page_key, can_access}`) | rbac handler, matrix view |

Liste sorgu parametreleri (`page`, `per_page`, `sort`, filtreler) string gelir; bunlar için `v.query_int({min,max,default})` yardımcı kuralı vardır (string → sayı çevirir).

### `rockspecs/todo-shared-0.1.0-1.rockspec`

```lua
package = "todo-shared"
version = "0.1.0-1"
source = { url = "git+file:///dev/null" }  -- yerel kurulum: luarocks make
description = {
  summary = "Todo uygulaması ortak tipler, doğrulama ve protokol",
  license = "MIT",
}
dependencies = { "lua >= 5.1, < 5.5" }
build = {
  type = "builtin",
  modules = {
    ["todo_shared.types"]      = "shared/src/types.lua",
    ["todo_shared.validation"] = "shared/src/validation.lua",
    ["todo_shared.protocol"]   = "shared/src/protocol.lua",
  },
}
```

Kurulum (repo kökünden): `luarocks make rockspecs/todo-shared-0.1.0-1.rockspec --local`.
`source.url` yerel kullanımda kullanılmaz; yayın gerekirse (YAGNI) güncellenir.

### `shared/spec/shared_spec.lua`

`package.path` başa `shared/src/?.lua` ekleyen ve `todo_shared.*` adlarını `package.preload` ile yönlendiren küçük bir bootstrap ile başlar (rock kurulmadan çalışsın diye).

Test grupları:

| describe | it (özet) |
|---|---|
| `types` | enum değerleri migration ENUM'larıyla aynı (sabit liste karşılaştırması); `PAGES` 9 eleman; `default_permission("admin", x)` hepsi true; todouser yalnızca 4 sayfa; `is_locked("admin","rbac.matrix")`; `AUDIT_ACTIONS` 14 eleman; `default_matrix()` 18 hücre ve `schemas.rbac_matrix`'ten geçer |
| `protocol` | her `ERR` için `HTTP_STATUS` ve `DEFAULT_MESSAGES` var; `CODE_LIST` = `ERR` anahtarları (21, tekrar yok); fazla anahtar yok; bilinmeyen kod → 500; `message("XYZ")` generic mesaj; `error_body` şekli; `is_refreshable` |
| `validation.string` | min/max UTF-8 (`"ğüş"` = 3 karakter); trim; pattern |
| `validation.enum` | geçerli/geçersiz, mesajda izinli liste |
| `validation.email` | lower+trim normalize; geçersiz örnekler (`a@`, `@b.com`, `a b@c.com`) |
| `validation.uuid` | geçerli v4; büyük harf kabul; eksik tire red |
| `validation.datetime` | `2026-09-18T10:00:00Z`, `…+03:00`, `…​.123Z` geçerli; `2026-13-01T…` red |
| `validation.password` | `Admin123!` geçerli; `admin123` (büyük harf yok) red, mesaj alan bazlı |
| `validation.array_of` | max, unique, eleman hatası `[2]: …` biçimi |
| `validation.optional/nullable` | yok vs NULL ayrımı; nullable olmayan alanda NULL → hata |
| `validation.schema strict` | bilinmeyen alan hatası |
| `validation.validate_partial` | boş gövde → `_` hatası; tek alan geçerli |
| `validation.schemas` | `todo_create` gerçekçi örnek geçer; `user_create` `role="root"` red |
| `saflık` | modül yüklendikten sonra `_G`'de yeni anahtar yok (global sızıntı testi) |

İki yorumlayıcı:

```make
test.shared:
	busted --lua=luajit shared/spec
	busted --lua=lua5.4 shared/spec
```

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Harici validator kütüphanesi yok (ör. `tableshape`) | Frontend'de (Wasmoon) de çalışmalı ve saf Lua olmalı; ~250 satırlık kendi DSL'imiz yeterli ve iki tarafı tek kaynaktan besler. |
| Endpoint şemaları `validation.schemas` altında | Frontend form validation'ı = backend validation; mesajlar birebir aynı. |
| `NULL` sentinel | PATCH semantiğinde "gönderilmedi" ile "null yap" ayrımı şart (ör. `due_date` temizleme). |
| Hata mesajları Türkçe, alan bazlı dizi | Bir alanın birden fazla hatası olabilir; UI hepsini gösterebilir. |
| Pragmatik e-posta regex'i | RFC tam uyumu gereksiz karmaşıklık; gerçek doğrulama reset e-postasıyla olur. |
| Bilinmeyen error kodu → 500 | Fail-safe: yazım hatası 200 dönmesin. |

## Kabul kriterleri (DoD)

- [ ] Üç modül de `ngx`/`js`/global kullanmıyor; `luacheck shared/` temiz.
- [ ] `ERR` listesi 00-genel-bakis §5 tablosuyla birebir aynı (21 kod); `CODE_LIST` ve `DEFAULT_MESSAGES` eksiksiz.
- [ ] `AUDIT_ACTIONS` 00-genel-bakis §8 ile birebir (14 olay); `default_matrix()` 00 §7 matrisini üretir.
- [ ] `PAGES` 00-genel-bakis §7 ile birebir (9 anahtar, aynı sıra).
- [ ] `busted --lua=luajit shared/spec` ve `busted --lua=lua5.4 shared/spec` ikisi de yeşil.
- [ ] `luarocks make rockspecs/todo-shared-0.1.0-1.rockspec --local` başarılı; ardından `lua -e 'print(require("todo_shared.protocol").http_status("TODO_NOT_FOUND"))'` → `404`.
- [ ] Tüm `schemas.*` tanımlı ve her biri için en az bir geçerli + bir geçersiz örnek spec'te var.
- [ ] Hiçbir dosyada 5.1 ∩ 5.4 yasak listesindeki yapı yok (`grep -nE '//|goto|<const>|<close>|utf8\.|math\.type' shared/src` boş; `//` yorum satırları hariç Lua'da yorum `--` olduğu için güvenli).

## Doğrulama

```bash
luacheck shared/
busted --lua=luajit shared/spec
busted --lua=lua5.4 shared/spec
luarocks make rockspecs/todo-shared-0.1.0-1.rockspec --local
lua5.4 -e 'local v=require("todo_shared.validation");
  local c,e=v.validate(v.schemas.todo_create,{title="  x  ",priority="urgent"});
  print(c, e and e.priority[1])'
# → nil   geçersiz değer: urgent (izinli: low, medium, high)
grep -nE '//|goto|<const>|<close>|utf8\.|math\.type' shared/src || echo "uyumlu"
```

## Riskler / Dikkat Noktaları

- **Lua 5.4 integer/float**: `3 == 3.0` true ama `tostring(3.0)` → `"3.0"`; JSON'dan gelen sayılar Wasmoon'da float olabilir → `integer()` kuralı `n == math.floor(n)` ile kontrol eder, `clean` değerini `math.floor(n)` olarak döner.
- **`cjson.null` vs JS null**: Frontend köprüsünde JS `null` Lua'ya `nil` olarak gelebilir (Wasmoon ayarına bağlı) → PATCH'te "temizle" ayrımı kaybolur. F13'te `fetch.lua` JSON'u JS tarafında değil **Lua tarafında** parse eder (tek davranış). Bu, F12/F13'e not olarak düşülür.
- **UTF-8 uzunluk**: `#s` byte sayar; `title` max 255 kontrolü karakter bazlı, DB `VARCHAR(255)` de karakter bazlı → tutarlı.
- Şema değişikliği hem backend hem frontend'i etkiler → shared değişikliklerinde iki tarafın spec'i de koşulmalı (CI F11).

## Tahmini Efor

**M** — 1–1.5 gün.
