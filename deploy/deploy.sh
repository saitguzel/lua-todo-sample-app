#!/bin/sh
# Sunucu deploy akışı (F18 §5.2). Kullanım (repo kökünde): TAG=v0.2.0 sh deploy/deploy.sh
# Hata olursa: TAG=<önceki> sh deploy/deploy.sh --rollback   (migration geri alınmaz — expand/contract)
set -eu

: "${TAG:?TAG gerekli}"
export TAG
C="docker compose --env-file .env.prod -f docker-compose.prod.yml"
DOMAIN_URL=${DOMAIN_URL:-$(grep -E '^APP_BASE_URL=' .env.prod | cut -d= -f2-)}

if [ "${1:-}" = "--rollback" ]; then
  $C up -d --no-build --wait api web
  echo "rollback tamam: $TAG"; exit 0
fi

echo "==> 1/6 imajlar ($TAG)";   $C pull api web
echo "==> 2/6 yedek";            $C exec -T backup sh /scripts/backup.sh pre-deploy
echo "==> 3/6 migration";        $C run --rm --no-deps api resty -I /app/src -I /app/lib /app/src/db/migrations.lua up
echo "==> 4/6 api";              $C up -d --no-build --wait api
echo "==> 5/6 web + proxy";      $C up -d --no-build --wait web proxy
echo "==> 6/6 duman testi"
curl -fsS "$DOMAIN_URL/api/v1/health/ready" >/dev/null
echo "deploy tamam: $TAG"
