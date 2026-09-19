#!/usr/bin/env bash
# Frontend build (F12/F17): Lua kaynaklarını çekirdek + admin bundle'larına paketler, Wasmoon glue.wasm'ını
# kopyalar, glue.js'i esbuild ile bundle eder, index.html'i şablondan üretir, hash'ler ve ön sıkıştırır.
# Çıktı: public/index.html + public/dist/* (hepsi üretilir; elle düzenlenmez).
set -euo pipefail
cd "$(dirname "$0")"

MODE=${MODE:-development}
OUT=public/dist
[ -d node_modules ] || npm ci --no-audit --no-fund

rm -rf "$OUT"
mkdir -p "$OUT"

hashname() { # $1 = dosya, $2 = ad, $3 = uzantı → $OUT/<ad>.<hash8>.<uzantı>
  local h; h=$(sha256sum "$1" | cut -c1-8)
  mv "$1" "$OUT/$2.$h.$3"
  echo "$2.$h.$3"
}

# --- 1. Wasmoon glue.wasm → app.<hash>.wasm (derlemiyoruz; hazır release derlemesi) ---
WASM_SRC=node_modules/wasmoon/dist/glue.wasm
[ -f "$WASM_SRC" ] || { echo "HATA: $WASM_SRC bulunamadı (wasmoon sürümü değişmiş olabilir)" >&2; exit 1; }
cp "$WASM_SRC" "$OUT/app.wasm.tmp"
WASM=$(hashname "$OUT/app.wasm.tmp" app wasm)

# --- 2. Lua bundle'ları: admin view'ları ayrı (todouser hiç indirmez — F17 #7) ---
MIN=""; [ "$MODE" = "production" ] && MIN="--minify"
ADMIN_VIEWS="src/views/users.lua,src/views/rbac_matrix.lua,src/views/audit_logs.lua"
node scripts/bundle-lua.mjs $MIN --exclude "$ADMIN_VIEWS" src= ../shared/src=todo_shared. > "$OUT/bundle.tmp"
BUNDLE=$(hashname "$OUT/bundle.tmp" bundle json)
node scripts/bundle-lua.mjs $MIN src/views/users.lua=views.users src/views/rbac_matrix.lua=views.rbac_matrix \
  src/views/audit_logs.lua=views.audit_logs > "$OUT/bundle-admin.tmp"
ADMIN_BUNDLE=$(hashname "$OUT/bundle-admin.tmp" bundle-admin json)

# --- 3. glue.js → esbuild (wasmoon dahil; canvas-confetti ayrı chunk, dinamik import) ---
npx --no-install esbuild js/glue.js --bundle --format=esm --target=es2020 --platform=browser --splitting \
  --outdir="$OUT" --entry-names="glue.[hash]" --chunk-names="chunk.[hash]" \
  --external:fs --external:path --external:module --external:url --external:child_process \
  --define:BUNDLE_PATH="'./$BUNDLE'" --define:ADMIN_BUNDLE_PATH="'./$ADMIN_BUNDLE'" --define:WASM_PATH="'./$WASM'" \
  $( [ "$MODE" = "production" ] && echo "--minify" ) --log-level=warning
GLUE=$(cd "$OUT" && ls glue.*.js)

# --- 4. Statik dosyalar (hash'li → immutable cache) ---
cp static/boot.js "$OUT/boot.tmp";     BOOT=$(hashname "$OUT/boot.tmp" boot js)
cp static/styles.css "$OUT/styles.tmp"; STYLES=$(hashname "$OUT/styles.tmp" styles css)

# --- 5. Tailwind: dev → Play CDN; prod → CLI ile derlenmiş CSS (F12 kararı #12) ---
if [ "$MODE" = "production" ]; then
  npx --no-install tailwindcss -c tailwind.config.cjs -i static/tailwind.input.css -o "$OUT/tw.tmp" --minify 2>/dev/null
  TW=$(hashname "$OUT/tw.tmp" tailwind css)
  TAILWIND="<link rel=\"stylesheet\" href=\"./dist/$TW\">"
  CSP_SCRIPT=""
  CSP_CONNECT=""
else
  cp static/tailwind.config.js "$OUT/twc.tmp"; TWC=$(hashname "$OUT/twc.tmp" tailwind.config js)
  TAILWIND="<script src=\"https://cdn.tailwindcss.com\"></script><script src=\"./dist/$TWC\"></script>"
  CSP_SCRIPT="https://cdn.tailwindcss.com"
  CSP_CONNECT="http://localhost:28080"
fi

# --- 6. index.html: şablondan üretilir (kaynak dosya değişmez) ---
node -e '
  const fs = require("fs");
  const [tpl, out, ...pairs] = process.argv.slice(1);
  let s = fs.readFileSync(tpl, "utf8");
  for (const p of pairs) { const i = p.indexOf("="); s = s.split(`__${p.slice(0, i)}__`).join(p.slice(i + 1)); }
  const left = s.match(/__[A-Z_]+__/);
  if (left) { console.error("HATA: doldurulmamış yer tutucu: " + left[0]); process.exit(1); }
  fs.writeFileSync(out, s);
' index.html public/index.html \
  "WASM=dist/$WASM" "BUNDLE=dist/$BUNDLE" "GLUE=dist/$GLUE" "BOOT=dist/$BOOT" "STYLES=dist/$STYLES" \
  "TAILWIND=$TAILWIND" "CSP_SCRIPT_EXTRA=$CSP_SCRIPT" "CSP_CONNECT_EXTRA=$CSP_CONNECT"

# --- 7. Ön sıkıştırma (F17 #4): nginx gzip_static / brotli_static ---
for f in "$OUT"/*.wasm "$OUT"/*.json "$OUT"/*.js "$OUT"/*.css; do
  [ -f "$f" ] || continue
  gzip -9 -kf "$f"
  if command -v brotli >/dev/null 2>&1; then brotli -q 11 -kf "$f"; fi
done

echo "build tamam (MODE=$MODE): public/index.html + $OUT"
ls -l "$OUT" | awk 'NR>1 {printf "  %8d  %s\n", $5, $9}'
