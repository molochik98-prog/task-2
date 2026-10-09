#!/bin/bash
# Цена проверки соединения при выдаче из пула (SELECT 1): пул включён, кеш выключен (каждый запрос идёт в Postgres).
# Режимы чередуются по кругам (с проверкой / без неё), чтобы дрейф VM не достался одному из них.
set -uo pipefail
cd /home/jahongir/devops-backend
command -v wrk > /dev/null || { echo "wrk не установлен: sudo apt install -y wrk"; exit 1; }
CA=/home/jahongir/certs/ca.crt
COLOR=$(grep -oP '(?<=backend-)[a-z]+(?=:8000)' nginx/nginx.conf | head -1)
BE="backend-$COLOR"
DUR="${DUR:-15s}"; CONN="${CONN:-50}"; ROUNDS="${ROUNDS:-3}"

flag() { if [[ "$2" == on ]]; then docker exec "$BE" touch "/var/uploads-tmp/$1"; else docker exec "$BE" rm -f "/var/uploads-tmp/$1"; fi; }
trap 'flag NO_PREPING off; flag NO_CACHE off; flag NO_POOL off' EXIT

echo "bench-file" > /var/tmp/bench.txt
ID=$(curl -sS --cacert "$CA" -H "Idempotency-Key: bench-file-1" -F file=@/var/tmp/bench.txt https://app.local/api/files | grep -oP '(?<="id":")[^"]+')
[[ -n "$ID" ]] || { echo "не удалось получить id тестового файла"; exit 1; }
URL="https://app.local/api/files/$ID"
echo "ручка: GET $URL, wrk -t2 -c$CONN -d$DUR, backend: $BE, пул включён, кеш выключен, wrk на той же VM-1"

flag NO_POOL off; flag NO_CACHE on
run() {  # $1 = on|off (флаг NO_PREPING: on = проверка выключена), $2 = круг, $3 = подпись
  flag NO_PREPING "$1"
  wrk -t2 -c"$CONN" -d5s "$URL" > /dev/null 2>&1
  echo "круг $2 | проверка $3 | $(wrk -t2 -c"$CONN" -d"$DUR" -s scripts/wrk-percentiles.lua "$URL" 2>&1 | grep -oP '(?<=RESULT ).*')"
}
for r in $(seq 1 "$ROUNDS"); do
  if (( r % 2 )); then run off "$r" "включена"; run on "$r" "выключена"; else run on "$r" "выключена"; run off "$r" "включена"; fi
done
