#!/bin/bash
# MinIO: зеркалирование bucket в отдельный bucket + сверка списка и размеров -> только потом ротация.
# Root-ключи читаются здесь, из .env, и никуда больше не передаются (приложение их не видит).
set -euo pipefail
umask 077

REPO=/home/jahongir/devops-backend
STATE_DIR=/var/backups/minio
KEEP=3
SRC=uploads
DST=uploads-backup
PREFIX=$(date +%Y%m%d-%H%M%S)

envval() { grep -E "^$1=" "$REPO/.env" | cut -d= -f2-; }
export MC_HOST_app="http://$(envval MINIO_ROOT_USER):$(envval MINIO_ROOT_PASSWORD)@localhost:9000"
mc() { docker exec -e MC_CONFIG_DIR=/tmp/.mc -e MC_HOST_app minio mc "$@"; }

listing() {  # $1 = путь в mc, $2 = префикс, который надо срезать из ключей
  mc ls --recursive --json "$1" | python3 -c '
import json, sys
strip = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    if d.get("status") != "success" or d.get("type") != "file":
        continue
    k = d["key"]
    if strip and k.startswith(strip):
        k = k[len(strip):]
    print(k, d["size"])
' "$2" | sort
}

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK" "$STATE_DIR/latest.new"' EXIT
mkdir -p "$STATE_DIR"; chgrp backup-read "$STATE_DIR"; chmod 750 "$STATE_DIR"

mc mb --ignore-existing "app/$DST" > /dev/null
listing "app/$SRC" "" > "$WORK/src.txt"
mc mirror --quiet "app/$SRC" "app/$DST/$PREFIX"
listing "app/$DST/$PREFIX" "$PREFIX/" > "$WORK/dst.txt" || true

n_src=$(wc -l < "$WORK/src.txt"); sz_src=$(awk '{s+=$2} END{print s+0}' "$WORK/src.txt")
n_dst=$(wc -l < "$WORK/dst.txt"); sz_dst=$(awk '{s+=$2} END{print s+0}' "$WORK/dst.txt")
echo "Источник: $n_src объектов, $sz_src байт. Копия $PREFIX: $n_dst объектов, $sz_dst байт"

# Каждый объект из списка источника (снятого ДО копирования) должен быть в копии с тем же размером.
# Объекты, загруженные во время копирования, в копии могут быть лишними: это допустимо.
missing=$(comm -23 "$WORK/src.txt" "$WORK/dst.txt" || true)
if [[ -n "$missing" ]]; then
  echo "FAIL: в копии нет объектов или не совпадает размер:" >&2
  echo "$missing" | head -20 >&2
  exit 1
fi

# Выгрузка проверенной копии в обычные файлы ВНЕ тома MinIO: бэкап внутри той же MinIO
# пропадает вместе с её томом. Именно эту выгрузку забирает ВМ-2 по SSH.
IMAGE=$(docker inspect minio --format '{{.Config.Image}}')
NET=$(docker inspect minio --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
export MC_HOST_exp="http://$(envval MINIO_ROOT_USER):$(envval MINIO_ROOT_PASSWORD)@minio:9000"
rm -rf "$STATE_DIR/latest.new"
install -d -m 750 "$STATE_DIR/latest.new/data"
docker run --rm --network "$NET" --user 0:0 --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -e MC_HOST_exp -e MC_CONFIG_DIR=/tmp/.mc \
  -v "$STATE_DIR/latest.new/data:/export" \
  --entrypoint mc "$IMAGE" mirror --quiet "exp/$DST/$PREFIX" /export
(cd "$STATE_DIR/latest.new/data" && find . -type f -printf '%P %s\n' | sort) > "$WORK/exp.txt"
if ! diff -q "$WORK/dst.txt" "$WORK/exp.txt" > /dev/null; then
  echo "FAIL: выгрузка на диск не совпадает с копией в bucket:" >&2
  diff "$WORK/dst.txt" "$WORK/exp.txt" | head -20 >&2
  exit 1
fi
publish_latest "$STATE_DIR"
echo "Выгрузка вне тома MinIO сверена: $STATE_DIR/latest ($(wc -l < "$WORK/exp.txt") объектов)"

# Ротация: остаются KEEP последних копий (префикс с датой сортируется как строка)
old=$(mc ls --json "app/$DST/" | grep -oP '(?<="key":")[0-9]{8}-[0-9]{6}(?=/")' | sort | head -n -"$KEEP" || true)
for p in $old; do
  mc rm --recursive --force "app/$DST/$p/" > /dev/null
  echo "Удалена старая копия $p"
done
date +%s > "$STATE_DIR/.last-success"
echo "Бэкап сверен по списку и размерам: app/$DST/$PREFIX"
