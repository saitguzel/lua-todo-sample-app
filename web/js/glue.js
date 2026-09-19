// Wasmoon yükleyici ve Lua ↔ JS köprüsü (F12).
// BUNDLE_PATH / ADMIN_BUNDLE_PATH / WASM_PATH esbuild --define ile build sırasında enjekte edilir.
import { LuaFactory } from "wasmoon";

const WASM_URL = new URL(WASM_PATH, import.meta.url).href;
const BUNDLE_URL = new URL(BUNDLE_PATH, import.meta.url).href;
const ADMIN_BUNDLE_URL = new URL(ADMIN_BUNDLE_PATH, import.meta.url).href;

// Lua'ya verilen DOM nesneleri ID ile tutulur; ham DOM referansı Lua'ya taşınmaz.
const nodes = new Map(); // id -> Node
let nextId = 1;
const handle = (node) => { const id = nextId++; nodes.set(id, node); return id; };
const get = (h) => nodes.get(h);

// Lua'ya yalnızca ihtiyaç duyulan event alanları düz nesne olarak geçer
function eventToLua(e) {
  return {
    type: e.type,
    key: e.key,
    value: e.target?.value,
    checked: e.target?.checked,
    targetId: e.target?.dataset?.id,
    action: e.target?.closest?.("[data-action]")?.dataset.action,
  };
}

// Kaldırılan alt ağaçta açık dialog varsa odağı tetikleyen öğeye geri ver (F16)
function returnFocusOf(n) {
  if (!(n instanceof Element)) return null;
  const ds = n.tagName === "DIALOG" ? [n] : [...n.querySelectorAll("dialog")];
  return ds.find((d) => d._returnFocus)?._returnFocus ?? null;
}

let factory = null;
const loadedBundles = new Map(); // url -> Promise
function mountBundle(url) {
  if (!loadedBundles.has(url)) {
    loadedBundles.set(url, fetch(url)
      .then((r) => { if (!r.ok) throw new Error(`bundle ${r.status}`); return r.json(); })
      .then((bundle) => Promise.all(Object.entries(bundle)
        .map(([mod, src]) => factory.mountFile(`/lua/${mod.replaceAll(".", "/")}.lua`, src))))
      .catch((e) => { loadedBundles.delete(url); throw e; }));
  }
  return loadedBundles.get(url);
}

