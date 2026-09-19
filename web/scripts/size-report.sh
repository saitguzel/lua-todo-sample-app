#!/usr/bin/env bash
# F17 bütçe raporu (make web.size): build çıktısının sıkıştırılmış boyutlarını bütçeyle karşılaştırır.
# Brotli çıktısı varsa .br, yoksa .gz ölçülür. Aşım uyarıdır (çıkış 0); STRICT=1 ile hata (çıkış 1).
set -euo pipefail
cd "$(dirname "$0")/.."
DIST=public/dist
[ -f public/index.html ] && [ -d "$DIST" ] || { echo "HATA: önce build (./build-wasm.sh)" >&2; exit 1; }

comp() { # $1 = dosya → sıkıştırılmış bayt
  if [ -f "$1.br" ]; then stat -c %s "$1.br"; elif [ -f "$1.gz" ]; then stat -c %s "$1.gz"; else gzip -9 -c "$1" | wc -c; fi
}
kb() { awk -v b="$1" 'BEGIN { printf "%.1f KB", b / 1024 }'; }

EXT=gz; ls "$DIST"/*.br >/dev/null 2>&1 && EXT=br
fail=0
check() { # ad, bayt, bütçe_bayt
  local st="OK"
  if [ "$2" -gt "$3" ]; then st="AŞIM"; fail=1; fi
  printf "  %-34s %10s  / %-10s %s\n" "$1" "$(kb "$2")" "$(kb "$3")" "$st"
}

echo "Boyut raporu ($EXT):"
login_total=$(gzip -9 -c public/index.html | wc -c)
for f in "$DIST"/*.wasm "$DIST"/*.json "$DIST"/*.js "$DIST"/*.css; do
  [ -f "$f" ] || continue
  b=$(comp "$f")
  printf "  %-34s %10s\n" "$(basename "$f")" "$(kb "$b")"
  # login sayfası admin bundle'ını indirmez (F17 #7)
  case "$(basename "$f")" in bundle-admin.*) ;; *) login_total=$((login_total + b)) ;; esac
done
echo "Bütçeler (faz-17 §3.3):"
check "Çekirdek Lua bundle" "$(comp "$(ls "$DIST"/bundle.*.json | grep -v admin | head -1)")" $((40 * 1024))
check "Login sayfası toplam aktarım" "$login_total" $((450 * 1024))
check "app.wasm (~100 KB br hedef)" "$(comp "$(ls "$DIST"/app.*.wasm | head -1)")" $((120 * 1024))

if [ "$fail" = 1 ]; then
  echo "UYARI: bütçe aşıldı"
  [ "${STRICT:-0}" = 1 ] && exit 1
fi
exit 0
