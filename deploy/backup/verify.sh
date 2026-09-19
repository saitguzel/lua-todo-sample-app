#!/bin/sh
# Geri yükleme tatbikatı (F18 §7): en son yedeği geçici bir postgres container'ına restore eder,
# doğrulama sorgularını koşar ve süreyi ölçer. Prod DB'ye DOKUNMAZ.
# Kullanım (repo kökünden): sh deploy/backup/verify.sh   [BACKUP_VOLUME=todo-prod_backups]
# Şifreli yedek: BACKUP_AGE_IDENTITY=/yol/age.key BACKUP_IMAGE=todo-backup:<TAG>
set -eu

NAME=todo-restore-drill-$$
VOL=${BACKUP_VOLUME:-todo-prod_backups}
docker volume inspect "$VOL" >/dev/null 2>&1 || { echo "HATA: volume yok: $VOL" >&2; exit 1; }

LATEST=$(docker run --rm -v "$VOL":/backups:ro alpine sh -c \
  'ls -1t /backups/daily/todo-* /backups/pre-deploy/todo-* 2>/dev/null | head -n1')
[ -n "$LATEST" ] || { echo "HATA: yedek yok" >&2; exit 1; }
echo "==> tatbikat: $LATEST"

trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=drill -e POSTGRES_USER=todo -e POSTGRES_DB=todo \
  -v "$VOL":/backups:ro -v "$(pwd)/deploy/backup":/scripts:ro ${BACKUP_AGE_IDENTITY:+-v "$BACKUP_AGE_IDENTITY":/age.key:ro} \
  "${BACKUP_IMAGE:-postgres:16-alpine}" >/dev/null
i=0; until docker exec "$NAME" pg_isready -U todo -d todo >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -lt 60 ] || { echo "HATA: postgres açılmadı" >&2; exit 1; }; sleep 1
done
sleep 2  # initdb sonrası yeniden başlatma
docker exec -e PGHOST=127.0.0.1 -e PGPASSWORD=drill ${BACKUP_AGE_IDENTITY:+-e BACKUP_AGE_IDENTITY=/age.key} \
  "$NAME" sh /scripts/restore.sh "$LATEST"
