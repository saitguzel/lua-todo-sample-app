# ═══ FAZ 13 — FRONTEND CORE ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) — error kodları (§5), page key'ler (§7), API yanıt zarfı (§15).
> Köprü API'si (`js.*`): [faz-12](faz-12-frontend-iskelet.md) §4.3.

## 1. Amaç

Frontend'in view'lardan bağımsız çekirdeği yazılır: DOM oluşturma ve güncelleme (`dom.lua`), JS Promise'lerini Lua coroutine'lerine çeviren HTTP istemcisi (`fetch.lua`), `localStorage` sarmalayıcısı (`storage.lua`), reducer pattern'li tek state deposu ve render döngüsü (`app.lua`), auth + RBAC guard'lı hash router (`router.lua`) ve tüm sayfaları saran `layout.lua`. Faz sonunda uygulama login durumuna göre doğru sayfaya yönlenir, navigasyon menüsü rolün izinlerine göre çizilir, 401'de token otomatik yenilenir; view'lar (F14/F15) yalnızca `render(state, dispatch)` fonksiyonu yazarak eklenebilir.

## 2. Önkoşullar

| Faz | Neden |
|---|---|
| F12 | `js.*` köprüsü, bundle, `main.lua` |
| F1 | `todo_shared.types` (PAGES, ROLES), `todo_shared.protocol` (error kodları), `todo_shared.validation` |
| F5 | `/auth/login`, `/auth/refresh`, `/auth/me`, `/auth/logout` |
| F7 | `rbac_service.permissions_for(role)` → `/auth/*` yanıtlarındaki `permissions` (aşağıdaki not) |

**RBAC izinlerini frontend nereden alır?** `/rbac/*` yalnızca admin'e açık (00-genel-bakis §7). Bu yüzden login, refresh ve `/auth/me` yanıtları kullanıcının kendi izinlerini de döner (F5): `{ data = { user = {...}, permissions = { ["dashboard"] = true, ["users.list"] = false, ... } } }` — 9 anahtarın hepsi, değer boolean. Frontend'in izinleri **yalnızca UI gizleme** içindir; asıl yetki kontrolü backend'dedir.

