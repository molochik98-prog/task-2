#!/bin/bash
# Redis: снимок RDB -> проверка восстановлением в отдельном инстансе -> только потом ротация.
set -euo pipefail
umask 077

REPO=/home/jahongir/devops-backend
BACKUP_DIR=/var/backups/redis
KEEP=7
FILE="$BACKUP_DIR/redis-$(date +%Y%m%d-%H%M%S).rdb"
CHECK="redis-restore-check-$$"
IMAGE=$(docker inspect redis --format '{{.Config.Image}}')

export REDISCLI_AUTH
REDISCLI_AUTH=$(grep -E '^REDIS_PASSWORD=' "$REPO/.env" | cut -d= -f2-)
[[ -n "$REDISCLI_AUTH" ]] || { echo "FAIL: нет REDIS_PASSWORD в .env" >&2; exit 1; }

rc() { docker exec -e REDISCLI_AUTH redis redis-cli --no-auth-warning "$@" | tr -d '\r'; }
cleanup() { docker rm -f "$CHECK" > /dev/null 2>&1 || true; rm -f "$FILE.partial"; rm -rf "$BACKUP_DIR/latest.new"; }
trap cleanup EXIT

# Выдача для ВМ-2 (pull по SSH). В $1/latest.new уже лежат данные; здесь добавляются
# контрольные суммы и метка COMPLETE, группа backup-read получает чтение, каталог подменяется целиком.
publish_latest() {
  local d="$1"
  ( cd "$d/latest.new" && find . -type f ! -name SHA256SUMS ! -name COMPLETE -print0 | sort -z | xargs -r -0 sha256sum > SHA256SUMS )
  date +%s > "$d/latest.new/COMPLETE"
  chgrp -R backup-read "$d/latest.new"
  find "$d/latest.new" -type d -exec chmod 750 {} +
  find "$d/latest.new" -type f -exec chmod 640 {} +
  rm -rf "$d/latest.old"
  if [[ -d "$d/latest" ]]; then mv "$d/latest" "$d/latest.old"; fi
  mv "$d/latest.new" "$d/latest"
  rm -rf "$d/latest.old"
}

mkdir -p "$BACKUP_DIR"
chgrp backup-read "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"
chmod 600 "$BACKUP_DIR"/redis-*.rdb 2>/dev/null || true

before=$(rc LASTSAVE)
rc BGSAVE
done_ok=0
for i in $(seq 1 60); do
  info=$(rc INFO persistence)
  now=$(rc LASTSAVE)
  if [[ "$now" != "$before" ]] && grep -q '^rdb_bgsave_in_progress:0' <<< "$info"; then
    grep -q '^rdb_last_bgsave_status:ok' <<< "$info" || { echo "FAIL: BGSAVE завершился с ошибкой" >&2; exit 1; }
    done_ok=1
    break
  fi
  sleep 1
done
[[ $done_ok -eq 1 ]] || { echo "FAIL: BGSAVE не завершился за 60 с" >&2; exit 1; }

src_db=$(rc DBSIZE)
src_dead=$(rc XLEN queue:files:dead)
docker cp redis:/data/dump.rdb "$FILE.partial"
[[ -s "$FILE.partial" ]] || { echo "FAIL: пустой снимок" >&2; exit 1; }
echo "Снимок: $(stat -c %s "$FILE.partial") байт, в источнике ключей: $src_db, в мёртвой очереди: $src_dead"

# 1. Структурная проверка файла
docker run --rm --network none --entrypoint redis-check-rdb \
  -v "$FILE.partial:/check/dump.rdb:ro" "$IMAGE" /check/dump.rdb

# 2. Восстановление: отдельный инстанс на этом файле, без сети
# без --rm: контейнер удаляет cleanup; с --rm его удаляли двое сразу (в журнале dockerd: "removal ... is already in progress")
docker run -d --name "$CHECK" --network none --entrypoint redis-server \
  -v "$FILE.partial:/data/dump.rdb:ro" "$IMAGE" \
  --dir /data --dbfilename dump.rdb --appendonly no --save "" --bind 127.0.0.1 > /dev/null
up=0
for i in $(seq 1 20); do
  if docker exec "$CHECK" redis-cli ping 2>/dev/null | grep -q PONG; then up=1; break; fi
  sleep 1
done
[[ $up -eq 1 ]] || { echo "FAIL: инстанс на снимке не поднялся за 20 с" >&2; exit 1; }
res_db=$(docker exec "$CHECK" redis-cli DBSIZE | tr -d '\r')
res_dead=$(docker exec "$CHECK" redis-cli XLEN queue:files:dead | tr -d '\r')
echo "Восстановленный инстанс: ключей $res_db, в мёртвой очереди $res_dead"
if [[ "$src_db" -gt 0 && "$res_db" -eq 0 ]]; then echo "FAIL: источник не пуст, восстановленная база пуста" >&2; exit 1; fi
[[ "$res_dead" == "$src_dead" ]] || { echo "FAIL: мёртвая очередь $res_dead != $src_dead" >&2; exit 1; }

mv "$FILE.partial" "$FILE"

# Выдача для ВМ-2: свежий снимок + контрольные суммы
rm -rf "$BACKUP_DIR/latest.new"
install -d -m 750 "$BACKUP_DIR/latest.new"
cp "$FILE" "$BACKUP_DIR/latest.new/"
publish_latest "$BACKUP_DIR"
ls -1t "$BACKUP_DIR"/redis-*.rdb | tail -n +$((KEEP + 1)) | xargs -r rm --
date +%s > "$BACKUP_DIR/.last-success"
echo "Бэкап проверен восстановлением: $FILE"
