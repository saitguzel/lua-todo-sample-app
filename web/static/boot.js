// boot.js — WASM yüklenmeden önce çalışır: temayı uygular (FOUC önleme) ve API yapılandırmasını koyar.
// CSP'de hash bakımı gerektirmemesi için inline değil ayrı dosya (F12 kararı).
try {
  const t = localStorage.getItem("todo.theme");
  const pref = t ? t.replace(/"/g, "") : null;
  document.documentElement.dataset.theme = pref && pref !== "system"
    ? pref
    : (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
} catch { /* localStorage engelli */ }

// Prod'da build aynı origin'i kullanır (/api/v1); dev'de API portu ayrıdır.
window.__TODO_CONFIG__ = { apiBase: location.port === "28000" || location.hostname === "localhost"
  ? "http://localhost:28080/api/v1"
  : `${location.origin}/api/v1` };
