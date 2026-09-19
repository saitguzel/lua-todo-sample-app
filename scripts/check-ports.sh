#!/usr/bin/env bash
# .env içindeki *_HOST_PORT değerlerinin host'ta boş olduğunu doğrular.
# Kendi yığınımız zaten çalışıyorsa kontrolü atlar (portları biz tutuyoruz).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

if [ -n "$(docker compose ps -q --status running 2>/dev/null)" ]; then
  echo "todo-lua zaten çalışıyor, port kontrolü atlandı"; exit 0
fi

fail=0
for var in API_HOST_PORT WEB_HOST_PORT DB_HOST_PORT MAILHOG_UI_HOST_PORT; do
  port="${!var:-}"
  [ -z "$port" ] && continue
  # ss yoksa (macOS) lsof'a düş
  if command -v ss >/dev/null; then used=$(ss -ltnH "sport = :$port" 2>/dev/null | wc -l)
  else used=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l); fi
  # wc çıktısında boşluk olabilir
  used=$(echo "$used" | tr -d ' ')
  if [ "$used" -gt 0 ]; then
    owner=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E ":$port->" | cut -d' ' -f1 || true)
    echo "HATA: $var=$port dolu${owner:+ (konteyner: $owner)} → .env içinde başka bir port seçin" >&2
    fail=1
  fi
done
if [ "$fail" -eq 0 ]; then
  echo "portlar boş: API=${API_HOST_PORT:-28080} WEB=${WEB_HOST_PORT:-28000} DB=${DB_HOST_PORT:-25432} MAILHOG=${MAILHOG_UI_HOST_PORT:-28025}"
fi
exit "$fail"