const bridge = {
  dom: {
    create: (tag) => handle(document.createElement(tag)),
    text: (s) => handle(document.createTextNode(s)),
    byId: (id) => { const n = document.getElementById(id); return n ? handle(n) : null; },
    setAttr: (h, k, v) => get(h)?.setAttribute(k, v),
    removeAttr: (h, k) => get(h)?.removeAttribute(k),
    // value/checked/disabled gibi property'ler attr değil prop ile set edilir
    setProp: (h, k, v) => { const n = get(h); if (n) n[k] = v; },
    getProp: (h, k) => { const n = get(h); return n ? n[k] : null; },
    setText: (h, s) => { const n = get(h); if (n) n.textContent = s; },
    append: (p, c) => get(p)?.appendChild(get(c)),
    // keyed diff: düğüm zaten doğru konumdaysa DOM'a dokunulmaz (odak korunur)
    insertAt: (p, c, i) => {
      const pn = get(p), cn = get(c);
      if (!pn || !cn) return;
      const ref = pn.childNodes[i] ?? null;
      if (ref !== cn) pn.insertBefore(cn, ref);
    },
    replaceWith: (o, n) => {
      const on = get(o), nn = get(n);
      if (!on || !nn) return;
      const rf = returnFocusOf(on);
      on.replaceWith(nn);
      rf?.focus?.();
    },
    replaceChildren: (p, ...cs) => get(p)?.replaceChildren(...cs.map(get).filter(Boolean)),
    remove: (h) => {
      const n = get(h);
      if (n) { const rf = returnFocusOf(n); n.remove(); rf?.focus?.(); }
      nodes.delete(h);
    },
    release: (h) => nodes.delete(h), // Lua tarafı ağacı atınca handle'ı serbest bırakır
    focus: (h) => get(h)?.focus?.(),
    on: (h, ev, fn) => {
      const f = (e) => {
        // SPA: form hiçbir zaman native submit edilmez (CSP form-action 'none')
        if (e.type === "submit") e.preventDefault();
        // native dialog Esc → cancel: kapanışı Lua state'i yönetir
        if (e.type === "cancel") e.preventDefault();
        try { fn(eventToLua(e)); } catch (err) { console.error("[lua]", err); }
      };
      get(h)?.addEventListener(ev, f);
      return () => get(h)?.removeEventListener(ev, f);
    },
    setClass: (h, cls, on) => get(h)?.classList.toggle(cls, on),
    setRootAttr: (k, v) => document.documentElement.setAttribute(k, v),
    title: (s) => { document.title = s; },
    activeElement: () => (document.activeElement ? handle(document.activeElement) : null),
    // Seçili satır: odaktaki öğenin en yakın [data-id] atası (F16 e/d kısayolları)
    activeDataId: () => document.activeElement?.closest?.("[data-id]")?.dataset.id ?? null,
    // Render sonrası açılmamış modal dialog'ları showModal ile aç (focus trap + inert arka plan)
    openModals: () => {
      document.querySelectorAll("dialog[data-modal]:not([open])").forEach((d) => {
        d._returnFocus = document.activeElement;
        d.showModal();
      });
    },
    modalOpen: () => !!document.querySelector("dialog[open]"),
    focusFirst: (sel) => { document.querySelector(sel)?.focus?.(); },
    _size: () => nodes.size,
  },
  http: {
    // Callback tabanlı: Lua coroutine'i yield eder, callback resume eder (F13 fetch.lua)
    request: (method, url, headersJson, body, cb) => {
      const ctrl = new AbortController();
      const to = setTimeout(() => ctrl.abort(), 15000); // 15 sn zaman aşımı → NETWORK_ERROR
      fetch(url, {
        method,
        headers: JSON.parse(headersJson || "{}"),
        body: body ?? undefined,
        credentials: "omit",
        signal: ctrl.signal,
      })
        .then(async (r) => {
          clearTimeout(to);
          cb(undefined, r.status, await r.text(), r.headers.get("content-type") || "",
            r.headers.get("retry-after") || "");
        })
        .catch((e) => { clearTimeout(to); cb(String(e?.message || e), 0, "", "", ""); });
    },
    // CSV export: Authorization header gerektiğinden <a href> yerine blob indirilir (F15)
    download: (url, token, filename, cb) => {
      fetch(url, { headers: token ? { Authorization: `Bearer ${token}` } : {}, credentials: "omit" })
        .then((r) => { if (!r.ok) throw new Error(`download ${r.status}`); return r.blob(); })
        .then((blob) => {
          const a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = filename || "export.csv";
          document.body.appendChild(a);
          a.click();
          a.remove();
          setTimeout(() => URL.revokeObjectURL(a.href), 5000);
          cb?.(undefined);
        })
        .catch((e) => { console.error("[lua] download hatası:", e); cb?.(String(e?.message || e)); });
    },
  },
  storage: {
    get: (k) => { try { return localStorage.getItem(k); } catch { return null; } },
    set: (k, v) => { try { localStorage.setItem(k, v); return true; } catch { return false; } },
    remove: (k) => { try { localStorage.removeItem(k); } catch { /* engelli */ } },
  },
  timer: {
    after: (ms, fn) => setTimeout(() => { try { fn(); } catch (e) { console.error("[lua]", e); } }, ms),
    cancel: (id) => clearTimeout(id),
    raf: (fn) => requestAnimationFrame(() => { try { fn(); } catch (e) { console.error("[lua]", e); } }),
    now: () => Date.now(),
  },
  location: {
    hash: () => location.hash,
    setHash: (h) => { location.hash = h; },
    replace: (h) => history.replaceState(null, "", h), // reset token'ı URL'den silmek (F14)
    onHashChange: (fn) => window.addEventListener("hashchange", () => { try { fn(location.hash); } catch (e) { console.error("[lua]", e); } }),
  },
  keyboard: {
    onKey: (fn) => document.addEventListener("keydown", (e) => {
      const t = e.target;
      const typing = t?.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t?.tagName);
      try {
        if (fn(e.key, !!typing, e.ctrlKey || e.metaKey, e.altKey, t?.tagName || "") === true) e.preventDefault();
      } catch (err) { console.error("[lua]", err); }
    }),
  },
  media: {
    prefersDark: () => matchMedia("(prefers-color-scheme: dark)").matches,
    reducedMotion: () => matchMedia("(prefers-reduced-motion: reduce)").matches,
    matches: (q) => matchMedia(q).matches,
    onChange: (q, fn) => matchMedia(q).addEventListener("change", (e) => { try { fn(e.matches); } catch (err) { console.error("[lua]", err); } }), // tema "system" (F16)
  },
  // Admin view'ları ayrı bundle'da (F17 #7); ilk admin route'unda yüklenir
  loadBundle: (name, cb) => {
    const url = name === "admin" ? ADMIN_BUNDLE_URL : null;
    if (!url) { cb(`bilinmeyen bundle: ${name}`); return; }
    mountBundle(url).then(() => cb(undefined)).catch((e) => cb(String(e?.message || e)));
  },
  // API UTC ISO döner, UI yerel saat gösterir (F14 profil, F15 audit tablosu)
  format_date: (iso, style) => {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return String(iso);
    return new Intl.DateTimeFormat("tr-TR",
      style === "date" ? { dateStyle: "medium" } : { dateStyle: "medium", timeStyle: "short" }).format(d);
  },
  // datetime-local girdisini yerel saat → UTC ISO'ya çevirir (F14 todo formu)
  to_iso_utc: (localValue) => {
    if (!localValue) return null;
    const d = new Date(localValue);
    return Number.isNaN(d.getTime()) ? null : d.toISOString().replace(/\.\d{3}Z$/, "Z");
  },
  // UTC ISO → datetime-local input değeri ("YYYY-MM-DDTHH:MM", yerel saat)
  to_local_input: (iso) => {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return "";
    d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
    return d.toISOString().slice(0, 16);
  },
  // Admin "parola oluştur" (F15): kriptografik rastgele, karışık karakter sınıfları
  random_password: (len) => {
    const cs = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%*-_";
    const a = crypto.getRandomValues(new Uint32Array(len || 16));
    // şema gereği her sınıftan en az bir karakter garanti edilir
    return "Aa1!" + Array.from(a.slice(4), (x) => cs[x % cs.length]).join("");
  },
  clipboard: (text) => { navigator.clipboard?.writeText(text).catch(() => { /* sessiz */ }); },
  confetti: (opts) => {
    // canvas-confetti dinamik import: ilk kullanıma kadar yüklenmez (F17)
    import("canvas-confetti").then(({ default: confetti }) => {
      const base = { disableForReducedMotion: true, ...(opts ? JSON.parse(opts) : {}) };
      if (!bridge.media.reducedMotion()) confetti(base);
    }).catch((e) => console.error("[lua] confetti:", e));
  },
  // Lua 5.4'te cjson yok; JSON JS tarafında çözülür (F13 json.lua sarmalayıcısı)
  // null değerler atılır: Lua'da nil (alan yok) olarak görünür
  json: { encode: (v) => JSON.stringify(v), decode: (s) => JSON.parse(s, (_k, v) => (v === null ? undefined : v)) },
  log: (level, msg) => console[level]?.(`[lua] ${msg}`),
  config: () => JSON.stringify(window.__TODO_CONFIG__ || {}),
};

