#!/bin/bash
# CHAOS №2: MinIO остановлен (docker stop) на HOLD секунд, затем docker start.
# Один запуск: опрос раз в секунду (+ ссылка и скачивание, /health/deps раз в 5 с), метрики и алерты,
# повтор загрузки с Idempotency-Key после failed. MinIO поднимается при любом выходе (trap).
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
BASE=https://app.local
ID="${FILE_ID:-b45bb0e1-8af2-47d8-99c3-e3c57989a1a3}"
PRE="${PRE:-20}"; HOLD="${HOLD:-150}"; POST="${POST:-100}"
OUT="${OUT:-/var/tmp/chaos2.txt}"
RUN=$(date +%s); KEY="chaos2-$RUN-k1"
BE=$(docker ps --format '{{.Names}}' | grep -E '^backend-(blue|green)$' | head -1)
trap 'docker start minio > /dev/null 2>&1' EXIT
echo "chaos2-upload" > /var/tmp/chaos2-up.txt
: > "$OUT"

ev() { echo "E $(date -u +%T) $*" >> "$OUT"; }
code() { local r; r=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}/%{time_total}' "$@" 2>/dev/null) || r="fail/-"; printf '%s' "$r"; }
jfield() { python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get(sys.argv[1], "?"))
except Exception:
    print("?")' "$1"; }
snap() {
  docker exec "$BE" python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/metrics').read().decode())" 2>/dev/null \
    | awk '/^(queue_stats_up|bucket_objects|bucket_bytes|cache_errors_total) /{printf "%s=%s ", $1, $2}'
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
idem_upload() {  # $1 = метка шага
  local body r
  body=$(mktemp)
  r=$(curl -sS -m 10 --cacert "$CA" -o "$body" -w '%{http_code}/%{time_total}' -H "Idempotency-Key: $KEY" \
      -F "file=@/var/tmp/chaos2-up.txt;filename=chaos2-$RUN-idem.txt" "$BASE/api/files" 2>/dev/null) || r="fail/-"
  echo "K $(date -u +%T) $1 $r $(head -c 170 "$body" | tr '\n' ' ')" >> "$OUT"
  rm -f "$body"
}
list_status() {
  curl -sS -m 10 --cacert "$CA" "$BASE/api/files?limit=200" 2>/dev/null | python3 -c '
import json, sys, collections
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    print("list-failed"); sys.exit()
mine = [i for i in items if i["original_name"].startswith("chaos2-" + sys.argv[1] + "-")]
c = collections.Counter(i["status"] for i in mine)
idem = [i for i in mine if i["original_name"].endswith("idem.txt")]
print(" ".join(k + "=" + str(v) for k, v in sorted(c.items())) or "none", "| строк с ключом:", len(idem),
      "| id:", ",".join(i["id"] + ":" + i["status"] for i in idem))' "$RUN"
}

c=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/api/files/$ID")
[[ "$c" == 200 ]] || { echo "файл $ID не читается (HTTP $c), задай FILE_ID=..." >&2; exit 1; }
[[ -n "$BE" ]] || { echo "активный backend не найден" >&2; exit 1; }

TOTAL=$((PRE + HOLD + POST)); STOPPED=0; STARTED=0; K0=0; K1=0; K2=0; i=0; SECONDS=0
ev "старт RUN=$RUN backend=$BE ключ=$KEY, фазы: pre=${PRE}с down=${HOLD}с post=${POST}с"
while (( SECONDS < TOTAL )); do
  if (( SECONDS >= PRE && STOPPED == 0 )); then ev "docker stop minio"; docker stop minio > /dev/null; STOPPED=1; ev "minio остановлен"; fi
  if (( SECONDS >= PRE + HOLD && STARTED == 0 )); then ev "docker start minio"; docker start minio > /dev/null; STARTED=1; ev "minio запущен"; fi
  phase=pre; (( STOPPED )) && phase=down; (( STARTED )) && phase=post
  mh=$(docker inspect -f '{{.State.Health.Status}}' minio 2>/dev/null || echo none)
  line="P $(date -u +%T) $phase health=$(code "$BASE/health") file=$(code "$BASE/api/files/$ID") list=$(code "$BASE/api/files") minio=$mh"
  if (( i % 5 == 0 )); then
    url=$(curl -sS -m 5 --cacert "$CA" "$BASE/api/files/$ID/link" 2>/dev/null | jfield url)
    dlc="nourl"; [[ "$url" == http* ]] && dlc=$(code "$url")
    deps=$(curl -sS -m 5 --cacert "$CA" "$BASE/health/deps" 2>/dev/null | jfield minio)
    line="$line link=$(code "$BASE/api/files/$ID/link") dl=$dlc deps=$deps"
    echo "M $(date -u +%T) $phase $(snap)" >> "$OUT"
  fi
  echo "$line" >> "$OUT"
  if (( i % 10 == 0 )); then
    body=$(mktemp)
    r=$(curl -sS -m 8 --cacert "$CA" -o "$body" -w '%{http_code}/%{time_total}' \
        -F "file=@/var/tmp/chaos2-up.txt;filename=chaos2-$RUN-$i.txt" "$BASE/api/files" 2>/dev/null) || r="fail/-"
    echo "U $(date -u +%T) $phase $r $(head -c 140 "$body" | tr '\n' ' ')" >> "$OUT"
    rm -f "$body"
  fi
  if (( i % 15 == 0 )); then echo "A $(date -u +%T) $phase $(alerts)" >> "$OUT"; fi
  if (( STOPPED && K0 == 0 && SECONDS >= PRE + 60 )); then idem_upload "down(MinIO лежит)"; K0=1; fi
  if (( STARTED && K1 == 0 )) && [[ "$mh" == healthy ]]; then idem_upload "up1(повтор после запуска)"; K1=1
  elif (( K1 == 1 && K2 == 0 )); then idem_upload "up2(второй повтор)"; K2=1; fi
  i=$((i + 1)); sleep 1
done

ev "опрос закончен, жду обработки задач (до 120 с)"
w=0
while (( w <= 120 )); do
  st=$(list_status); echo "S $(date -u +%T) $st" >> "$OUT"
  case "$st" in *uploaded*|*processing*|*pending*|list-failed) ;; *) break ;; esac
  sleep 10; w=$((w + 10))
done
ev "готово"

SINCE=$(date -u -d "@$RUN" +%Y-%m-%dT%H:%M:%SZ)
python3 scripts/chaos-minio-summary.py "$OUT"
echo "== логи за время опыта"
echo "backend: 'upload to storage failed': $(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c 'upload to storage failed'), Traceback: $(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c Traceback)"
docker logs --since "$SINCE" worker 2>&1 | grep -iE 'error|traceback' | cut -c1-170 | sort | uniq -c | sort -rn | head -3
docker inspect -f 'worker: status={{.State.Status}} перезапусков={{.RestartCount}}' worker
docker inspect -f 'minio: status={{.State.Status}} health={{.State.Health.Status}}' minio
cp "$OUT" evidence/chaos2-minio-stop.txt
echo "готово"
