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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

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

# Ротация: остаются KEEP последних копий (префикс с датой сортируется как строка)
old=$(mc ls --json "app/$DST/" | grep -oP '(?<="key":")[0-9]{8}-[0-9]{6}(?=/")' | sort | head -n -"$KEEP" || true)
for p in $old; do
  mc rm --recursive --force "app/$DST/$p/" > /dev/null
  echo "Удалена старая копия $p"
done
date +%s > "$STATE_DIR/.last-success"
echo "Бэкап сверен по списку и размерам: app/$DST/$PREFIX"
