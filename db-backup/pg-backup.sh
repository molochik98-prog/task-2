#!/bin/bash
# Postgres: логический дамп -> восстановление в отдельную БД + сверка данных -> только потом ротация.
# Запускается от postgres через pg-backup.service. Любой сбой = ненулевой код = OnFailure-алерт.
set -euo pipefail
umask 077

SOCKET_DIR="/var/run/postgresql"
DB_NAME="appdb"
CHECK_DB="appdb_restore_check"
BACKUP_DIR="/var/backups/postgresql-appdb"
KEEP=7
FILE="${BACKUP_DIR}/appdb-$(date +%Y%m%d-%H%M%S).dump"

pq() { psql -h "$SOCKET_DIR" -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
trap 'rm -f "$FILE.partial"' EXIT

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
chmod 600 "$BACKUP_DIR"/appdb-*.dump 2>/dev/null || true

TABLES=$(pq -d "$DB_NAME" -c "select tablename from pg_tables where schemaname='public' order by 1")
[[ -n "$TABLES" ]] || { echo "FAIL: в $DB_NAME нет таблиц" >&2; exit 1; }
declare -A BEFORE AFTER
for t in $TABLES; do BEFORE[$t]=$(pq -d "$DB_NAME" -c "select count(*) from public.\"$t\""); done

pg_dump -h "$SOCKET_DIR" -U postgres -Fc "$DB_NAME" > "$FILE.partial"
[[ -s "$FILE.partial" ]] || { echo "FAIL: пустой дамп" >&2; exit 1; }
mv "$FILE.partial" "$FILE"
chmod 600 "$FILE"
echo "Дамп создан: $FILE ($(stat -c %s "$FILE") байт)"

for t in $TABLES; do AFTER[$t]=$(pq -d "$DB_NAME" -c "select count(*) from public.\"$t\""); done

dropdb -h "$SOCKET_DIR" -U postgres --if-exists "$CHECK_DB"
createdb -h "$SOCKET_DIR" -U postgres "$CHECK_DB"
if ! pg_restore -h "$SOCKET_DIR" -U postgres -d "$CHECK_DB" --exit-on-error "$FILE"; then
  echo "FAIL: pg_restore не отработал; дамп переименован в .failed, БД $CHECK_DB оставлена для разбора" >&2
  mv "$FILE" "$FILE.failed"
  exit 1
fi

# Данные в копии должны совпасть с источником. Источник мог измениться во время дампа,
# поэтому допускается диапазон между счётом до дампа и после.
for t in $TABLES; do
  got=$(pq -d "$CHECK_DB" -c "select count(*) from public.\"$t\"")
  lo=${BEFORE[$t]}; hi=${AFTER[$t]}
  if (( lo > hi )); then tmp=$lo; lo=$hi; hi=$tmp; fi
  if (( got < lo || got > hi )); then
    echo "FAIL: таблица $t: в копии $got строк, в источнике $lo..$hi" >&2
    mv "$FILE" "$FILE.failed"
    exit 1
  fi
  echo "OK: $t = $got строк (источник $lo..$hi)"
done
dropdb -h "$SOCKET_DIR" -U postgres "$CHECK_DB"

# Ротация только после успешной проверки восстановления
ls -1t "$BACKUP_DIR"/appdb-*.dump | tail -n +$((KEEP + 1)) | xargs -r rm --
date +%s > "$BACKUP_DIR/.last-success"
echo "Бэкап проверен восстановлением: $FILE"
