# ═══ FAZ 9 — SWAGGER / OPENAPI 3.1 ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — error kodları (§5), `APP_BASE_URL` (§6),
> page key'ler (§7), yanıt zarfı (§15), teknik düzeltmeler #8, #9, #10.

## Amaç

Tüm REST API'nin OpenAPI 3.1 sözleşmesini **Lua tablosu** olarak (`api/src/openapi/spec.lua`)
tanımlamak, `GET /swagger.json` ile servis etmek, `GET /swagger` altında Swagger UI sunmak ve
spec'i CI'da `@redocly/cli lint` ile doğrulamak. Enum'lar ve error kodları `shared/` kaynaklarından
üretilir → spec kodla **kendiliğinden senkron** kalır. Ek olarak bir "route kapsama" testi,
router'daki her route'un spec'te, spec'teki her path'in router'da bulunduğunu doğrular.

## Önkoşullar

| Faz | Neden |
|---|---|
| F1 | `types` (enum'lar, PAGES), `protocol` (error kodları + HTTP map) |
| F3 | `router.lua`, `config.APP_BASE_URL` |
| F5–F8 | Belgelenecek tüm endpoint'ler ve yanıt şekilleri |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `api/src/openapi/spec.lua` | `build()` → OpenAPI 3.1 Lua tablosu; yardımcılar (`ref`, `json_body`, `op`, `errors_for`) |
| `api/src/handlers/swagger.lua` | `GET /swagger.json` (önbellekli JSON), `GET /swagger` (index.html) |
| `api/public/swagger/index.html` | Swagger UI (CDN, sürüm sabit + SRI) |
| `api/src/router.lua` | (güncelleme) swagger route'ları; route tablosunu kapsama testi için dışa açar |
| `redocly.yaml` (repo kökü) | Lint kuralları |
| `Makefile` | (güncelleme) `openapi.dump`, `openapi.lint` hedefleri |
| `api/spec/openapi_spec.lua` | Route ↔ spec kapsama + temel yapı testleri (busted) |

> `redocly.yaml` ve `api/spec/openapi_spec.lua` orijinal ağaçta yok; doğrulama gereksinimi
> ("Spec doğrulama") için eklenen en küçük iki dosyadır.

---

## Route'lar

| Metot | Yol | Auth | Yanıt |
|---|---|---|---|
| GET | `/api/v1/swagger.json` | Açık | `application/json` — OpenAPI 3.1 dokümanı |
| GET | `/api/v1/swagger` | Açık | `text/html` — Swagger UI |

Prompt bu iki yolu `/api/v1` base'i altında listeler; öyle uygulanır. 00 §7 gereği middleware
zinciri yalnızca `cors`, `logger` (auth/authorization yok). Prod'da (F18) isteğe bağlı olarak
`APP_ENV=production` + `SWAGGER_ENABLED` gibi bir anahtarla kapatma **eklenmez** (00 §6'da yok;
spec hassas bilgi içermez). Gerekirse önce 00'a eklenir.

---

## Dosya Bazlı Tasarım

### 1. `api/src/openapi/spec.lua`

#### Üst yapı

```lua
-- OpenAPI 3.1 spec'i: Lua tablosu olarak tanımlanır, enum ve error kodları shared/'dan üretilir.
local cjson    = require("cjson.safe")
local types    = require("todo_shared.types")
local protocol = require("todo_shared.protocol")
local config   = require("config")

local _M = {}
local EMPTY = cjson.empty_array

function _M.build()
  return {
    openapi = "3.1.0",
    info = {
      title = "Todo API",
      version = "0.1.0",
      description = "OpenResty + Lapis tabanlı Todo REST API. Tüm yanıtlar JSON zarfı kullanır.",
      license = { name = "MIT", identifier = "MIT" },
    },
    jsonSchemaDialect = "https://spec.openapis.org/oas/3.1/dialect/base",
    servers = { { url = config.APP_BASE_URL .. "/api/v1", description = config.APP_ENV } },
    security = { { bearerAuth = EMPTY } },            -- varsayılan: korumalı
    tags = {
      { name = "auth",    description = "Kimlik doğrulama" },
      { name = "todos",   description = "Görevler" },
      { name = "users",   description = "Kullanıcı yönetimi (admin)" },
      { name = "rbac",    description = "Rol-sayfa izin matrisi (admin)" },
      { name = "audit",   description = "Denetim kayıtları (admin)" },
      { name = "system",  description = "Sağlık ve dokümantasyon" },
    },
    components = components(),
    paths = paths(),
  }
end
```

- Açık endpoint'ler (login, refresh, forgot, reset, health, swagger) operasyon seviyesinde
  `security = EMPTY` (`[]`) ile işaretlenir. `cjson.empty_array` kullanılmazsa `{}` yazılır ve spec
  geçersiz olur — lint bunu yakalar.
- Path'ler OpenAPI sözdiziminde: Lapis `:id` → `{id}`, `:role/:page_key` → `{role}/{page_key}`.

#### Yardımcılar (tekrarı azaltmak için, 4 küçük fonksiyon)

```lua
local function ref(name) return { ["$ref"] = "#/components/schemas/" .. name } end

-- İstek gövdesi
local function json_body(schema_name, example)
  return { required = true, content = { ["application/json"] = {
    schema = ref(schema_name), example = example } } }
end

-- { data = <schema> } zarfı
local function data_of(schema)
  return { type = "object", required = { "data" }, properties = { data = schema } }
end

-- Operasyon: ortak hata yanıtlarını otomatik ekler
local function op(o)
  o.responses = o.responses or {}
  for _, code in ipairs(o.errors or {}) do
    local status = tostring(protocol.http_status(code))
    o.responses[status] = o.responses[status] or { ["$ref"] = "#/components/responses/" .. code }
  end
  o.errors = nil
  return o
end
```

`op{ errors = { "UNAUTHORIZED", "FORBIDDEN" } }` → `401` ve `403` yanıtları `components/responses`'a
referansla eklenir. HTTP kodu `protocol.http_status` ile alınır → 00 §5 tablosuyla asla ayrışmaz.
Aynı status'a düşen birden fazla kod varsa (ör. `TOKEN_EXPIRED` ve `UNAUTHORIZED` → 401) ilki
kullanılır ve `Error` şemasındaki `code` enum'u tüm olasılıkları listeler.

#### `components.securitySchemes`

```lua
securitySchemes = {
  bearerAuth = {
    type = "http", scheme = "bearer", bearerFormat = "JWT",
    description = "POST /auth/login'den alınan access_token (15 dk). Süresi dolunca /auth/refresh.",
  },
},
```

#### `components.schemas` listesi

| Şema | İçerik / Not |
|---|---|
| `Error` | `{ code: enum(protocol.CODE_LIST), message, details: object\|null, req_id: uuid }` |
| `ErrorResponse` | `{ error: Error }` |
| `ValidationDetails` | `additionalProperties: { type: array, items: string }` |
| `PaginationMeta` | `page, per_page, total, total_pages` (integer) |
| `Uuid` | `type: string, format: uuid` |
| `Timestamp` | `type: string, format: date-time` |
| `Role` | `enum: types.ROLES` |
| `TodoStatus` / `TodoPriority` | `enum` ← `types` |
| `PageKey` | `enum: types.PAGES` |
| `User` | id, email, full_name (`["string","null"]`), role, is_active, last_login_at (nullable), created_at, updated_at |
| `Permissions` | `object`, `propertyNames: PageKey`, `additionalProperties: boolean` (9 anahtarın hepsi) |
| `Me` | `{ user: User, permissions: Permissions }` (login/refresh yanıtındaki `TokenPair` de `user` + `permissions` içerir) |
| `UserCreate` | email, password (`writeOnly`, minLength 8), full_name, role, is_active |
| `UserUpdate` | UserCreate ile aynı, `password` opsiyonel |
| `Todo` | F6 JSON örneğindeki tüm alanlar; `owner_email` opsiyonel |
| `TodoCreate` / `TodoReplace` / `TodoPatch` | F6 şemaları; `TodoPatch` `minProperties: 1`, `additionalProperties: false` |
| `TodoStats` | F6 stats yanıtı |
| `LoginRequest` | email, password |
| `TokenPair` | access_token, refresh_token, token_type (`const: "Bearer"`), expires_in, refresh_expires_in, user |
| `RefreshRequest` / `LogoutRequest` | refresh_token (logout'ta opsiyonel) |
| `ForgotPasswordRequest` / `ResetPasswordRequest` | F5 şemaları |
| `MessageResponse` | `{ data: { message } }` |
| `RbacPage` | key, label, group, locked_for |
| `RbacMatrix` | roles, pages, matrix (`additionalProperties: { additionalProperties: boolean }`) |
| `RbacMatrixUpdate` | `{ matrix }` — açıklamada "kısmi gönderim kabul edilir" notu (F7) |
| `RbacCellUpdate` | `{ can_access: boolean }` |
| `AuditLog` | F8 serialize alanları; `old_value`/`new_value` `["object","null"]` |
| `AuditLogSummary` | Liste satırı (old/new yok) |
| `AuditStats` | F8 stats yanıtı |
| `Health` | `{ status: enum(ok, degraded), db: enum(up, down), version, uptime_s }` |

OpenAPI 3.1 = JSON Schema 2020-12: `nullable: true` **kullanılmaz**, yerine `type = { "string", "null" }`.

**Örnek — enum'ların shared'dan üretimi:**

```lua
Todo = {
  type = "object",
  required = { "id", "user_id", "title", "status", "priority", "tags", "created_at", "updated_at" },
  properties = {
    id = ref("Uuid"), user_id = ref("Uuid"),
    title = { type = "string", minLength = 1, maxLength = 255, examples = { "Sunum hazırla" } },
    description = { type = { "string", "null" }, maxLength = 10000 },
    status = ref("TodoStatus"), priority = ref("TodoPriority"),
    due_date = { type = { "string", "null" }, format = "date-time" },
    tags = { type = "array", maxItems = 10, items = { type = "string", minLength = 1, maxLength = 30 } },
    created_at = ref("Timestamp"), updated_at = ref("Timestamp"),
    completed_at = { type = { "string", "null" }, format = "date-time" },
    owner_email = { type = "string", format = "email", description = "Yalnızca admin listesinde" },
  },
},
TodoStatus = { type = "string", enum = types.TODO_STATUS },
Error = {
  type = "object", required = { "code", "message" },
  properties = {
    code = { type = "string", enum = protocol.CODE_LIST },
    message = { type = "string" },
    details = { type = { "object", "null" } },
    req_id = ref("Uuid"),
  },
},
```

`types.ROLES`, `types.PAGES`, `types.TODO_STATUS`, `types.TODO_PRIORITY` ve `protocol.CODE_LIST` F1'de sıralı
dizilerdir (JSON'da deterministik enum sırası için).

#### `components.parameters`

| Ad | Tanım |
|---|---|
| `IdPath` | `in: path, name: id, required, schema: Uuid` |
| `AuditIdPath` | `in: path, name: id, schema: { type: integer, minimum: 1 }` |
| `Page` | `in: query, schema: { integer, minimum 1, default 1 }` |
| `PerPage` | `in: query, schema: { integer, 1–100, default 20 }` |
| `Sort` | `in: query, schema: string`, açıklamada endpoint bazlı whitelist |
| `From` / `To` | `in: query, format: date-time` |

#### `components.responses`

00 §5'teki her kod için bir yanıt nesnesi otomatik üretilir:

```lua
local responses = {}
for _, code in ipairs(protocol.CODE_LIST) do
  responses[code] = {
    description = protocol.message(code),
    content = { ["application/json"] = {
      schema = ref("ErrorResponse"),
      example = { error = { code = code, message = "...", req_id = "5b1d9c1e-7f7a-4c1b-9a8e-3f2d8e1c0a11" } },
    } },
  }
end
responses.RATE_LIMITED.headers = { ["Retry-After"] = { schema = { type = "integer" } } }
```

`no-unused-components` lint kuralı kullanılmayan yanıtlar için uyarı verir → `redocly.yaml`'da bu
kural `components/responses` için kapatılır (hepsinin üretilmesi bilinçli).

#### `paths` — tam liste

| Path | Metot | operationId | Tag | Security | Başarı | `errors` |
|---|---|---|---|---|---|---|
| `/auth/login` | post | `login` | auth | `[]` | 200 `TokenPair` | VALIDATION_FAILED, INVALID_CREDENTIALS, ACCOUNT_DISABLED, RATE_LIMITED |
| `/auth/logout` | post | `logout` | auth | bearer | 204 | UNAUTHORIZED |
| `/auth/refresh` | post | `refreshToken` | auth | `[]` | 200 `TokenPair` | VALIDATION_FAILED, UNAUTHORIZED, ACCOUNT_DISABLED |
| `/auth/forgot-password` | post | `forgotPassword` | auth | `[]` | 202 `MessageResponse` | VALIDATION_FAILED, RATE_LIMITED |
| `/auth/reset-password` | post | `resetPassword` | auth | `[]` | 204 | VALIDATION_FAILED, RESET_TOKEN_INVALID |
| `/auth/me` | get | `getMe` | auth | bearer | 200 `Me` | UNAUTHORIZED, USER_NOT_FOUND |
| `/todos` | get | `listTodos` | todos | bearer | 200 `Todo[]` + meta | UNAUTHORIZED, FORBIDDEN, VALIDATION_FAILED |
| `/todos` | post | `createTodo` | todos | bearer | 201 `Todo` + `Location` | UNAUTHORIZED, FORBIDDEN, VALIDATION_FAILED, USER_NOT_FOUND |
| `/todos/stats` | get | `getTodoStats` | todos | bearer | 200 `TodoStats` | UNAUTHORIZED, FORBIDDEN |
| `/todos/{id}` | get | `getTodo` | todos | bearer | 200 `Todo` | UNAUTHORIZED, FORBIDDEN, TODO_NOT_FOUND |
| `/todos/{id}` | put | `replaceTodo` | todos | bearer | 200 `Todo` | + VALIDATION_FAILED |
| `/todos/{id}` | patch | `patchTodo` | todos | bearer | 200 `Todo` | + VALIDATION_FAILED |
| `/todos/{id}` | delete | `deleteTodo` | todos | bearer | 204 | UNAUTHORIZED, FORBIDDEN, TODO_NOT_FOUND |
| `/users` | get | `listUsers` | users | bearer | 200 `User[]` + meta | UNAUTHORIZED, FORBIDDEN, VALIDATION_FAILED |
| `/users` | post | `createUser` | users | bearer | 201 `User` | + EMAIL_TAKEN, VALIDATION_FAILED |
| `/users/{id}` | get | `getUser` | users | bearer | 200 `User` | UNAUTHORIZED, FORBIDDEN, USER_NOT_FOUND |
| `/users/{id}` | put | `updateUser` | users | bearer | 200 `User` | + EMAIL_TAKEN, LAST_ADMIN, SELF_ACTION_FORBIDDEN, VALIDATION_FAILED |
| `/users/{id}` | delete | `deleteUser` | users | bearer | 204 | + LAST_ADMIN, SELF_ACTION_FORBIDDEN |
| `/rbac/pages` | get | `listRbacPages` | rbac | bearer | 200 `RbacPage[]` | UNAUTHORIZED, FORBIDDEN |
| `/rbac/matrix` | get | `getRbacMatrix` | rbac | bearer | 200 `RbacMatrix` | UNAUTHORIZED, FORBIDDEN |
| `/rbac/matrix` | put | `updateRbacMatrix` | rbac | bearer | 200 `RbacMatrix` | + CONFLICT, VALIDATION_FAILED |
| `/rbac/matrix/{role}/{page_key}` | patch | `setRbacCell` | rbac | bearer | 200 `RbacMatrix` | + NOT_FOUND, CONFLICT, VALIDATION_FAILED |
| `/audit/logs` | get | `listAuditLogs` | audit | bearer | 200 `AuditLogSummary[]` + meta | UNAUTHORIZED, FORBIDDEN, VALIDATION_FAILED |
| `/audit/logs/{id}` | get | `getAuditLog` | audit | bearer | 200 `AuditLog` | UNAUTHORIZED, FORBIDDEN, NOT_FOUND |
| `/audit/stats` | get | `getAuditStats` | audit | bearer | 200 `AuditStats` | UNAUTHORIZED, FORBIDDEN, VALIDATION_FAILED |
| `/audit/export` | get | `exportAuditLogs` | audit | bearer | 200 `text/csv` (string, binary) | UNAUTHORIZED, FORBIDDEN, VALIDATION_FAILED |
| `/health` | get | `getHealth` | system | `[]` | 200 / 503 `Health` | — |
| `/swagger.json` | get | `getOpenApiSpec` | system | `[]` | 200 | — |
| `/swagger` | get | `getSwaggerUi` | system | `[]` | 200 `text/html` | — |

Spec path'leri `servers[0].url` (`.../api/v1`) altında göreli yazılır. Tüm route'lar (health ve swagger dahil)
F3 `router.register` ile `API_PREFIX` altına kaydedilir: gerçek yollar `/api/v1/health`, `/api/v1/health/ready` (F18),
`/api/v1/swagger`, `/api/v1/swagger.json`. Operasyon düzeyinde `servers` override'ı gerekmez.

Her korumalı operasyonun `description` alanı gerekli page key'i belirtir, örn. `"Yetki: todos.edit"`,
ve `x-page-key: "todos.edit"` vendor extension'ı içerir (kapsama testi ve frontend için makinece okunur).

`INTERNAL_ERROR` (500) ve `DB_UNAVAILABLE` (503) her operasyona `op()` içinde otomatik eklenir.

**Tam operasyon örneği:**

```lua
["/todos/{id}"] = {
  parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
  patch = op({
    tags = { "todos" }, operationId = "patchTodo",
    summary = "Todo'yu kısmi güncelle",
    description = "Yalnızca gönderilen alanlar değişir. `status=completed` → `completed_at` dolar.\n\nYetki: todos.edit",
    ["x-page-key"] = "todos.edit",
    requestBody = json_body("TodoPatch", { status = "completed" }),
    responses = {
      ["200"] = { description = "Güncellendi", content = { ["application/json"] = {
        schema = data_of(ref("Todo")) } } },
    },
    errors = { "UNAUTHORIZED", "FORBIDDEN", "TODO_NOT_FOUND", "VALIDATION_FAILED" },
  }),
},
```

**Liste yanıtı yardımcısı:**

```lua
local function page_of(item_schema_name)
  return { type = "object", required = { "data", "meta" }, properties = {
    data = { type = "array", items = ref(item_schema_name) },
    meta = ref("PaginationMeta"),
  } }
end
```

---

### 2. `api/src/handlers/swagger.lua`

```lua
-- Swagger/OpenAPI servis handler'ları: spec JSON'u worker başına bir kez üretilir.
local cjson = require("cjson.safe")
local spec  = require("openapi.spec")

local _M = {}

local cached_json, cached_html          -- worker ömrü boyunca değişmez

function _M.spec_json(self)
  if not cached_json then
    cached_json = assert(cjson.encode(spec.build()))
  end
  ngx.header["Cache-Control"] = "public, max-age=300"
  return { status = 200, layout = false, content_type = "application/json", cached_json }
end

function _M.ui(self)
  if not cached_html then
    local f = assert(io.open(ngx.config.prefix() .. "public/swagger/index.html", "rb"))
    cached_html = f:read("*a")
    f:close()
  end
  ngx.header["Content-Security-Policy"] = SWAGGER_CSP
  return { status = 200, layout = false, content_type = "text/html; charset=utf-8", cached_html }
end

return _M
```

- `cjson.encode` bir kez → sonraki istekler sıfır maliyet (`ETag` gereksiz; `max-age=300` yeterli).
- `cjson.encode_escape_forward_slash(false)` (F3 global ayarı) → `$ref` değerlerinde `\/` olmaz;
  olsa da geçerli JSON'dur, yalnızca okunabilirlik.
- `io.open` blocking I/O'dur ama worker başına bir kez, dosya KB'lar → kabul. Alternatif nginx
  `location = /api/v1/swagger { alias ...; }` — tek nokta olarak Lua tercih edildi (CSP header'ı
  aynı yerde).
- `ngx.config.prefix()` = OpenResty `-p` dizini (Dockerfile'da `api/`); F3/F18 ile teyit.

**`SWAGGER_CSP`:**

```
default-src 'none';
script-src https://cdn.jsdelivr.net 'sha256-<init-script-hash>';
style-src https://cdn.jsdelivr.net 'unsafe-inline';
img-src 'self' data: https://cdn.jsdelivr.net;
connect-src 'self';
font-src https://cdn.jsdelivr.net;
frame-ancestors 'none'
```

Inline init script'in SHA-256 hash'i build sırasında hesaplanır (`make openapi.csp-hash`) veya
basitlik için hash sabit yazılır ve index.html değişince spec testi uyarır.

---

### 3. `api/public/swagger/index.html`

```html
<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Todo API — Swagger UI</title>
  <link rel="stylesheet"
        href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css"
        integrity="sha384-<SRI>" crossorigin="anonymous">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js"
          integrity="sha384-<SRI>" crossorigin="anonymous"></script>
  <script>
    // Spec aynı origin'den, göreli yol ile yüklenir
    window.ui = SwaggerUIBundle({
      url: "./swagger.json",
      dom_id: "#swagger-ui",
      deepLinking: true,
      persistAuthorization: true,
      tryItOutEnabled: true,
      displayRequestDuration: true,
      filter: true,
    });
  </script>
</body>
</html>
```

- Sürüm **sabitlenir** (`@5.x.y`), `latest` değil; SRI hash'leri `curl ... | openssl dgst -sha384 -binary | base64` ile üretilir.
- Göreli `./swagger.json` → `/api/v1/swagger` ile `/api/v1/swagger.json` aynı dizinde çözülür.
  **Dikkat:** `/api/v1/swagger/` (sondaki `/` ile) açılırsa göreli yol `/api/v1/swagger/swagger.json`
  olur → router'da sondaki `/` için 301 yönlendirme veya mutlak yol `/api/v1/swagger.json` kullanılır
  (tercih: mutlak yol).
- `persistAuthorization`: token tarayıcının localStorage'ında kalır — geliştirici aracı için kabul.

---

### 4. Doğrulama altyapısı

#### `Makefile` hedefleri

```make
openapi.dump:            ## Spec'i JSON dosyasına yazar (lint ve artifact için)
	docker compose run --rm api resty -I /app/src -I /app/shared/src \
	  -e 'print(require("cjson").encode(require("openapi.spec").build()))' > api/public/swagger.json

openapi.lint: openapi.dump   ## OpenAPI 3.1 lint (00 §11 #10: swagger-cli değil redocly)
	npx --yes @redocly/cli@1 lint api/public/swagger.json --config redocly.yaml
```

`api/public/swagger.json` üretilmiş dosyadır → `.gitignore`'a eklenir (F0 güncellemesi). CI'da
artifact olarak saklanır (frontend/istemci üretimi için).

`resty -e` içinde `config` modülü env okur; dump sırasında `JWT_SECRET` / `DB_PASSWORD` zorunlulukları
nedeniyle `config.load()` assert'i patlamasın diye `APP_ENV=test` ile dummy değerler verilir
(`docker compose run -e ...`) — ya da spec yalnızca `config.APP_BASE_URL`'i okur, lazy erişim.

#### `redocly.yaml`

```yaml
extends:
  - recommended
rules:
  operation-operationId-unique: error
  operation-4xx-response: error
  operation-2xx-response: error
  security-defined: error
  no-unused-components: warn
  operation-summary: error
  no-invalid-media-type-examples: error
  path-parameters-defined: error
  tag-description: warn
```

#### `api/spec/openapi_spec.lua` (busted)

```lua
-- Spec yapısı ve router ↔ spec kapsama testleri.
describe("openapi spec", function()
  local spec = require("openapi.spec").build()
  local routes = require("router").route_list()   -- { {method="GET", path="/api/v1/todos/:id"}, ... }

  it("3.1.0 sürümünü bildirir", function()
    assert.equal("3.1.0", spec.openapi)
  end)

  it("router'daki her route spec'te var", function()
    for _, r in ipairs(routes) do
      local p = r.path:gsub("^/api/v1", ""):gsub(":([%w_]+)", "{%1}")
      assert.is_table(spec.paths[p], "spec'te yok: " .. p)
      assert.is_table(spec.paths[p][r.method:lower()], "metot yok: " .. r.method .. " " .. p)
    end
  end)

  it("spec'teki her operasyon router'da var", function() --[[ ters yön ]] end)

  it("korumalı her operasyon x-page-key taşır ve PAGES'te tanımlıdır", function() --[[ ... ]] end)

  it("Error.code enum'u protocol.CODE_LIST ile aynı", function()
    assert.same(require("todo_shared.protocol").CODE_LIST, spec.components.schemas.Error.properties.code.enum)
  end)

  it("JSON'a encode edilebilir ve açık endpoint'lerde security = []", function()
    local json = require("cjson").encode(spec)
    assert.truthy(json:find('"security":%[%]'))
  end)
end)
```

`router.route_list()`: router.lua'nın route kayıtlarını bir tabloda da tuttuğu küçük bir dışa aktarım
(Lapis `app.router` iç yapısına bağımlı olmamak için). Ayrıca `x-page-key` ↔ router'daki
`requires(page_key)` eşleşmesi de bu listeden kontrol edilir (router kaydı page key'i de saklar).

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Spec Lua tablosunda, YAML değil | Prompt gereksinimi; enum/error kodları shared'dan üretilir → tek kaynak |
| `@redocly/cli lint` | swagger-cli deprecated, 3.1 desteklemiyor (00 §11 #10) |
| Route ↔ spec kapsama testi | "Spec eskidi" sorununu CI'da yakalar |
| `x-page-key` extension | RBAC gereksinimi spec'te makinece okunur; router ile çapraz kontrol |
| Worker başına tek encode | Spec statik; her istekte encode gereksiz |
| Swagger UI CDN, sürüm sabit + SRI | Prompt "CDN"; tedarik zinciri riskini SRI azaltır |
| `components/responses` her error kodu için otomatik | 00 §5 ile senkron; elle tekrar yok |
| Request/response örnekleri | Her POST/PUT/PATCH için `example`; lint `no-invalid-media-type-examples` doğrular |

## Kabul kriterleri (DoD)

- [ ] `GET /api/v1/swagger.json` 200, `Content-Type: application/json`, `openapi == "3.1.0"`.
- [ ] `GET /api/v1/swagger` tarayıcıda Swagger UI'ı açar, 29 operasyon listelenir (tablo), konsolda CSP hatası yok.
- [ ] Swagger UI "Authorize" ile access token girilip `GET /todos` "Try it out" 200 döner.
- [ ] `make openapi.lint` 0 hata ile geçer (uyarılar kabul).
- [ ] `busted api/spec/openapi_spec.lua` geçer: route ↔ spec iki yönlü kapsama, `x-page-key` tutarlılığı, error enum eşitliği.
- [ ] Açık endpoint'ler (`login`, `refresh`, `forgot-password`, `reset-password`, `health`, `swagger*`) `security: []`; diğer tümü bearer.
- [ ] Her operasyonun en az bir 2xx ve bir 4xx yanıtı var (health/swagger hariç 4xx).
- [ ] Her request body için `example` var ve şemaya uyuyor (lint).
- [ ] Enum değerleri (`TodoStatus`, `TodoPriority`, `Role`, `PageKey`) `shared/src/types.lua` ile aynı; types'a değer eklenince spec kendiliğinden güncellenir (test: geçici değer ekle → spec'te görünür).
- [ ] Nullable alanlar `type: [X, "null"]` ile; spec'te `nullable` anahtarı yok (`grep -c nullable` = 0).
- [ ] Spec JSON'unda hassas bilgi (secret, parola örneği dışında gerçek değer) yok; örnek parolalar `"Ornek123!"` gibi sahte.

## Doğrulama

```bash
# Spec erişimi
curl -s localhost:28080/api/v1/swagger.json | jq '{openapi, title: .info.title, paths: (.paths | keys | length)}'
# Beklenen: openapi "3.1.0", paths 21 (farklı path sayısı)

# Operasyon sayısı
curl -s localhost:28080/api/v1/swagger.json | jq '[.paths[] | to_entries[] | select(.key | test("get|post|put|patch|delete"))] | length'
# Beklenen: 29

# Açık endpoint'ler
curl -s localhost:28080/api/v1/swagger.json | jq '[.paths | to_entries[] | .key as $p | .value | to_entries[] | select(.value.security == []) | "\(.key) \($p)"]'

# nullable kullanılmıyor
curl -s localhost:28080/api/v1/swagger.json | grep -c '"nullable"'     # 0

# Lint
make openapi.lint

# Kapsama testi
busted api/spec/openapi_spec.lua

# UI
xdg-open http://localhost:28080/api/v1/swagger
curl -sI localhost:28080/api/v1/swagger | grep -i content-security-policy
```

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| Spec ile gerçek yanıt ayrışması (şekil) | Kapsama testi path/metot seviyesinde; şekil için F11 integration spec'lerinde kritik yanıtlar spec şemasına karşı doğrulanabilir (`ponytail:` şimdilik yok, `lua-resty-jsonschema` ile eklenebilir) |
| `cjson` boş tabloyu `{}` yazar (`security`, `required`) | `cjson.empty_array`; boş `required` hiç yazılmaz |
| cjson anahtar sırasını korumaz | JSON geçerli; okunabilirlik için sorun değil, dump diff'leri gürültülü olabilir (`jq -S` ile karşılaştırma) |
| CDN erişilemezse UI açılmaz | Yalnızca dokümantasyon; API etkilenmez. Air-gapped ortamda `swagger-ui-dist` `api/public/swagger/` altına kopyalanır |
| Göreli URL / sondaki slash | Mutlak `/api/v1/swagger.json` |
| Inline script CSP hash'i index.html değişince bozulur | Spec testi hash'i dosyadan hesaplayıp CSP ile karşılaştırır |
| Swagger UI XSS geçmişi | Sürüm sabit + düzenli güncelleme (F18 güvenlik listesi, Dependabot) |

## Tahmini Efor

**M** (1.5–2 gün): şemalar + 29 operasyon 1 gün, handler/UI/CSP 0.25 gün, lint + kapsama testi 0.5 gün.
