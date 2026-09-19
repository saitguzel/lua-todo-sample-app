# ═══ FAZ 12 — FRONTEND İSKELET ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) — teknik düzeltmeler #1 (Wasmoon/Emscripten), #2 (Lua alt kümesi), #11 (optimizasyon), #12 (Tailwind).

## 1. Amaç

Tarayıcıda Lua 5.4 çalıştıran `todo-web` uygulamasının iskeleti kurulur: Wasmoon yükleyicisi (`glue.js`), Lua kaynaklarını tek pakete toplayan `build-wasm.sh`, uygulamanın barındırıldığı `index.html`, tema değişkenlerini tanımlayan `styles.css` ve Lua tarafında giriş noktası `main.lua`. Faz sonunda tarayıcıda sayfa açıldığında Wasmoon yüklenir, `main.lua` çalışır, `shared/` modülleri `require` edilebilir ve ekranda "todo-web hazır" yazan minimal bir DOM render edilir.

**Önemli gerçeklik (teknik düzeltme #1):** Lua kodu WASM'a **derlenmez**. Wasmoon, Lua 5.4 yorumlayıcısının Emscripten ile önceden derlenmiş halini (`glue.wasm`) npm paketi olarak getirir. Bizim Lua dosyalarımız bu VM içinde yorumlanır. Bu yüzden Emscripten toolchain'i kurulmaz; "build" = Lua kaynaklarını paketlemek + JS glue'yu bundle etmek + wasm dosyasını kopyalamak.

## 2. Önkoşullar

| Faz | Neden |
|---|---|
| F0 | `web/` dizini, docker-compose `web` servisi, Makefile `web.build` hedefi |
| F1 | `shared/src/*.lua` frontend'e paketlenecek |
| F5 | (Paralel çalışma için yeterli) Login endpoint'i; bu fazda henüz çağrılmaz, CORS doğrulaması için |

## 3. Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/package.json` | npm bağımlılıkları (`wasmoon`, `canvas-confetti`) + dev (`esbuild`, `serve`) + script'ler |
| `web/build-wasm.sh` | `glue.wasm` kopyala → `public/app.wasm`; Lua kaynaklarını `public/bundle.json`'a paketle; `glue.js`'i esbuild ile bundle et |
| `web/js/glue.js` | Wasmoon yükleyici, Lua modüllerini mount etme, JS köprülerini (DOM, fetch, storage, timer, confetti, console) Lua'ya expose etme |
| `web/public/index.html` | Kabuk HTML, CSP, Tailwind CDN, preload, `#app` kökü, noscript/yükleme göstergesi |
| `web/public/styles.css` | CSS değişkenleri (light/dark), temel tipografi, skeleton animasyonu, odak halkası |
| `web/public/app.wasm` | **Üretilen dosya** (git'e girmez) — Wasmoon `glue.wasm` kopyası |
| `web/public/bundle.json` | **Üretilen dosya** — `{ "modül.adı": "lua kaynak kodu" }` |
| `web/public/glue.js` | **Üretilen dosya** — esbuild çıktısı (ESM, wasmoon dahil) |
| `web/src/main.lua` | Lua giriş noktası: bağımlılıkları yükler, `app.start()` çağırır, global hata yakalayıcı |
| `.gitignore` (güncelleme) | `web/node_modules`, `web/public/app.wasm`, `web/public/bundle.json`, `web/public/glue.js` |

## 4. Dosya Bazlı Tasarım

### 4.1 `web/package.json`

```json
{
  "name": "todo-web",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "./build-wasm.sh",
    "build:prod": "MODE=production ./build-wasm.sh",
    "dev": "./build-wasm.sh && serve public -l 28000 --single",
    "watch": "find src ../shared/src js -name '*.lua' -o -name '*.js' | entr -r npm run dev"
  },
  "dependencies": {
    "wasmoon": "^1.16.0",
    "canvas-confetti": "^1.9.3"
  },
  "devDependencies": {
    "esbuild": "^0.24.0",
    "serve": "^14.2.0"
  }
}
```

- `serve --single`: SPA fallback gereksiz (hash router) ama zararsız; kaldırılabilir.
- `entr` sistem aracıdır, npm bağımlılığı değil; yoksa `watch` script'i kullanılmaz, elle `npm run dev`.
- Sürümler `package-lock.json` ile sabitlenir.

### 4.2 `web/build-wasm.sh`

**Adımlar:**

```
1. set -euo pipefail; cd "$(dirname "$0")"
2. [ -d node_modules ] || npm ci
3. cp node_modules/wasmoon/dist/glue.wasm public/app.wasm
4. Lua paketleme:
     src/**/*.lua        → modül adı: yol → "views/todos.lua" → "views.todos"
     ../shared/src/*.lua → modül adı: "todo_shared.types", "todo_shared.validation", "todo_shared.protocol"
   Her dosya: sözdizimi kontrolü (luac5.4 -p), sonra JSON'a string olarak eklenir.
5. MODE=production ise: yorum satırları ve baştaki boşluklar silinir (basit minify, bkz. F17)
6. public/bundle.json yazılır (jq ile) + içerik hash'i: public/bundle.<hash8>.json
7. esbuild js/glue.js --bundle --format=esm --target=es2020 --outfile=public/glue.js
     production: --minify --sourcemap=external
8. index.html içindeki __BUNDLE_HASH__ yer tutucusu hash ile değiştirilir (cache busting)
9. Özet: dosya boyutları (ls -lh), gzip boyutları
```

**Paketleme kodu (jq ile, ek dil gerektirmeden):**

```bash
# Her Lua dosyasını {name, src} satırına çevir, sonra tek nesnede birleştir
bundle_entries() {
  local root=$1 prefix=$2
  find "$root" -name '*.lua' | sort | while read -r f; do
    rel=${f#"$root"/}; mod=${rel%.lua}; mod=${mod//\//.}
    luac5.4 -p "$f"                          # sözdizimi hatasında build durur
    jq -Rs --arg n "$prefix$mod" '{($n): .}' "$f"
  done
}
{ bundle_entries src ""; bundle_entries ../shared/src "todo_shared."; } | jq -s 'add' > public/bundle.json
```

`luac5.4` yoksa uyarı basılır ve kontrol atlanır (CI'da zorunlu). Modül adlandırması: `src/views/todos.lua` → `views.todos`, `shared/src/validation.lua` → `todo_shared.validation`.

**Neden JSON bundle, `mountFile` ile tek tek dosya değil?** Tek HTTP isteği; `fetch` + `JSON.parse` sonrası her modül `factory.mountFile("/lua/<yol>.lua", src)` ile sanal dosya sistemine yazılır — böylece Lua'nın standart `require` mekanizması (`package.path = "/lua/?.lua;/lua/?/init.lua"`) çalışır, özel `package.searchers` gerekmez.

**Shared kütüphanenin backend ile aynı adla çağrılması:** Kanonik karar (F1): **her iki tarafta da `todo_shared.*`** (`require("todo_shared.types")`). Backend'de rock kurulumu veya dev mount hedefi `/app/lib/todo_shared` + `lua_package_path "/app/lib/?.lua;..."` (F0/F3); frontend bundle'ında `build-wasm.sh` `shared/src/x.lua` dosyasını `todo_shared.x` modül adıyla manifeste yazar. Kaynak ağaç prompt'taki gibi (`shared/src/`) kalır.

### 4.3 `web/js/glue.js`

**Sorumluluklar:**
1. Wasmoon `LuaFactory`'yi `app.wasm` URL'i ile oluşturmak.
2. `bundle.json`'u çekip modülleri mount etmek.
3. Lua engine'e **dar ve açık** bir JS API'si (`js` global tablosu) vermek — tüm `window`'u değil.
4. Lua'yı başlatmak (`require("main")`), yükleme göstergesini kaldırmak, fatal hatayı kullanıcıya göstermek.
5. `wasmMemory` erişimini (debug) `window.__todo.memory()` ile açmak.

**İskelet:**

```js
// Wasmoon yükleyici ve Lua ↔ JS köprüsü
import { LuaFactory } from "wasmoon";
import confetti from "canvas-confetti";

const WASM_URL = new URL("./app.wasm", import.meta.url).href;
const BUNDLE_URL = document.querySelector('meta[name="lua-bundle"]').content;

// Lua'ya verilen DOM nesneleri ID ile tutulur; Lua'ya ham DOM referansı yerine sayı verilir
// (Wasmoon JS nesnelerini proxy'leyebilir ama sayı handle GC ve performans açısından öngörülebilir)
const nodes = new Map();   // id -> Node
let nextId = 1;
const handle = (node) => { const id = nextId++; nodes.set(id, node); return id; };

const bridge = {
  dom: {
    create: (tag) => handle(document.createElement(tag)),
    text: (s) => handle(document.createTextNode(s)),
    byId: (id) => { const n = document.getElementById(id); return n ? handle(n) : null; },
    setAttr: (h, k, v) => nodes.get(h).setAttribute(k, v),
    removeAttr: (h, k) => nodes.get(h).removeAttribute(k),
    setProp: (h, k, v) => { nodes.get(h)[k] = v; },     // value, checked, disabled
    getProp: (h, k) => nodes.get(h)[k],
    setText: (h, s) => { nodes.get(h).textContent = s; },
    append: (p, c) => nodes.get(p).appendChild(nodes.get(c)),
    replaceChildren: (p, ...cs) => nodes.get(p).replaceChildren(...cs.map((c) => nodes.get(c))),
    remove: (h) => { nodes.get(h)?.remove(); nodes.delete(h); },
    release: (h) => nodes.delete(h),                    // Lua tarafı tree'yi atınca çağırır
    focus: (h) => nodes.get(h).focus(),
    on: (h, ev, fn) => { const f = (e) => fn(eventToLua(e)); nodes.get(h).addEventListener(ev, f); return () => nodes.get(h)?.removeEventListener(ev, f); },
    setClass: (h, cls, on) => nodes.get(h).classList.toggle(cls, on),
    setRootAttr: (k, v) => document.documentElement.setAttribute(k, v),
    title: (s) => { document.title = s; },
    activeElement: () => (document.activeElement ? handle(document.activeElement) : null), // modal focus iadesi (F16)
    showModal: (h) => nodes.get(h).showModal(),         // native <dialog>: focus trap + Esc tarayıcıdan (F16)
    closeModal: (h) => nodes.get(h).close(),
  },
  http: {
    // Callback tabanlı: Lua coroutine'i yield eder, callback resume eder (F13 fetch.lua)
    request: (method, url, headersJson, body, cb) => {
      fetch(url, { method, headers: JSON.parse(headersJson || "{}"), body: body ?? undefined, credentials: "omit" })
        .then(async (r) => cb(null, r.status, await r.text(), r.headers.get("content-type") || ""))
        .catch((e) => cb(String(e.message || e), 0, "", ""));
    },
    download: (url, token, filename) => { /* CSV export: fetch → blob → a[download] */ },
  },
  storage: {
    get: (k) => { try { return localStorage.getItem(k); } catch { return null; } },
    set: (k, v) => { try { localStorage.setItem(k, v); return true; } catch { return false; } },
    remove: (k) => { try { localStorage.removeItem(k); } catch {} },
  },
  timer: {
    after: (ms, fn) => setTimeout(fn, ms),
    cancel: (id) => clearTimeout(id),
    raf: (fn) => requestAnimationFrame(fn),
  },
  location: {
    hash: () => location.hash,
    setHash: (h) => { location.hash = h; },
    replace: (h) => history.replaceState(null, "", h),   // geçmişe yazmadan (reset token'ı URL'den silmek, F14)
    onHashChange: (fn) => window.addEventListener("hashchange", () => fn(location.hash)),
  },
  keyboard: {
    onKey: (fn) => document.addEventListener("keydown", (e) => {
      const t = e.target;
      const typing = t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName);
      if (fn(e.key, typing, e.ctrlKey || e.metaKey) === true) e.preventDefault();
    }),
  },
  media: {
    prefersDark: () => matchMedia("(prefers-color-scheme: dark)").matches,
    reducedMotion: () => matchMedia("(prefers-reduced-motion: reduce)").matches,
    matches: (q) => matchMedia(q).matches,
    onChange: (q, fn) => matchMedia(q).addEventListener("change", (e) => fn(e.matches)),  // tema "system" (F16)
  },
  // Tarih biçimleme: API UTC ISO döner, UI yerel saat gösterir (F14 profil, F15 audit tablosu)
  format_date: (iso, style) => iso ? new Intl.DateTimeFormat("tr-TR",
    style === "date" ? { dateStyle: "medium" } : { dateStyle: "medium", timeStyle: "short" }).format(new Date(iso)) : "",
  // Admin "parola oluştur" (F15): kriptografik rastgele, karışık karakter sınıfları
  random_password: (len) => {
    const cs = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%*-_";
    const a = crypto.getRandomValues(new Uint32Array(len || 16));
    return Array.from(a, (x) => cs[x % cs.length]).join("");
  },
  confetti: (opts) => { if (!bridge.media.reducedMotion()) confetti(opts ? JSON.parse(opts) : { particleCount: 120, spread: 70 }); },
  json: { encode: (v) => JSON.stringify(v), decode: (s) => JSON.parse(s) },   // Lua tarafında cjson yok
  log: (level, msg) => console[level]?.(`[lua] ${msg}`),
  config: () => JSON.stringify(window.__TODO_CONFIG__ || {}),
};

function eventToLua(e) {
  // Lua'ya yalnızca ihtiyaç duyulan alanlar düz nesne olarak geçer
  return {
    type: e.type, key: e.key, value: e.target?.value, checked: e.target?.checked,
    targetId: e.target?.dataset?.id, action: e.target?.closest("[data-action]")?.dataset.action,
    preventDefault: () => e.preventDefault(),
  };
}

async function boot() {
  const t0 = performance.now();
  const factory = new LuaFactory(WASM_URL);
  const [lua, bundle] = await Promise.all([
    factory.createEngine({ openStandardLibs: true, injectObjects: true, enableProxy: false }),
    fetch(BUNDLE_URL).then((r) => { if (!r.ok) throw new Error(`bundle ${r.status}`); return r.json(); }),
  ]);
  for (const [mod, src] of Object.entries(bundle)) {
    await factory.mountFile(`/lua/${mod.replaceAll(".", "/")}.lua`, src);
  }
  lua.global.set("js", bridge);
  await lua.doString(`package.path = "/lua/?.lua;/lua/?/init.lua"`);
  await lua.doString(`require("main")`);
  document.getElementById("boot")?.remove();
  window.__todo = { lua, memory: () => factory.getLuaModule().then((m) => m.module.HEAPU8.length), bootMs: performance.now() - t0 };
}

boot().catch((err) => {
  console.error(err);
  const el = document.getElementById("boot");
  if (el) { el.textContent = "Uygulama yüklenemedi. Sayfayı yenileyin."; el.setAttribute("role", "alert"); }
});
```

**Köprü tasarım ilkeleri:**

| İlke | Uygulama |
|---|---|
| Dar yüzey | Lua yalnızca `js.*` altındaki fonksiyonları görür; `window`/`document` doğrudan verilmez (XSS sonrası saldırgan kodun Lua'dan erişebileceği yüzeyi daraltır, köprü test edilebilir olur) |
| Handle tabanlı DOM | DOM düğümleri sayı ID; Lua ↔ JS proxy nesnesi taşınmaz. `dom.release` ile bellek sızıntısı önlenir |
| Metin güvenliği | `innerHTML` **hiç** expose edilmez; yalnızca `textContent` ve `createTextNode` → XSS yok |
| JSON | Lua 5.4'te cjson yok; JSON encode/decode JS'e devredilir (`JSON.parse` hızlı ve doğru). Lua tarafında `json.lua` sarmalayıcısı F13'te |
| Async | Promise Lua'ya taşınmaz; callback verilir, Lua coroutine ile sarmalar (F13). Wasmoon'un `promise:await()` özelliği de mümkün ama callback modeli açık ve test edilebilir |
| Hata izolasyonu | Lua'dan çağrılan callback'ler JS tarafında try/catch ile sarılır; Lua hatası konsola `[lua]` önekiyle düşer |

**`wasmMemory` erişimi (prompt gereği):** Wasmoon'un Emscripten modülü `factory.getLuaModule()` ile alınır; `HEAPU8.length` ile WASM bellek boyutu okunur. Yalnızca debug/profil için `window.__todo.memory()`; üretimde de zararsız.

### 4.4 `web/public/index.html`

```html
<!doctype html>
<html lang="tr" data-theme="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Todo</title>
  <meta name="lua-bundle" content="./bundle.__BUNDLE_HASH__.json">
  <meta http-equiv="Content-Security-Policy" content="
    default-src 'self';
    script-src 'self' 'wasm-unsafe-eval' https://cdn.tailwindcss.com;
    style-src 'self' 'unsafe-inline';
    connect-src 'self';
    img-src 'self' data:;
    font-src 'self';
    object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'">
  <link rel="preload" href="./app.wasm" as="fetch" type="application/wasm" crossorigin>
  <link rel="preload" href="./bundle.__BUNDLE_HASH__.json" as="fetch" crossorigin>
  <script>
    // Tema FOUC önleme: Lua yüklenmeden önce kayıtlı temayı uygula
    try {
      const t = localStorage.getItem("todo.theme") ||
        (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      document.documentElement.dataset.theme = t;
    } catch {}
    window.__TODO_CONFIG__ = { apiBase: `${location.origin}/api/v1` };
  </script>
  <script src="https://cdn.tailwindcss.com"></script>
  <link rel="stylesheet" href="./styles.css">
  <script type="module" src="./glue.js"></script>
</head>
<body class="min-h-screen bg-[var(--bg)] text-[var(--fg)]">
  <a href="#main" class="skip-link">İçeriğe atla</a>
  <div id="toast-root" aria-live="polite" aria-atomic="false"></div>
  <div id="modal-root"></div>
  <div id="app">
    <div id="boot" class="boot" aria-busy="true">Yükleniyor…</div>
  </div>
  <noscript>Bu uygulama JavaScript ve WebAssembly gerektirir.</noscript>
</body>
</html>
```

**CSP notları:**
- `'wasm-unsafe-eval'`: `WebAssembly.instantiate` için zorunlu; `'unsafe-eval'` **verilmez**.
- Inline `<script>` (tema + config) CSP'de `'self'` ile çalışmaz → iki seçenek: (a) SHA-256 hash'i CSP'ye eklemek (`'sha256-...'`), (b) bu kodu `boot.js` dosyasına taşımak. **Karar: (b)** — `public/boot.js`, hash bakımı gerektirmez. Yukarıdaki inline blok uygulamada `<script src="./boot.js">` olur.
- Tailwind Play CDN kendi `<style>` enjekte eder → `style-src 'unsafe-inline'` dev'de gerekli. Prod'da (F18) derlenmiş CSS ile `'unsafe-inline'` kaldırılır.
- `apiBase` dev ve prod'da aynı: sayfanın origin'i + `/api/v1` (00 §6.2). Dev'de web nginx'i (`deploy/web/dev.conf`), prod'da proxy `/api/`'yi api'ye aktarır → `connect-src 'self'` yeterli; uygulama localhost, IP veya domain ile açılabilir.
- Tercih edilen: CSP'yi meta yerine **HTTP header** olarak web sunucusu (F18 nginx) göndermek; meta, dev sunucusu (`serve`) header ekleyemediği için.

### 4.5 `web/public/styles.css`

```css
/* Tema değişkenleri: Tailwind sınıfları bu değişkenlere referans verir (bg-[var(--bg)]) */
:root, [data-theme="light"] {
  --bg: #f8fafc; --bg-elev: #ffffff; --fg: #0f172a; --fg-muted: #64748b;
  --border: #e2e8f0; --primary: #4f46e5; --primary-fg: #ffffff;
  --danger: #dc2626; --success: #16a34a; --warning: #d97706;
  --focus: #6366f1; --skeleton: #e2e8f0; --skeleton-hi: #f1f5f9;
  --radius: 0.5rem; --shadow: 0 1px 3px rgb(0 0 0 / .08);
  color-scheme: light;
}
[data-theme="dark"] {
  --bg: #0b1120; --bg-elev: #111827; --fg: #e5e7eb; --fg-muted: #9ca3af;
  --border: #1f2937; --primary: #818cf8; --primary-fg: #0b1120;
  --danger: #f87171; --success: #4ade80; --warning: #fbbf24;
  --focus: #a5b4fc; --skeleton: #1f2937; --skeleton-hi: #374151;
  color-scheme: dark;
}
```

Ek bölümler:
- `.skip-link` (odakta görünür), `:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }`
- `.boot` yükleme ekranı (ortalanmış, spinner CSS-only)
- `.skeleton` shimmer animasyonu (`@keyframes shimmer`), `@media (prefers-reduced-motion: reduce)` ile kapalı
- `.sr-only` (Tailwind'de var; CDN olmadan da çalışsın diye tekrar tanım)
- Priority/status rozet renkleri: `.badge-high`, `.badge-medium`, `.badge-low`, `.badge-completed` vb. — değişkenlerle
- Kontrast: tüm fg/bg çiftleri WCAG AA ≥ 4.5:1 (F16'da ölçülür)

### 4.6 `web/src/main.lua`

```lua
-- Uygulama giriş noktası: glue.js tarafından require("main") ile çağrılır.
-- Global hata yakalayıcıyı kurar, uygulamayı başlatır.

local log = function(level, ...) js.log(level, table.concat({ ... }, " ")) end

-- Lua 5.4 kontrolü: shared kod alt kümede yazıldı ama frontend 5.4 varsayar
assert(_VERSION == "Lua 5.4", "Beklenmeyen Lua sürümü: " .. _VERSION)

local ok, err = xpcall(function()
  local types = require("todo_shared.types")       -- paketleme doğrulaması
  local app = require("app")                  -- F13'te gerçek implementasyon
  app.start({ config = js.json.decode(js.config()) })
end, debug.traceback)

if not ok then
  log("error", "Başlatma hatası: " .. tostring(err))
  local root = js.dom.byId("app")
  if root then js.dom.setText(root, "Beklenmeyen bir hata oluştu.") end
end
```

Bu fazda `app.lua` henüz yoksa geçici olarak `app = { start = function() ... "todo-web hazır" ... end }` stub'ı kullanılır (F13'te değiştirilir). Stub, `types.PAGES` sayısını da ekrana yazar → shared paketlemesinin çalıştığının kanıtı.

## 5. Teknik Kararlar

| Karar | Neden |
|---|---|
| Emscripten yok, Wasmoon'un hazır `glue.wasm`'ı | Teknik düzeltme #1; Lua VM'i yeniden derlemek hiçbir fayda sağlamaz |
| `app.wasm` adı korunur | Prompt'taki dosya ağacıyla uyum; içerik Wasmoon'un wasm'ı |
| JSON bundle + `mountFile` | Tek istek, standart `require` semantiği, özel loader yok |
| esbuild | Wasmoon ESM paketini ve canvas-confetti'yi tek dosyaya toplamak için en küçük araç; import map + CDN alternatifi CSP'yi genişletirdi |
| Handle tabanlı DOM köprüsü | Proxy nesneleri GC ve Lua↔JS sınırında öngörülemez; sayı handle ucuz ve serbest bırakılabilir |
| `innerHTML` yok | XSS'i tasarımla engellemek |
| JSON JS'te | Lua 5.4'te yerleşik JSON yok; saf Lua JSON parser hem yavaş hem kod yükü |
| Hash router | Sunucu yapılandırması gerektirmez, statik hosting yeterli |
| Tema FOUC önleme script'i | Lua VM yüklenene kadar (~100–300 ms) yanlış tema flaşını engeller |

## Kabul kriterleri (DoD)

- [ ] `cd web && npm ci && ./build-wasm.sh` hatasız biter; `public/app.wasm`, `public/bundle.<hash>.json`, `public/glue.js` oluşur.
- [ ] Sözdizimi hatalı bir `.lua` dosyası build'i **durdurur** ve dosya adını basar.
- [ ] `npm run dev` → `http://localhost:28000` açılır, konsolda hata yok, ekranda "todo-web hazır" ve `PAGES` sayısı (9) görünür.
- [ ] `window.__todo.bootMs` < 1000 ms (yerel, soğuk cache).
- [ ] `window.__todo.memory()` bir sayı döner.
- [ ] Tarayıcı konsolunda CSP ihlali yok; `'unsafe-eval'` CSP'de yok.
- [ ] `bundle.json` bozuk/404 olduğunda "Uygulama yüklenemedi" mesajı `role="alert"` ile görünür.
- [ ] `localStorage` erişimi engelli (gizli mod / 3. parti) iken uygulama çökmez.
- [ ] Tema: `localStorage.setItem("todo.theme","dark")` + yenile → ilk boyamada koyu tema (flaş yok).
- [ ] Üretilen dosyalar `.gitignore`'da.
- [ ] `luacheck web/src` temiz (`std = "lua54"`, `globals = { "js" }`).

## 7. Doğrulama

```bash
cd web
npm ci
./build-wasm.sh
ls -lh public/                       # app.wasm (~250-400 KB), bundle.*.json, glue.js
jq 'keys' public/bundle.*.json       # ["main", "todo_shared.protocol", "todo_shared.types", "todo_shared.validation", ...]
npm run dev &
# Tarayıcı: http://localhost:28000
#  - DevTools > Console: hata yok
#  - DevTools > Network: app.wasm ve bundle preload ile, tek seferde
#  - Console: __todo.bootMs, await __todo.memory()
# Hata senaryosu:
echo 'local x = = 1' > src/broken.lua && ./build-wasm.sh; echo "exit=$?"   # exit≠0 beklenir
rm src/broken.lua
luacheck src --std lua54 --globals js
```

## 8. Riskler

| Risk | Önlem |
|---|---|
| Wasmoon sürüm değişince `glue.wasm` yolu / API (`mountFile`, `createEngine` seçenekleri) değişir | Sürüm `package-lock.json` ile sabit; build script yol yoksa açık hata verir |
| Wasmoon'un JS↔Lua otomatik tip dönüşümü (tablo ↔ obje) sürprizleri | Köprüde yalnızca primitifler, fonksiyonlar ve düz eventToLua nesnesi; karmaşık veri JSON string olarak geçer |
| `mountFile` await'leri seri → çok modülde yavaş başlangıç | ~25 modül için ihmal edilebilir; F17'de ölçülür, gerekirse `Promise.all` |
| Tailwind CDN yavaş/erişilemez | CSS değişkenleri + `styles.css` temel düzeni tek başına okunabilir kılar; prod'da CDN yok (F18) |
| Lua 5.4 ile LuaJIT farkı shared kodda yakalanmaz | CI'da shared spec iki yorumlayıcıda (F11); frontend `main.lua`'da sürüm assert'i |
| Handle haritasında sızıntı (release edilmeyen düğümler) | F13 `dom.lua` unmount'ta alt ağacı release eder; `__todo` debug'da `nodes.size` izlenir |

## 9. Tahmini Efor

**M** — ~1.5 gün (build script 0.5, glue köprüsü 0.5, HTML/CSS/CSP 0.5).
