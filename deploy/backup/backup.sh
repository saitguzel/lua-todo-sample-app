#!/bin/sh
# Günlük PostgreSQL yedeği: custom format dump + doğrulama + (opsiyonel) age şifreleme + rotasyon (F18).
# Kullanım: backup.sh [daily|pre-deploy]
# Saklama: günlük 7, haftalık 4 (pazar), aylık 6 (ayın 1'i), pre-deploy 5.
# BACKUP_AGE_RECIPIENT set ise dump age ile şifrelenir (.dump.age), düz dump silinir.
set -eu

TAG=${1:-daily}
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT=/backups/$TAG/todo-$TS.dump
mkdir -p "/backups/$TAG"

PGPASSWORD=$(cat /run/secrets/db_password 2>/dev/null || echo "${PGPASSWORD:-}")
export PGPASSWORD
pg_dump -h "${PGHOST:-postgres}" -U "${PGUSER:-todo}" -d "${PGDATABASE:-todo}" -Fc -Z 6 -f "$OUT"

# dump okunabilir mi (bozuk dosya tespiti)
pg_restore -l "$OUT" > /dev/null

if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  command -v age >/dev/null || { echo "HATA: age yok (deploy/backup/Dockerfile imajını kullanın)" >&2; exit 1; }
  age -r "$BACKUP_AGE_RECIPIENT" -o "$OUT.age" "$OUT"
  rm -f "$OUT"
  OUT=$OUT.age
fi

# keep <dizin> <adet>: en yeni N dosya kalır
keep() {
  ls -1t "$1"/todo-* 2>/dev/null | tail -n +$(($2 + 1)) | xargs -r rm -f
}

if [ "$TAG" = "daily" ]; then
  if [ "$(date -u +%u)" = "7" ]; then mkdir -p /backups/weekly && cp "$OUT" /backups/weekly/; fi
  if [ "$(date -u +%d)" = "01" ]; then mkdir -p /backups/monthly && cp "$OUT" /backups/monthly/; fi
  keep /backups/daily 7
  keep /backups/weekly 4
  keep /backups/monthly 6
else
  keep "/backups/$TAG" 5
fi

echo "{\"job\":\"backup\",\"file\":\"$OUT\",\"status\":\"success\",\"ts\":\"$TS\"}"
