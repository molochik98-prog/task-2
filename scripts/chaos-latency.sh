#!/bin/bash
# CHAOS №7: tc netem delay на исходящий трафик VM-1 -> VM-2 (192.168.64.5), только на него.
# Постоянная нагрузка wrk (c=20) по /api/files?limit=5 + пробы раз в секунду + метрики и алерты.
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
BASE=https://app.local
PG=192.168.64.5
DELAY="${DELAY:-300ms}"; CONN="${CONN:-20}"
PRE="${PRE:-60}"; HOLD="${HOLD:-450}"; POST="${POST:-90}"; CHUNK=30
OUT="${OUT:-/var/tmp/chaos7.txt}"
ID="${FILE_ID:-b45bb0e1-8af2-47d8-99c3-e3c57989a1a3}"
RUN=$(date +%s)
BE=$(docker ps --format '{{.Names}}' | grep -E '^backend-(blue|green)$' | head -1)

command -v wrk > /dev/null || { echo "нет wrk" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "нужен свежий sudo: sudo -v" >&2; exit 1; }
IFACE=$(ip -o route get "$PG" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[[ -n "$IFACE" ]] || { echo "не определён интерфейс до $PG" >&2; exit 1; }
sudo modprobe sch_netem 2>/dev/null; sudo modprobe sch_prio 2>/dev/null
if ! lsmod | grep -q '^sch_netem'; then
  echo "нет модуля sch_netem. Установи: sudo apt install -y linux-modules-extra-$(uname -r)  и запусти снова" >&2; exit 1
fi
tc qdisc show dev "$IFACE" | grep -q 'qdisc prio\|qdisc netem' && { echo "на $IFACE уже есть qdisc prio/netem, стоп: $(tc qdisc show dev "$IFACE")" >&2; exit 1; }
c=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/api/files/$ID")
[[ "$c" == 200 && -n "$BE" ]] || { echo "файл не читается или backend не найден" >&2; exit 1; }

CLEARED=0
clear_delay() { sudo -n tc qdisc del dev "$IFACE" root 2>/dev/null; CLEARED=1; }
cleanup() { clear_delay; kill $(jobs -p) 2>/dev/null; if tc qdisc show dev "$IFACE" | grep -q 'prio\|netem'; then echo "!!! задержка НЕ снята, выполни: sudo tc qdisc del dev $IFACE root" >&2; fi; }
trap cleanup EXIT
: > "$OUT"
ev() { echo "E $(date -u +%T) $*" >> "$OUT"; }
code() { local r; r=$(curl -sS -m 15 --cacert "$CA" -o /dev/null -w '%{http_code}/%{time_total}' "$@" 2>/dev/null) || r="fail/-"; printf '%s' "$r"; }
snap() {
  docker exec "$BE" python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/metrics').read().decode())" 2>/dev/null \
    | awk '/^(db_pool_in_use|db_pool_timeouts_total|db_pool_stale_total) /{printf "%s=%s ", $1, $2}'
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

TOTAL=$((PRE + HOLD + POST))
( while (( $(date +%s) < RUN + TOTAL )); do
    echo "W $(date -u +%T) $(wrk -t2 -c"$CONN" -d${CHUNK}s -s scripts/wrk-percentiles.lua "$BASE/api/files?limit=5" 2>&1 | grep -oP '(?<=RESULT ).*')" >> "$OUT"
  done ) &
ev "старт RUN=$RUN iface=$IFACE delay=$DELAY wrk -c$CONN; фазы pre=${PRE}с delay=${HOLD}с post=${POST}с"

ON=0; OFF=0; i=0; SECONDS=0
while (( SECONDS < TOTAL )); do
  if (( SECONDS >= PRE && ON == 0 )); then
    sudo -n tc qdisc add dev "$IFACE" root handle 1: prio \
      && sudo -n tc qdisc add dev "$IFACE" parent 1:3 handle 30: netem delay "$DELAY" \
      && sudo -n tc filter add dev "$IFACE" protocol ip parent 1:0 prio 3 u32 match ip dst "$PG"/32 flowid 1:3 \
      || { ev "tc не удалось настроить"; exit 1; }
    ON=1; ev "задержка $DELAY включена: $(tc qdisc show dev "$IFACE" | tr '\n' ';')"
  fi
  if (( SECONDS >= PRE + HOLD && OFF == 0 )); then clear_delay; OFF=1; ev "задержка снята"; fi
  phase=pre; (( ON )) && phase=delay; (( OFF )) && phase=post
  echo "P $(date -u +%T) $phase health=$(code "$BASE/health") file=$(code "$BASE/api/files/$ID") list1=$(code "$BASE/api/files?limit=1")" >> "$OUT"
  if (( i % 10 == 0 )); then
    body=$(mktemp); echo "chaos7" > /var/tmp/chaos7-up.txt
    r=$(curl -sS -m 20 --cacert "$CA" -o "$body" -w '%{http_code}/%{time_total}' -F "file=@/var/tmp/chaos7-up.txt;filename=chaos7-$RUN-$i.txt" "$BASE/api/files" 2>/dev/null) || r="fail/-"
    echo "U $(date -u +%T) $phase $r $(head -c 90 "$body" | tr '\n' ' ')" >> "$OUT"; rm -f "$body"
  fi
  (( i % 5 == 0 )) && echo "M $(date -u +%T) $phase $(snap) docker=$(docker inspect -f '{{.State.Health.Status}}' "$BE")" >> "$OUT"
  (( i % 15 == 0 )) && echo "A $(date -u +%T) $phase $(alerts)" >> "$OUT"
  i=$((i + 1)); sleep 1
done
ev "опрос закончен, дожидаюсь wrk"; wait
ev "готово"
python3 scripts/chaos-latency-summary.py "$OUT"
echo "== после опыта: tc на $IFACE: $(tc qdisc show dev "$IFACE" | tr '\n' ';')"
cp "$OUT" evidence/chaos7-latency.txt
echo "готово"
