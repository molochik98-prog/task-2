#!/usr/bin/env bash
# Измеряет память backend при загрузке файла заданного размера через nginx.
# Использование: scripts/upload-mem-test.sh <размер_в_МиБ>
# Нужен алиас "app" в mc внутри контейнера minio.
set -euo pipefail

SIZE_MB=${1:?использование: $0 <размер_в_МиБ>}
CA=/home/jahongir/certs/ca.crt
URL=https://app.local/api/files
B=$(docker ps --format '{{.Names}}' | grep '^backend-' | head -1)
FILE=/tmp/upload-test-${SIZE_MB}mb.bin
SAMPLES=/tmp/mem-samples-${SIZE_MB}mb.txt
MC="docker exec -i -e MC_CONFIG_DIR=/tmp/.mc minio mc"

$MC ls app/uploads/ > /dev/null || { echo "алиас app в mc не создан"; exit 1; }

sample() {
  docker exec "$B" sh -c "grep -E '^(anon|file) ' /sys/fs/cgroup/memory.stat" | tr '\n' ' '
}

echo "backend: $B, файл: ${SIZE_MB} МиБ"
dd if=/dev/urandom of="$FILE" bs=1M count="$SIZE_MB" status=none
echo "до загрузки: $(sample)"

: > "$SAMPLES"
( while true; do echo "$(date +%T) $(sample)" >> "$SAMPLES"; sleep 0.2; done ) &
SAMPLER=$!
trap 'kill "$SAMPLER" 2>/dev/null || true' EXIT

START=$(date +%s)
RESP=$(curl -s -m 900 --cacert "$CA" --resolve app.local:443:127.0.0.1 \
  -F "file=@$FILE" -w ' HTTP %{http_code}' "$URL") || RESP="curl завершился с ошибкой"
END=$(date +%s)

kill "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true

echo "ответ: $RESP (за $((END-START)) с)"
echo "после загрузки: $(sample)"
echo "замеров: $(wc -l < "$SAMPLES")"
PEAK_ANON=$(awk '{for(i=1;i<=NF;i++) if($i=="anon") print $(i+1)}' "$SAMPLES" | sort -n | tail -1)
PEAK_FILE=$(awk '{for(i=1;i<=NF;i++) if($i=="file") print $(i+1)}' "$SAMPLES" | sort -n | tail -1)
echo "ПИК anon: $((PEAK_ANON/1048576)) МиБ, пик file (кеш): $((PEAK_FILE/1048576)) МиБ"
docker inspect -f 'OOMKilled={{.State.OOMKilled}} restarts={{.RestartCount}}' "$B"
echo "временные файлы в томе: $(docker exec "$B" sh -c 'ls /var/uploads-tmp | wc -l') шт."

ID=$(echo "$RESP" | grep -oP '(?<="id":")[^"]+' || true)
if [ -n "$ID" ]; then
  A=$(sha256sum "$FILE" | cut -d' ' -f1)
  H=$($MC cat "app/uploads/files/$ID" | sha256sum | cut -d' ' -f1)
  if [ "$A" = "$H" ]; then echo "sha256: СОВПАДАЕТ ($ID)"; else echo "sha256: НЕ СОВПАДАЕТ ($ID)"; fi
fi
rm -f "$FILE"
