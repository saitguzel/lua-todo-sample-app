#!/bin/sh
# Yedekten geri yükleme + doğrulama (F18). Kullanım: restore.sh /backups/daily/todo-....dump[.age]
# DİKKAT: hedef veritabanındaki mevcut veriyi --clean --if-exists ile ezer.
# .age dosyası için BACKUP_AGE_IDENTITY (age özel anahtar dosyası) gerekir.
set -eu

DUMP=${1:?kullanım: restore.sh /backups/<tag>/<dosya>.dump}
[ -f "$DUMP" ] || { echo "HATA: dump bulunamadı: $DUMP" >&2; exit 1; }

PGHOST=${PGHOST:-postgres}
PGUSER=${PGUSER:-todo}
PGDATABASE=${PGDATABASE:-todo}
PGPASSWORD=$(cat /run/secrets/db_password 2>/dev/null || echo "${PGPASSWORD:-}")
export PGHOST PGUSER PGDATABASE PGPASSWORD

case "$DUMP" in
  *.age)
    command -v age >/dev/null || { echo "HATA: age yok (deploy/backup/Dockerfile imajını kullanın)" >&2; exit 1; }
    PLAIN=/tmp/restore-$$.dump
    age -d -i "${BACKUP_AGE_IDENTITY:?BACKUP_AGE_IDENTITY gerekli}" -o "$PLAIN" "$DUMP"
    trap 'rm -f "$PLAIN"' EXIT
    DUMP=$PLAIN
    ;;
esac

START=$(date +%s)
echo "==> geri yükleniyor: $DUMP"
pg_restore --clean --if-exists --no-owner -d "$PGDATABASE" "$DUMP"

echo "==> doğrulama"
q() { psql -tA -c "$1"; }
echo "users:    $(q 'SELECT count(*) FROM users;')"
echo "todos:    $(q 'SELECT count(*) FROM todos;')"
echo "audit:    $(q 'SELECT max(created_at) FROM audit_logs;')"
echo "migrate:  $(q 'SELECT version FROM schema_migrations ORDER BY 1 DESC LIMIT 1;')"
echo "restore tamam ($(($(date +%s) - START)) sn)"