## 3. Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/src/dom.lua` | `h(tag, props, children)` sanal düğüm, `mount`, basit keyed diff/patch, event delegation, handle release |
| `web/src/fetch.lua` | `api.get/post/put/patch/delete` — coroutine içinde senkron görünen çağrılar, token ekleme, 401 → tek-uçuş refresh, error normalize |
| `web/src/storage.lua` | Namespace'li, JSON'lu, hata-toleranslı `localStorage` |
| `web/src/app.lua` | Store (`state`, `dispatch`, `subscribe`), kök reducer, action sabitleri, effect runner (`spawn`), render zamanlayıcı |
| `web/src/router.lua` | Route tablosu, hash parse (path + query), guard'lar, `navigate`, 404 |
| `web/src/views/layout.lua` | Üst bar (kullanıcı, tema, çıkış), rol bazlı yan menü, `<main id="main">`, mobil menü |
| `web/src/json.lua` | `js.json` sarmalayıcısı + `null` sentinel (küçük; ayrı dosya çünkü fetch, storage ve view'lar ortak kullanır) |
| `web/spec/` (iskelet) | F17'de doldurulacak reducer/router testleri için `js` mock'u |

`json.lua` prompt ağacında yok; 20 satırlık zorunlu yardımcı. Alternatif `fetch.lua` içine gömmek ama `storage.lua` da kullandığı için ayrı.

## 4. Dosya Bazlı Tasarım

### 4.1 `web/src/dom.lua` — Sanal DOM + Patch

**Veri yapısı (vnode):**

```lua
-- Sanal düğüm: düz Lua tablosu
-- { tag = "button", props = { class = "...", onclick = fn, ["aria-label"] = "..." }, children = { ... }, key = "todo-42", _h = <handle> }
-- Metin düğümü: { text = "Merhaba", _h = <handle> }
```

**Public API:**

```lua
local dom = {}

-- vnode üretir. children: vnode | string | number | nil | liste (iç içe listeler düzleştirilir, nil atlanır)
function dom.h(tag, props, children) end

-- Kısayollar: dom.div(props, children), dom.button(...), dom.input(...), ... (yaygın 25 etiket)

-- İlk yerleştirme: kök handle altına vnode ağacını kurar
function dom.mount(root_handle, vnode) end

-- Eski ve yeni ağacı karşılaştırıp minimum DOM işlemi uygular; yeni ağacı döner
function dom.patch(root_handle, old_vnode, new_vnode) end

-- Tek seferlik yardımcılar (render dışı: toast, modal kökleri)
function dom.set_text(handle, s) end
function dom.focus(selector_id) end
function dom.on(handle, event, fn) end   -- dönen fonksiyon listener'ı kaldırır

return dom
```

**Patch algoritması (yeterince basit):**

```
patch(parent, old, new):
  old == nil          → create(new), append
  new == nil          → remove(old) + release alt ağaç
  farklı tag / text↔el→ replace
  ikisi de text       → setText (değiştiyse)
  aynı tag            → props diff:
                          - eklenen/değişen attr → setAttr / setProp (value, checked, disabled prop ile)
                          - silinen attr → removeAttr
                          - on* → listener değiştiyse eski kaldır, yeni ekle
                        children diff:
                          - hepsinde key varsa → key eşleştirme (map), taşınan düğüm replaceChildren ile sıralanır
                          - yoksa → index bazlı
```

`-- ponytail:` notu: Keyed diff O(n) map + `replaceChildren` ile tam yeniden sıralama; liste > 1000 elemanda LIS tabanlı minimum taşıma algoritmasına geçilir. Todo listesi sayfalıdır (≤100), yeterli.

**Özellik ↔ property eşlemesi:** `value`, `checked`, `disabled`, `selected`, `indeterminate` → `js.dom.setProp`; geri kalan her şey `setAttr`. `class` string veya `{ ["px-2"] = true, ["hidden"] = cond }` tablosu kabul eder.

**Event handling:** Her `on*` prop için `js.dom.on(h, "click", fn)` kurulur, dönen "kaldır" fonksiyonu vnode'da `_off.click` olarak saklanır. Patch'te handler kimliği değiştiyse eski kaldırılır. (Delegation alternatifi: kökte tek listener + `data-action`; view'lar closure kullandığı için doğrudan bağlama daha sade. `eventToLua.action` alanı klavye kısayolları için korunur.)

**Güvenlik:** Metin her zaman `createTextNode` / `textContent`; `innerHTML` API'de yok. `href` prop'u `javascript:` ile başlıyorsa atılır (`^%s*javascript:` kontrolü, büyük/küçük harf duyarsız).

**Bellek:** `remove` edilen her düğüm ve alt ağacı için `js.dom.release(h)` çağrılır; JS tarafı `nodes` haritası büyümez.

**Odak koruma:** Patch sırasında aynı düğüm yeniden kullanıldığı için input odak ve imleç korunur (düğüm değiştirilmez, sadece prop'lar).

### 4.2 `web/src/fetch.lua` — Promise → Coroutine Köprüsü

**Temel mekanizma:**

```lua
-- JS tarafı callback çağırır; biz çağıran coroutine'i yield edip callback'te resume ederiz.
local function await_request(method, url, headers, body)
  local co = coroutine.running()
  assert(co and not select(2, coroutine.running()), "api.* bir coroutine içinde çağrılmalı (app.spawn kullanın)")
  local done, result = false, nil
  js.http.request(method, url, json.encode(headers), body, function(net_err, status, text, ctype)
    result = { net_err = net_err, status = status, text = text, ctype = ctype }
    if done == false then done = true end
    local ok, err = coroutine.resume(co)
    if not ok then js.log("error", "coroutine hatası: " .. tostring(err)) end
  end)
  coroutine.yield()
  return result
end
```

Not: JS `fetch` her zaman asenkron olduğundan callback, `yield`'dan **sonra** çalışır; senkron callback durumu oluşmaz. Yine de callback önce gelirse diye `done` bayrağı ile korunur (uygulamada `if not done then yield end` şeklinde).

**Public API:**

```lua
local api = {}

-- Hepsi coroutine içinde çağrılır; dönüş: data, nil | nil, err
-- err = { code = "TODO_NOT_FOUND", message = "...", details = {...}, status = 404 }
function api.get(path, query) end            -- query: { status = "pending", page = 2 } → ?status=pending&page=2 (url-encode)
function api.post(path, body) end
function api.put(path, body) end
function api.patch(path, body) end
function api.delete(path) end
function api.download(path, filename) end    -- CSV export (js.http.download)

-- Yapılandırma
function api.configure({ base = "...", get_tokens = fn, set_tokens = fn, on_logout = fn }) end

return api
```

**İstek akışı:**

```
api.patch("/todos/42", { status = "completed" })
  ├─ url = base .. path (.. query)
  ├─ headers: Content-Type: application/json, Accept: application/json, Authorization: Bearer <access>
  ├─ res = await_request(...)
  ├─ res.net_err          → nil, { code = "NETWORK_ERROR", message = "Sunucuya ulaşılamadı" }
  ├─ res.status == 401 ve body.error.code == "TOKEN_EXPIRED" ve path ≠ /auth/*
  │     ├─ refresh_once()  ← tek-uçuş
  │     ├─ başarılı → isteği BİR KEZ yeniden dene
  │     └─ başarısız → on_logout() → nil, err
  ├─ 204                   → true, nil
  ├─ 2xx                   → json.decode(text).data (+ meta), nil
  └─ diğer                 → nil, normalize(json.decode(text).error, status)
```

**Tek-uçuş refresh (single-flight):** Aynı anda 3 istek 401 alırsa tek bir `/auth/refresh` çağrılmalı (refresh token rotasyonlu; ikinci çağrı `TOKEN_REVOKED` alır ve kullanıcıyı atardı).

```lua
local refreshing = nil   -- nil | { waiters = { co1, co2 } }

local function refresh_once()
  if refreshing then
    -- Başka bir coroutine zaten yeniliyor: sıraya gir, sonucu bekle
    table.insert(refreshing.waiters, coroutine.running())
    return coroutine.yield()           -- resume(co, ok) ile döner
  end
  refreshing = { waiters = {} }
  local ok = do_refresh()               -- POST /auth/refresh, set_tokens
  local waiters = refreshing.waiters
  refreshing = nil
  for _, co in ipairs(waiters) do coroutine.resume(co, ok) end
  return ok
end
```

**Error normalize:** Backend kodları (00-genel-bakis §5) aynen geçer; frontend'e özgü iki ek kod yalnızca istemci tarafında üretilir ve **backend'e hiç gönderilmez**: `NETWORK_ERROR`, `INVALID_RESPONSE` (JSON parse hatası). Bunlar `shared/protocol.lua`'ya eklenmez; `fetch.lua` içinde yerel sabitler.

**Mesaj çevirisi:** `err.message` backend'den Türkçe gelir; view'lar doğrudan gösterir. `VALIDATION_FAILED` için `err.details` alan bazlı form hatalarına bağlanır.

**Zaman aşımı:** `js.http.request` 15 sn sonra `AbortController` ile iptal eder (glue.js'e eklenir) → `NETWORK_ERROR`.

### 4.3 `web/src/storage.lua`

```lua
local storage = {}
local PREFIX = "todo."

-- Değerler JSON olarak saklanır; bozuk JSON veya erişim hatası → default döner
function storage.get(key, default) end
function storage.set(key, value) end     -- dönüş: true | false (kota/engelli)
function storage.remove(key) end

return storage
```

**Anahtarlar (kanonik):**

| Anahtar | İçerik | Not |
|---|---|---|
| `todo.auth` | `{ access_token, refresh_token }` | Güvenlik notu aşağıda |
| `todo.theme` | `"light" \| "dark"` | `boot.js` de okur (F12) — JSON değil düz string; bu anahtar için `storage.get_raw/set_raw` |
| `todo.todos.filters` | `{ status, priority, sort, per_page }` | Kullanıcı tercihi |
| `todo.sidebar` | `"open" \| "closed"` | Mobil menü |

**Token saklama güvenlik notu:** Prompt `localStorage` diyor. `localStorage`'daki token XSS ile çalınabilir. Azaltım: (1) `innerHTML` yok, sıkı CSP (F12), (2) access token 15 dk, (3) refresh rotasyon + denylist (F5). Daha güvenli seçenek (HttpOnly cookie ile refresh) backend'de CSRF katmanı gerektirir; kapsam dışı, F18 güvenlik kontrol listesinde "bilinen risk" olarak listelenir.

### 4.4 `web/src/app.lua` — Store, Reducer, Render

**State şekli (tek ağaç):**

```lua
local initial_state = {
  route       = { name = nil, params = {}, query = {} },
  auth        = { status = "unknown",        -- unknown | anonymous | authenticated
                  user = nil,                -- { id, email, full_name, role }
                  permissions = {} },        -- { ["todos.list"] = true, ... }
  todos       = { items = {}, by_id = {}, meta = nil, status = "idle", error = nil,
                  filters = { status = nil, priority = nil, q = nil, sort = "-created_at", page = 1, per_page = 20 },
                  pending = {} },            -- optimistic: { [id] = snapshot }
  stats       = { data = nil, status = "idle" },
  users       = { items = {}, meta = nil, status = "idle", error = nil },
  rbac        = { pages = {}, matrix = nil, status = "idle" },
  audit       = { items = {}, meta = nil, filters = {}, status = "idle", selected = nil },
  ui          = { theme = "light", toasts = {}, modal = nil, sidebar_open = false, busy = {} },
}
```

`status` alanı her async dilimde: `idle | loading | ready | error` → view'lar skeleton / hata / empty state kararını buna göre verir.

**Action sabitleri (kanonik liste):**

| Grup | Action | Payload |
|---|---|---|
| Router | `ROUTE_CHANGED` | `{ name, params, query }` |
| Auth | `AUTH_RESTORED` | `{ user, permissions }` |
| | `AUTH_ANONYMOUS` | — |
| | `LOGIN_SUCCEEDED` | `{ user, permissions }` |
| | `LOGGED_OUT` | — |
| | `LOGIN_REQUESTED` | — (buton spinner'ı; F14) |
| | `PERMISSIONS_LOADED` | `{ permissions }` (`/auth/me` yeniden çekildiğinde; F15 RBAC değişimi sonrası) |
| Todos | `TODOS_REQUESTED` | `{ filters }` |
| | `TODOS_LOADED` | `{ items, meta }` |
| | `TODOS_FAILED` | `{ error }` |
| | `TODO_FILTERS_CHANGED` | `{ patch }` |
| | `TODO_OPTIMISTIC_CREATE` | `{ temp_id, todo }` |
| | `TODO_CREATE_CONFIRMED` | `{ temp_id, todo }` |
| | `TODO_OPTIMISTIC_UPDATE` | `{ id, patch }` |
| | `TODO_UPDATE_CONFIRMED` | `{ todo }` |
| | `TODO_OPTIMISTIC_DELETE` | `{ id }` |
| | `TODO_DELETE_CONFIRMED` | `{ id }` |
| | `TODO_ROLLBACK` | `{ id }` (snapshot'a geri dön) |
| | `TODO_EDIT_OPENED` / `TODO_EDIT_CLOSED` | `{ id }` / — (klavye `e`, F14/F16) |
| Stats | `STATS_REQUESTED` / `STATS_LOADED` / `STATS_FAILED` | |
| | `RECENT_TODOS_LOADED` | `{ items }` (dashboard, F14) |
| | `ADMIN_STATS_LOADED` / `ADMIN_STATS_FAILED` | `{ users, audit }` / `{ error }` (dashboard admin kartları, F15) |
| Users | `USERS_REQUESTED` / `USERS_LOADED` / `USERS_FAILED` / `USER_SAVED` / `USER_REMOVED` | |
| | `USERS_FILTERS_CHANGED` | `{ patch }` |
| | `USER_EDIT_OPENED` / `USER_EDIT_CLOSED` | `{ id \| nil }` (nil = yeni kullanıcı) / — |
| | `USER_SAVE_REQUESTED` / `USER_SAVE_FAILED` | — / `{ error }` |
| RBAC | `RBAC_REQUESTED` / `RBAC_LOADED` / `RBAC_FAILED` | |
| | `RBAC_CELL_TOGGLED` (optimistic) / `RBAC_CELL_CONFIRMED` / `RBAC_CELL_ROLLBACK` | `{ role, page_key, can_access }` |
| | `RBAC_MATRIX_REPLACED` | `{ matrix }` (toplu PUT / varsayılana sıfırla) |
| Audit | `AUDIT_REQUESTED` / `AUDIT_LOADED` / `AUDIT_FAILED` / `AUDIT_FILTERS_CHANGED` / `AUDIT_SELECTED` | |
| | `AUDIT_DETAIL_LOADED` / `AUDIT_DESELECTED` | `{ log }` / — |
| | `AUDIT_STATS_LOADED` | `{ stats }` |
| | `AUDIT_EXPORT_STARTED` / `AUDIT_EXPORT_FINISHED` | — |
| Formlar | `FORM_ERRORS_SET` | `{ form, errors }` (`VALIDATION_FAILED.details` veya istemci validation) |
| UI | `TOAST_PUSHED` / `TOAST_DISMISSED` | `{ id, kind, message }` / `{ id }` |
| | `MODAL_OPENED` / `MODAL_CLOSED` | `{ name, props }` |
| | `THEME_SET` | `{ theme }` |
| | `SIDEBAR_TOGGLED` | — |
| | `BUSY_SET` | `{ key, value }` (buton spinner'ları) |

F14–F16 bu listeye yalnızca ekleme yapar; yeniden adlandırmaz.

**Reducer düzeni:** Dilim bazlı alt reducer'lar, kök reducer bunları birleştirir (Redux `combineReducers` benzeri, 10 satır):

```lua
local reducers = {
  route = reduce_route, auth = reduce_auth, todos = reduce_todos, stats = reduce_stats,
  users = reduce_users, rbac = reduce_rbac, audit = reduce_audit, ui = reduce_ui,
}

-- Saf fonksiyon: değişmeyen dilim aynı tablo referansını korur (render'da kısa devre için)
local function root_reducer(state, action)
  local next_state, changed = {}, false
  for k, r in pairs(reducers) do
    local s = r(state[k], action)
    next_state[k] = s
    if s ~= state[k] then changed = true end
  end
  return changed and next_state or state
end
```

**Değişmezlik kuralı:** Reducer'lar mevcut tabloyu **değiştirmez**; yeni tablo döner (`util.assign({}, old, patch)`). Test (F17) bunu `deep_freeze` ile doğrular (metatable `__newindex` → error).

`LOGGED_OUT` tüm dilimleri `initial_state`'e döndürür (ui.theme hariç) — başka kullanıcının verisi bellekte kalmaz.

**Store API:**

```lua
local app = {}

function app.start(opts) end               -- main.lua çağırır
function app.dispatch(action) end          -- { type = "...", ... }
function app.get_state() end
function app.subscribe(fn) end             -- dönüş: unsubscribe
function app.spawn(fn, ...) end            -- effect'i coroutine'de çalıştırır, hatayı yakalayıp toast'a çevirir
function app.can(page_key) end             -- state.auth.permissions[page_key] == true (menü, buton görünürlüğü, router guard)
function app.refresh_permissions() end   -- spawn: GET /auth/me → PERMISSIONS_LOADED (F15: admin kendi rolünün matrisini değiştirince)

return app
```

**Effect'ler (async işler):** Reducer saf kalır; API çağrıları "effect" fonksiyonlarında, `app.spawn` ile coroutine içinde:

```lua
-- views/todos.lua içinde (F14) örnek effect
local function load_todos(filters)
  app.dispatch({ type = "TODOS_REQUESTED", filters = filters })
  local data, err = api.get("/todos", filters)
  if err then return app.dispatch({ type = "TODOS_FAILED", error = err }) end
  app.dispatch({ type = "TODOS_LOADED", items = data.items, meta = data.meta })
end

app.spawn(load_todos, state.todos.filters)
```

`app.spawn`:

```lua
function app.spawn(fn, ...)
  local co = coroutine.create(function(...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
      js.log("error", err)
      app.dispatch({ type = "TOAST_PUSHED", kind = "error", message = "Beklenmeyen bir hata oluştu" })
    end
  end)
  local ok, err = coroutine.resume(co, ...)
  if not ok then js.log("error", err) end
end
```

**Render döngüsü:**

```
dispatch(action)
  ├─ state = root_reducer(state, action)
  ├─ state değişmediyse → çık
  ├─ subscribers çağrılır (storage senkronu: filters, theme)
  └─ schedule_render()  → js.timer.raf ile tek kareye birleştirilir (aynı karede 5 dispatch = 1 render)

render()
  ├─ view = router.resolve(state.route)           -- view modülü (lazy require)
  ├─ tree = layout.render(state, dispatch, view.render(state, dispatch))
  │         (login/forgot/reset sayfaları layout'suz: view.layout == false)
  └─ current = dom.patch(app_root, current, tree)
```

Toast ve modal kökleri (`#toast-root`, `#modal-root`) aynı render'da ayrı `dom.patch` çağrılarıyla güncellenir (F16 bileşenleri).

**Başlangıç (`app.start`):**

```
1. theme = storage.get_raw("todo.theme") or (js.media.prefersDark() and "dark" or "light") → THEME_SET
2. api.configure({ base = config.apiBase, get_tokens, set_tokens, on_logout = → LOGGED_OUT + navigate("#/login") })
3. router.start(on_change = dispatch ROUTE_CHANGED)
4. klavye kısayol dinleyicisi (F16 kayıt eder; burada sadece js.keyboard.onKey → app.handle_key)
5. spawn(restore_session):
     token yok → AUTH_ANONYMOUS
     token var → GET /auth/me → AUTH_RESTORED { user, permissions } | hata → AUTH_ANONYMOUS + token sil
6. İlk render (auth.status == "unknown" iken tam sayfa skeleton)
```

### 4.5 `web/src/router.lua` — Hash Router + Guard

**Route tablosu (kanonik):**

| Hash | name | view modülü | auth | page_key | layout |
|---|---|---|---|---|---|
| `#/login` | `login` | `views.login` | guest-only | — | ❌ |
| `#/forgot-password` | `forgot_password` | `views.forgot_password` | guest-only | — | ❌ |
| `#/reset-password?token=…` | `reset_password` | `views.reset_password` | public | — | ❌ |
| `#/` , `#/dashboard` | `dashboard` | `views.dashboard` | ✅ | `dashboard` | ✅ |
| `#/todos` | `todos` | `views.todos` | ✅ | `todos.list` | ✅ |
| `#/todos/new` | `todos_new` | `views.todos` (modal açık) | ✅ | `todos.create` | ✅ |
| `#/todos/:id` | `todo_edit` | `views.todos` (modal açık) | ✅ | `todos.edit` | ✅ |
| `#/users` | `users` | `views.users` | ✅ | `users.list` | ✅ |
| `#/rbac` | `rbac` | `views.rbac_matrix` | ✅ | `rbac.matrix` | ✅ |
| `#/audit` | `audit` | `views.audit_logs` | ✅ | `audit.logs` | ✅ |
| `#/profile` | `profile` | `views.profile` | ✅ | — (her auth kullanıcı) | ✅ |
| diğer | `not_found` | `views.layout` içi 404 bloğu | — | — | ✅ |

Reset linki backend e-postasında `WEB_BASE_URL/#/reset-password?token=...` biçimindedir (F5 ile uyumlu).

**Public API:**

```lua
local router = {}

function router.start(on_change) end          -- hashchange dinler, ilk hash'i işler
function router.navigate(hash, opts) end      -- opts.replace: history'ye ekleme (location.replace)
function router.parse(hash) end               -- saf: "#/todos/abc?x=1" → { name, params = { id = "abc" }, query = { x = "1" } }
function router.guard(route, auth) end        -- saf: → nil (geç) | "#/login?next=..." | "#/" | "forbidden"
function router.resolve(route) end            -- view modülünü lazy require eder
function router.href(name, params, query) end -- link üretimi (view'larda string sabitlerini önler)
function router.can(auth, page_key) end       -- menü/buton gizleme için

return router
```

**Guard mantığı (saf fonksiyon, F17'de tablo-bazlı test edilir):**

```
guard(route, auth):
  auth.status == "unknown"                         → nil (bekle; skeleton render, restore bitince yeniden guard)
  route.auth == "guest-only" ve authenticated       → "#/"
  route.auth == true ve anonymous                   → "#/login?next=" .. urlencode(current_hash)
  route.page_key ve not auth.permissions[page_key]  → "forbidden" (403 sayfası render, yönlendirme yok)
  aksi                                              → nil
```

- `next` parametresi yalnızca `#/` ile başlayan değerleri kabul eder (open redirect koruması).
- `forbidden` durumunda URL değişmez, içerik "Bu sayfaya erişim yetkiniz yok" (+ dashboard linki) olur.
- Login sonrası `next` varsa oraya, yoksa `#/`.
- `#/` → `dashboard` izni yoksa (teorik) ilk izinli sayfaya düşülür.

**Lazy view yükleme:** `resolve` `require("views." .. name)` yapar; modüller zaten mount edilmiş olduğundan maliyet yalnızca ilk parse. F17'de bundle bölme ile gerçek lazy fetch'e dönüşebilir; API değişmez.

### 4.6 `web/src/views/layout.lua`

**Sözleşme (tüm view'lar için):**

```lua
-- Her view modülü şu şekli izler:
local M = {}
M.title = "Görevler"                  -- document.title ve <h1>
M.layout = true                       -- false: login/forgot/reset
function M.on_enter(route, state) end -- opsiyonel: veri yükleme effect'i (app.spawn ile)
function M.render(state, dispatch) end -- vnode döner
return M
```

`on_enter` router tarafından route değişiminde bir kez çağrılır (render'da değil) → render saf kalır, sonsuz yükleme döngüsü olmaz.

**Layout yapısı:**

```
<div class="min-h-screen flex">
  <aside id="sidebar" aria-label="Ana menü" class="hidden md:block w-60 ...">   ← mobilde çekmece
    <nav><ul>
      (router.can(auth, page_key) olan öğeler)
      Pano · Görevler · Kullanıcılar · Yetki Matrisi · Denetim Kayıtları
    </ul></nav>
  </aside>
  <div class="flex-1 flex flex-col">
    <header class="flex items-center justify-between h-14 px-4 border-b">
      <button aria-label="Menüyü aç" aria-expanded=... class="md:hidden">☰</button>
      <h1>{view.title}</h1>
      <div> theme_toggle (F16) · kullanıcı menüsü (Profil, Çıkış) </div>
    </header>
    <main id="main" tabindex="-1" class="flex-1 p-4 md:p-6">{view içeriği}</main>
  </div>
</div>
```

- Aktif menü öğesi `aria-current="page"`.
- Route değişince `document.title = view.title .. " · Todo"` ve odak `#main`'e taşınır (ekran okuyucu duyurusu için).
- Çıkış: `app.spawn(logout)` → `POST /auth/logout` (hata olsa bile) → token sil → `LOGGED_OUT` → `#/login`.
- `theme_toggle` bileşeni F16'da yazılır; bu fazda basit bir buton (`THEME_SET`) yer tutucu.

### 4.7 `web/src/json.lua`

```lua
-- JSON encode/decode JS'e devredilir; Lua'da null'u temsil eden sentinel sağlanır
local json = { null = setmetatable({}, { __tostring = function() return "null" end }) }
function json.encode(v) return js.json.encode(v) end   -- Wasmoon tabloyu JS nesnesine çevirir
function json.decode(s) return js.json.decode(s) end
return json
```

Dikkat: Wasmoon'un Lua tablo ↔ JS dönüşümünde boş tablo `{}` dizi mi nesne mi belirsiz, `nil` değerli alanlar kaybolur. PATCH'te alanı `null` yapmak (ör. `due_date = null`) için `json.null` sentinel'i encode öncesi özel işaretle değiştirilir. Uygulamada: `encode` kendi küçük Lua serializer'ı ile string üretir (sentinel ve dizi/nesne ayrımı kontrol altında), `decode` JS'e devredilir. Karar implementasyon sırasında Wasmoon davranışı test edilerek kesinleştirilir; dış API değişmez.

## 5. Teknik Kararlar

| Karar | Neden |
|---|---|
| Sanal DOM + küçük keyed patch | Prompt "kendi render'ı" diyor; her dispatch'te tüm ağacı yeniden oluşturmak input odak/imleç kaybettirir. Patch ~150 satır |
| rAF ile render birleştirme | Optimistic akışlarda art arda dispatch'ler tek boyamaya iner |
| Reducer saf, effect'ler ayrı + `app.spawn` | Reducer tablo-bazlı test edilebilir (F17); coroutine yalnızca effect katmanında |
| Callback → coroutine (Wasmoon `:await()` yerine) | Açık kontrol akışı, single-flight refresh'i yazmak kolay, köprü mock'lanabilir |
| İzinler `/auth/me`'den | `/rbac/matrix` admin-only; UI gizleme için kullanıcının kendi izinleri yeterli |
| Guard `forbidden` → yönlendirme değil içerik | Kullanıcı neden reddedildiğini görür; kötü niyetli link döngüsü olmaz |
| `next` yalnızca `#/` önekli | Open redirect engeli |

## Kabul kriterleri (DoD)

- [ ] `dom.patch` input'a yazarken odak/imleç kaybolmaz (todo filtresine yazarken liste yeniden render olur).
- [ ] 100 elemanlı keyed listede bir eleman silinince yalnızca o düğüm kaldırılır (JS `nodes.size` bir azalır).
- [ ] `href="javascript:alert(1)"` vnode'u attribute olarak DOM'a yazılmaz.
- [ ] Coroutine dışından `api.get` çağrısı anlaşılır bir assert mesajıyla hata verir.
- [ ] Süresi dolmuş access token ile aynı anda 3 istek → Network sekmesinde **tek** `/auth/refresh`, 3 isteğin hepsi başarılı.
- [ ] Refresh de başarısızsa kullanıcı `#/login?next=...`'e düşer, state temizlenir.
- [ ] Sunucu kapalıyken istek → `NETWORK_ERROR` toast'u, uygulama donmaz.
- [ ] Tokensız `#/todos` → `#/login?next=%23%2Ftodos`; login sonrası `#/todos`.
- [ ] Login'liyken `#/login` → `#/`.
- [ ] todouser `#/users` → "yetkiniz yok" içeriği; menüde Kullanıcılar/Yetki/Denetim görünmez.
- [ ] `#/login?next=https://evil.com` → login sonrası `#/`.
- [ ] Çıkış sonrası `app.get_state().todos.items` boş.
- [ ] Aynı karede 5 dispatch → tek render (render sayacı debug log'u ile).
- [ ] Route değişiminde `document.title` güncellenir, odak `#main`'e gider.
- [ ] `luacheck web/src` temiz.

## 7. Doğrulama

```bash
cd web && ./build-wasm.sh && npm run dev &
docker compose up -d api postgres && make db.migrate db.seed

# Tarayıcı senaryoları (http://localhost:28000):
# 1. #/todos → login'e yönlenir (URL'de next)
# 2. user@todoapp.local / User123! → #/todos; menüde yalnızca Pano, Görevler
# 3. #/users → yetkisiz içeriği
# 4. DevTools > Application > localStorage > todo.auth.access_token'ı bozuk bir değerle değiştir
#    ama refresh_token'ı bırak → sayfayı yenile → /auth/me 401 → tek refresh → devam
# 5. Console:
#    __todo.lua.doString('return require("router").parse("#/todos/abc?x=1").params.id')   → "abc"
#    __todo.lua.doString('return require("router").guard({auth=true,page_key="users.list"}, {status="authenticated",permissions={}})') → "forbidden"
# 6. API container'ı durdur → bir işlem yap → "Sunucuya ulaşılamadı" toast
docker compose stop api

luacheck src --std lua54 --globals js
```

## 8. Riskler

| Risk | Önlem |
|---|---|
| Wasmoon tablo↔JS dönüşümü (boş tablo, nil, integer/float) | Karmaşık veri köprüden JSON string olarak geçer; `json.lua` kontrollü encode |
| Coroutine resume JS callback içinden → Lua hatası JS'e sızar | Her resume `ok, err` kontrol eder, log'a yazar; `app.spawn` xpcall ile sarar |
| Patch algoritmasında hata → DOM ile vnode ağacı senkron dışı | Geliştirme modunda her 100 render'da bir tam yeniden mount seçeneği (debug bayrağı); F17 testleri |
| `on_enter` + render sırasında dispatch döngüsü | Render içinde dispatch yasak; `app.dispatch` render sırasında çağrılırsa `error` (dev) |
| Token `localStorage`'da | Bkz. §4.3 güvenlik notu; F18 kontrol listesinde |
| Handle sızıntısı | Patch'te kaldırılan her alt ağaç `release`; `__todo` üzerinden sayaç izlenir |

## 9. Tahmini Efor

**L** — ~3 gün (dom + patch 1, fetch + single-flight 0.5, store/reducer 0.5, router + guard 0.5, layout 0.5).
