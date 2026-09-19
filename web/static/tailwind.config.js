// Tailwind Play CDN yapılandırması (yalnızca geliştirme). Inline <script> CSP'ye takılacağı için ayrı dosya.
// Prod'da aynı ayarlar tailwind.config.cjs ile CLI derlemesinde kullanılır (F18).
tailwind.config = { darkMode: ["selector", '[data-theme="dark"]'] };
