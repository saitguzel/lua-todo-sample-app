// boot.js — WASM yüklenmeden önce çalışır: temayı uygular (FOUC önleme) ve API yapılandırmasını koyar.
// CSP'de hash bakımı gerektirmemesi için inline değil ayrı dosya (F12 kararı).
try {
  const t = localStorage.getItem("todo.theme");
  const pref = t ? t.replace(/"/g, "") : null;
  document.documentElement.dataset.theme = pref && pref !== "system"
    ? pref
    : (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
} catch { /* localStorage engelli */ }

// API her zaman aynı origin'den (/api/v1): dev'de web nginx, prod'da proxy api'ye aktarır.
// Böylece uygulama localhost, IP veya domain ile açılsa da çalışır; CORS gerekmez.
window.__TODO_CONFIG__ = { apiBase: `${location.origin}/api/v1` };
