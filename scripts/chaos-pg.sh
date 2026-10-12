#!/bin/bash
# CHAOS №3: раз в секунду опрашивает API, пока Postgres на VM-2 остановлен вручную.
# Колонки: health (readiness), file (метаданные одного файла: через кеш Redis),
# list (список, всегда в Postgres), upload (раз в 10 с), docker (статус healthcheck).
# Формат значения: HTTP-код/время_в_секундах; fail = нет ответа за 5 с.
set -uo pipefail
CA=/home/jahongir/certs/ca.crt
BASE=https://app.local
DUR="${DUR:-600}"
OUT="${OUT:-/var/tmp/chaos3.txt}"
BODIES="${BODIES:-/var/tmp/chaos3-bodies.txt}"
ID="${FILE_ID:-b45bb0e1-8af2-47d8-99c3-e3c57989a1a3}"
BE=$(docker ps --format '{{.Names}}' | grep -E '^backend-(blue|green)$' | head -1)
RUN=$(date +%s)
echo "chaos3-upload" > /var/tmp/chaos3-up.txt
: > "$OUT"; : > "$BODIES"

# Печатает код/время; тело не-2xx ответа дописывает в $BODIES (что увидел клиент)
req() {
  local name=$1 tmp r; shift
  tmp=$(mktemp)
  r=$(curl -sS -m 5 --cacert "$CA" -o "$tmp" -w '%{http_code}/%{time_total}' "$@" 2>/dev/null) || r="fail/-"
  if [[ "${r%%/*}" != 2* ]]; then
    printf '%s %s %s %s\n' "$(date -u +%T)" "$name" "$r" "$(head -c 160 "$tmp" | tr '\n' ' ')" >> "$BODIES"
  fi
  rm -f "$tmp"
  printf '%s' "$r"
}

c=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/api/files/$ID")
[[ "$c" == 200 ]] || { echo "файл $ID не читается (HTTP $c), задай FILE_ID=..." >&2; exit 1; }

for ((i = 0; i < DUR; i++)); do
  t=$(date -u +%T)
  h=$(req health "$BASE/health")
  f=$(req file "$BASE/api/files/$ID")
  l=$(req list "$BASE/api/files")
  u=-
  if (( i % 10 == 0 )); then
    u=$(req upload -F file=@/var/tmp/chaos3-up.txt -H "Idempotency-Key: chaos3-$RUN-$i" "$BASE/api/files")
  fi
  d=$(docker inspect -f '{{.State.Health.Status}}' "$BE" 2>/dev/null || echo gone)
  echo "$t health=$h file=$f list=$l upload=$u docker=$d" >> "$OUT"
  sleep 1
done
echo "готово" >> "$OUT"
