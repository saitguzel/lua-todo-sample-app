#!/usr/bin/env bash
# Token al, 4 senaryoyu koştur, sonuçları tarihli dizine yaz (F11 §7)
set -euo pipefail
cd "$(dirname "$0")/../.."
for bin in wrk jq curl; do command -v "$bin" >/dev/null || { echo "HATA: $bin kurulu değil" >&2; exit 1; }; done
BASE=${BASE:-http://localhost:28080}
OUT=api/bench/results/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$OUT"
echo "Bench base: $BASE out: $OUT"
TOKEN=$(curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"user@todoapp.local","password":"User123!"}' | jq -r '.data.access_token // empty')
[ -n "$TOKEN" ] || { echo "HATA: token alınamadı" >&2; exit 1; }
export TOKEN
wrk -t4 -c50  -d30s --latency -s api/bench/login.lua       "$BASE" | tee "$OUT/login.txt"
wrk -t4 -c100 -d30s --latency -s api/bench/todos_list.lua  "$BASE" | tee "$OUT/todos_list.txt"
wrk -t4 -c100 -d60s --latency -s api/bench/todos_mixed.lua "$BASE" | tee "$OUT/todos_mixed.txt"
wrk -t2 -c50  -d15s --latency "$BASE/api/v1/health"                | tee "$OUT/health.txt"
# Hata oranı %0 olmalı: 2xx dışı status ve socket hatası varsa başarısız
if grep -E "^status [^2][0-9]{2}:|Non-2xx|Socket errors" "$OUT"/*.txt; then
  echo "HATA: 2xx dışı yanıt veya socket hatası var" >&2; exit 1
fi
echo "Sonuçlar $OUT altında"
