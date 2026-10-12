#!/bin/bash
# CHAOS №6: исчерпание пула соединений Postgres (5 на backend). На VM-2 отдельной командой держится
# ACCESS EXCLUSIVE на таблице files: запросы к ней висят до statement_timeout (8 с).
# Здесь: 2 запроса списка в секунду БЕЗ ожидания ответа (иначе пул не исчерпать), пробы health,
# метаданных и загрузки. Точный момент блокировки не нужен: границы окна берутся из данных.
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
BASE=https://app.local
ID="${FILE_ID:-b45bb0e1-8af2-47d8-99c3-e3c57989a1a3}"
DUR="${DUR:-330}"
OUT="${OUT:-/var/tmp/chaos6.txt}"
RUN=$(date +%s)
BE=$(docker ps --format '{{.Names}}' | grep -E '^backend-(blue|green)$' | head -1)
echo "chaos6-upload" > /var/tmp/chaos6-up.txt
: > "$OUT"

code() { local r; r=$(curl -sS -m 15 --cacert "$CA" -o /dev/null -w '%{http_code}/%{time_total}' "$@" 2>/dev/null) || r="fail/-"; printf '%s' "$r"; }
fire() {
  local s tmp r ra; s=$(date -u +%T); tmp=$(mktemp)
  r=$(curl -sS -m 20 --cacert "$CA" -D "$tmp.h" -o "$tmp" -w '%{http_code}/%{time_total}' "$BASE/api/files" 2>/dev/null) || r="fail/-"
  ra=$(grep -i '^retry-after' "$tmp.h" 2>/dev/null | tr -d '\r' | cut -d' ' -f2)
  echo "L $s $r ra=${ra:--} $(head -c 90 "$tmp" | tr '\n' ' ')" >> "$OUT"
  rm -f "$tmp" "$tmp.h"
}
probe() { local s; s=$(date -u +%T); echo "H $s health=$(code "$BASE/health") file=$(code "$BASE/api/files/$ID")" >> "$OUT"; }
upload() {
  local s tmp r; s=$(date -u +%T); tmp=$(mktemp)
  r=$(curl -sS -m 20 --cacert "$CA" -o "$tmp" -w '%{http_code}/%{time_total}' \
      -F "file=@/var/tmp/chaos6-up.txt;filename=chaos6-$RUN-$1.txt" "$BASE/api/files" 2>/dev/null) || r="fail/-"
  echo "U $s $r $(head -c 100 "$tmp" | tr '\n' ' ')" >> "$OUT"; rm -f "$tmp"
}
snap() {
  docker exec "$BE" python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/metrics').read().decode())" 2>/dev/null \
    | awk '/^(db_pool_in_use|db_pool_timeouts_total|db_pool_size) /{printf "%s=%s ", $1, $2}'
}
alerts() {
  docker exec monitoring-stack-prometheus-1 wget -qO- http://localhost:9090/api/v1/alerts 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["data"]["alerts"]
    print(" ".join(a["labels"]["alertname"] + "=" + a["state"] for a in d) or "none")
except Exception:
    print("prometheus-unavailable")'
}

c=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/api/files/$ID")
[[ "$c" == 200 ]] || { echo "файл $ID не читается (HTTP $c), задай FILE_ID=..." >&2; exit 1; }
[[ -n "$BE" ]] || { echo "активный backend не найден" >&2; exit 1; }

END=$(( $(date +%s) + DUR )); i=0
echo "E $(date -u +%T) старт RUN=$RUN backend=$BE, длительность ${DUR} с; запусти блокировку на VM-2 (30-120 с после старта)" >> "$OUT"
while (( $(date +%s) < END )); do
  fire &
  (( i % 2 == 0 )) && probe &
  (( i % 20 == 0 )) && upload "$i" &
  (( i % 10 == 0 )) && echo "M $(date -u +%T) $(snap)" >> "$OUT"
  (( i % 30 == 0 )) && echo "A $(date -u +%T) $(alerts)" >> "$OUT"
  i=$((i + 1)); sleep 0.5
done
echo "E $(date -u +%T) опрос закончен, жду незавершённых запросов (до 20 с)" >> "$OUT"
wait
echo "E $(date -u +%T) готово" >> "$OUT"

SINCE=$(date -u -d "@$RUN" +%Y-%m-%dT%H:%M:%SZ)
python3 scripts/chaos-pool-summary.py "$OUT"
echo "== логи за опыт"
echo "backend: Traceback $(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c Traceback), healthcheck: $(docker inspect -f '{{.State.Health.Status}}' "$BE")"
echo "worker: 'sweeper failed' $(docker logs --since "$SINCE" worker 2>&1 | grep -c 'sweeper failed'), перезапусков $(docker inspect -f '{{.RestartCount}}' worker)"
cp "$OUT" evidence/chaos6-pool-exhaustion.txt
echo "готово"
