#!/bin/bash
set -euo pipefail

SOCKET_DIR="/var/run/postgresql"
DB_NAME="appdb"
BACKUP_DIR="/var/backups/postgresql-appdb"
KEEP=7
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/appdb-${TIMESTAMP}.dump"

mkdir -p "$BACKUP_DIR"

pg_dump -h "$SOCKET_DIR" -U postgres -Fc "$DB_NAME" > "$BACKUP_FILE"
echo "Backup created: $BACKUP_FILE"

ls -1t "${BACKUP_DIR}"/appdb-*.dump | tail -n +$((KEEP + 1)) | xargs -r rm --

RESTORE_DB="appdb_restore_check"
dropdb -h "$SOCKET_DIR" -U postgres --if-exist "$RESTORE_DB"
createdb -h "$SOCKET_DIR" -U postgres "$RESTORE_DB"

if pg_restore -h "$SOCKET_DIR" -U postgres -d "$RESTORE_DB" "$BACKUP_FILE"; then
  echo "Restore verification: OK"
  dropdb -h "$SOCKET_DIR" -U postgres "$RESTORE_DB"
else
  echo "Restore verification: FAILED - damp leave, scratch-DB NOT DELETE for invastigation" >&2
  exit 1
fi