// Wasmoon JS null'ı Lua'ya aktaramaz (injectObjects kapalı) ve dönen nesneleri derin kopyalar →
// köprüden dönen null ve DOM nesneleri (appendChild'ın döndürdüğü Node gibi) undefined (= nil) olur
const nn = (v) => (v === null || v instanceof Node || v instanceof Event ? undefined : v);
(function wrapNulls(obj) {
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === "function") obj[k] = (...a) => nn(v(...a));
    else if (v && typeof v === "object") wrapNulls(v);
  }
})(bridge);

async function boot() {
  const t0 = performance.now();
  // Wasmoon glue.wasm'ı Emscripten üzerinden WebAssembly.instantiateStreaming ile yükler
  // (application/wasm MIME ile servis edildiğinde indirme ve derleme paralel — F17 #6).
  factory = new LuaFactory(WASM_URL);
  const [lua] = await Promise.all([
    // injectObjects: false → JS null Lua'ya nil olarak gelir (true iken js_null userdata olur ve "x or y" kalıpları bozulur)
    factory.createEngine({ openStandardLibs: true, injectObjects: false, enableProxy: false }),
    mountBundle(BUNDLE_URL), // paralel mount (F17 optimizasyonu)
  ]);
  lua.global.set("js", bridge);
  await lua.doString(`package.path = "/lua/?.lua;/lua/?/init.lua"`);
  await lua.doString(`require("main")`);
  document.getElementById("boot")?.remove();
  window.__todo = {
    lua,
    bootMs: Math.round(performance.now() - t0),
    memory: () => factory.getLuaModule().then((m) => m.module.HEAPU8.length),
    nodesSize: () => nodes.size,
  };
  // E2E bekleme yardımcısı: keyfi sleep yerine data-ready (F17)
  document.documentElement.dataset.ready = "1";
  performance.mark("lua-ready");
  console.info(`[todo] lua-ready ${window.__todo.bootMs} ms`);
}

boot().catch((err) => {
  console.error(err);
  const el = document.getElementById("boot");
  if (el) { el.textContent = "Uygulama yüklenemedi. Sayfayı yenileyin."; el.setAttribute("role", "alert"); }
});
