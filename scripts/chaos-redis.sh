#!/bin/bash
# CHAOS №1: Redis остановлен (docker stop) на HOLD секунд, затем запущен явным docker start.
# Один запуск делает всё: опрос раз в секунду, снимки метрик и алертов Prometheus, ожидание
# обработки загруженных задач, итоговая сводка. Redis поднимается при любом выходе (trap).
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
BASE=https://app.local
ID="${FILE_ID:-b45bb0e1-8af2-47d8-99c3-e3c57989a1a3}"
PRE="${PRE:-20}"; HOLD="${HOLD:-240}"; POST="${POST:-150}"; WAIT_TASKS="${WAIT_TASKS:-240}"
OUT="${OUT:-/var/tmp/chaos1.txt}"
RUN=$(date +%s)
BE=$(docker ps --format '{{.Names}}' | grep -E '^backend-(blue|green)$' | head -1)
trap 'docker start redis > /dev/null 2>&1' EXIT
echo "chaos1-upload" > /var/tmp/chaos1-up.txt
: > "$OUT"

ev() { echo "E $(date -u +%T) $*" >> "$OUT"; }
code() { local r; r=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}/%{time_total}' "$@" 2>/dev/null) || r="fail/-"; printf '%s' "$r"; }
snap() {
  docker exec "$BE" python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/metrics').read().decode())" 2>/dev/null \
    | awk '/^(cache_hits_total|cache_misses_total|cache_errors_total|queue_stats_up|queue_waiting_tasks) /{printf "%s=%s ", $1, $2}'
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
list_status() {
  curl -sS -m 10 --cacert "$CA" "$BASE/api/files?limit=200" 2>/dev/null | python3 -c '
import json, sys, collections
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    print("list-failed"); sys.exit()
c = collections.Counter(i["status"] for i in items if i["original_name"].startswith(sys.argv[1]))
print(" ".join(k + "=" + str(v) for k, v in sorted(c.items())) or "none")' "chaos1-$RUN-"
}

c=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/api/files/$ID")
[[ "$c" == 200 ]] || { echo "файл $ID не читается (HTTP $c), задай FILE_ID=..." >&2; exit 1; }
[[ -n "$BE" ]] || { echo "активный backend не найден" >&2; exit 1; }

TOTAL=$((PRE + HOLD + POST)); STOPPED=0; STARTED=0; i=0; SECONDS=0
ev "старт RUN=$RUN backend=$BE, фазы: pre=${PRE}с down=${HOLD}с post=${POST}с"
while (( SECONDS < TOTAL )); do
  if (( SECONDS >= PRE && STOPPED == 0 )); then ev "docker stop redis"; docker stop redis > /dev/null; STOPPED=1; ev "redis остановлен"; fi
  if (( SECONDS >= PRE + HOLD && STARTED == 0 )); then ev "docker start redis"; docker start redis > /dev/null; STARTED=1; ev "redis запущен"; fi
  phase=pre; (( STOPPED )) && phase=down; (( STARTED )) && phase=post
  h=$(code "$BASE/health"); f=$(code "$BASE/api/files/$ID"); l=$(code "$BASE/api/files")
  echo "P $(date -u +%T) $phase health=$h file=$f list=$l" >> "$OUT"
  if (( i % 10 == 0 )); then
    body=$(mktemp)
    r=$(curl -sS -m 8 --cacert "$CA" -o "$body" -w '%{http_code}/%{time_total}' \
        -F "file=@/var/tmp/chaos1-up.txt;filename=chaos1-$RUN-$i.txt" "$BASE/api/files" 2>/dev/null) || r="fail/-"
    echo "U $(date -u +%T) $phase $r $(head -c 140 "$body" | tr '\n' ' ')" >> "$OUT"
    rm -f "$body"
  fi
  if (( i % 5 == 0 )); then echo "M $(date -u +%T) $phase $(snap)" >> "$OUT"; fi
  if (( i % 15 == 0 )); then echo "A $(date -u +%T) $phase $(alerts)" >> "$OUT"; fi
  i=$((i + 1)); sleep 1
done

ev "опрос закончен, жду обработки задач (до ${WAIT_TASKS} с)"
w=0
while (( w <= WAIT_TASKS )); do
  st=$(list_status); echo "S $(date -u +%T) $st" >> "$OUT"
  case "$st" in *uploaded*|*processing*|*pending*|list-failed) ;; *) break ;; esac
  sleep 10; w=$((w + 10))
done
ev "готово"

SINCE=$(date -u -d "@$RUN" +%Y-%m-%dT%H:%M:%SZ)
python3 scripts/chaos-redis-summary.py "$OUT"
echo "== логи за время опыта"
echo "backend: строк 'redis unavailable': $(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c 'redis unavailable'), трейсбеков: $(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c Traceback)"
docker logs --since "$SINCE" "$BE" 2>&1 | grep 'redis unavailable' | cut -c1-190 | sort | uniq -c | sort -rn | head -3
echo "worker: строк с error/traceback: $(docker logs --since "$SINCE" worker 2>&1 | grep -ciE 'error|traceback')"
docker logs --since "$SINCE" worker 2>&1 | grep -iE 'error|traceback' | cut -c1-190 | sort | uniq -c | sort -rn | head -3
docker inspect -f 'worker: status={{.State.Status}} перезапусков={{.RestartCount}}' worker
docker inspect -f 'redis: status={{.State.Status}}' redis
cp "$OUT" evidence/chaos1-redis-stop.txt
echo "готово"
