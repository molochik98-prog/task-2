#!/bin/bash
# wrk по одной ручке (GET /api/files/{id}) в четырёх режимах: пул Postgres x кеш Redis.
# Режимы переключаются файлами-флагами в томе backend-tmp, без перезапуска.
set -uo pipefail
cd /home/jahongir/devops-backend
command -v wrk > /dev/null || { echo "wrk не установлен: sudo apt install -y wrk"; exit 1; }
CA=/home/jahongir/certs/ca.crt
COLOR=$(grep -oP '(?<=backend-)[a-z]+(?=:8000)' nginx/nginx.conf | head -1)
BE="backend-$COLOR"
DUR="${DUR:-20s}"; CONN="${CONN:-50}"

flag() { if [[ "$2" == on ]]; then docker exec "$BE" touch "/var/uploads-tmp/$1"; else docker exec "$BE" rm -f "/var/uploads-tmp/$1"; fi; }
trap 'flag NO_POOL off; flag NO_CACHE off' EXIT

echo "bench-file" > /var/tmp/bench.txt
ID=$(curl -sS --cacert "$CA" -H "Idempotency-Key: bench-file-1" -F file=@/var/tmp/bench.txt https://app.local/api/files | grep -oP '(?<="id":")[^"]+')
[[ -n "$ID" ]] || { echo "не удалось получить id тестового файла"; exit 1; }
URL="https://app.local/api/files/$ID"
echo "ручка: GET $URL, wrk -t2 -c$CONN -d$DUR, активный backend: $BE, wrk запущен на той же VM-1"

run() {
  [[ "${ONLY_CACHE:-}" == 1 && "$3" == on ]] && return 0  # ONLY_CACHE=1: только строки с кешем
  flag NO_POOL "$2"; flag NO_CACHE "$3"
  wrk -t2 -c"$CONN" -d5s "$URL" > /dev/null 2>&1   # прогрев
  echo "$1 | $(wrk -t2 -c"$CONN" -d"$DUR" -s scripts/wrk-percentiles.lua "$URL" 2>&1 | grep -oP '(?<=RESULT ).*')"
}
run "без пула / без кеша" on  on
run "без пула / с кешем " on  off
run "с пулом / без кеша " off on
run "с пулом / с кешем  " off off
