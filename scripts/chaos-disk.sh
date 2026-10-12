#!/bin/bash
# CHAOS №5: том /srv/minio (только он) заполняется файлом-заглушкой, остаётся LEFT_MIB МиБ.
# Каждые 10 с загрузка файла SIZE_MIB МиБ. Потом заглушка удаляется, наблюдается восстановление.
# Тихий успех ищется сравнением размера и SHA-256 (их считает worker по объекту в MinIO) с исходным файлом.
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
BASE=https://app.local
VOL=/srv/minio
FILLER="$VOL/chaos5-filler"
LEFT_MIB="${LEFT_MIB:-80}"; SIZE_MIB="${SIZE_MIB:-25}"
PRE="${PRE:-20}"; HOLD="${HOLD:-130}"; POST="${POST:-70}"
OUT="${OUT:-/var/tmp/chaos5.txt}"
ID="${FILE_ID:-b45bb0e1-8af2-47d8-99c3-e3c57989a1a3}"
RUN=$(date +%s)
BE=$(docker ps --format '{{.Names}}' | grep -E '^backend-(blue|green)$' | head -1)

[[ "$(findmnt -no TARGET -T "$VOL")" == "$VOL" ]] || { echo "$VOL не отдельная файловая система: стоп (иначе заполнился бы корень)" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "нужен свежий sudo: выполни sudo -v и запусти снова" >&2; exit 1; }
[[ -n "$BE" ]] || { echo "активный backend не найден" >&2; exit 1; }
c=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/api/files/$ID")
[[ "$c" == 200 ]] || { echo "файл $ID не читается (HTTP $c), задай FILE_ID=..." >&2; exit 1; }

release() { sudo -n rm -f "$FILLER" 2>/dev/null || echo "!!! НЕ УДАЛОСЬ удалить $FILLER, выполни: sudo rm -f $FILLER" >&2; }
trap release EXIT
sudo -n rm -f "$FILLER"
: > "$OUT"
ev() { echo "E $(date -u +%T) $*" >> "$OUT"; }
avail() { df --output=avail -B1M "$VOL" | tail -1 | tr -d ' '; }
code() { local r; r=$(curl -sS -m 5 --cacert "$CA" -o /dev/null -w '%{http_code}/%{time_total}' "$@" 2>/dev/null) || r="fail/-"; printf '%s' "$r"; }
depsminio() { curl -sS -m 5 --cacert "$CA" "$BASE/health/deps" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("minio","?"))
except Exception: print("?")'; }
bucketobj() { docker exec "$BE" python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/metrics').read().decode())" 2>/dev/null | awk '/^bucket_objects /{print $2}'; }
alerts() { docker exec monitoring-stack-prometheus-1 wget -qO- http://localhost:9090/api/v1/alerts 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["data"]["alerts"]
    print(" ".join(a["labels"]["alertname"] + "=" + a["state"] for a in d) or "none")
except Exception:
    print("prometheus-unavailable")'; }
list_status() { curl -sS -m 10 --cacert "$CA" "$BASE/api/files?limit=200" 2>/dev/null | python3 -c '
import json, sys, collections
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    print("list-failed"); sys.exit()
c = collections.Counter(i["status"] for i in items if i["original_name"].startswith("chaos5-" + sys.argv[1] + "-"))
print(" ".join(k + "=" + str(v) for k, v in sorted(c.items())) or "none")' "$RUN"; }

head -c $((SIZE_MIB * 1024 * 1024)) /dev/urandom > /var/tmp/chaos5-up.bin
EXP_SIZE=$(stat -c %s /var/tmp/chaos5-up.bin); EXP_SHA=$(sha256sum /var/tmp/chaos5-up.bin | cut -d' ' -f1)
ev "старт RUN=$RUN expect size=$EXP_SIZE sha=$EXP_SHA; свободно на $VOL: $(avail) МиБ; фазы pre=${PRE}с full=${HOLD}с post=${POST}с"

TOTAL=$((PRE + HOLD + POST)); FILLED=0; FREED=0; i=0; SECONDS=0
while (( SECONDS < TOTAL )); do
  if (( SECONDS >= PRE && FILLED == 0 )); then
    a=$(avail); fill=$((a - LEFT_MIB))
    (( fill > 0 )) || { ev "свободного места мало ($a МиБ), стоп"; exit 1; }
    sudo -n fallocate -l "${fill}M" "$FILLER" || { ev "fallocate не удался"; exit 1; }
    FILLED=1; ev "заглушка ${fill} МиБ создана, свободно $(avail) МиБ (было $a)"
  fi
  if (( SECONDS >= PRE + HOLD && FREED == 0 )); then
    sudo -n rm -f "$FILLER"; FREED=1; ev "заглушка удалена, свободно $(avail) МиБ"
  fi
  phase=pre; (( FILLED )) && phase=full; (( FREED )) && phase=post
  echo "P $(date -u +%T) $phase health=$(code "$BASE/health") file=$(code "$BASE/api/files/$ID") list=$(code "$BASE/api/files")" >> "$OUT"
  if (( i % 5 == 0 )); then
    echo "M $(date -u +%T) $phase free=$(avail) minio=$(docker inspect -f '{{.State.Health.Status}}' minio 2>/dev/null || echo none) deps=$(depsminio) bucket_objects=$(bucketobj)" >> "$OUT"
  fi
  if (( i % 10 == 0 )); then
    body=$(mktemp)
    r=$(curl -sS -m 60 --cacert "$CA" -o "$body" -w '%{http_code}/%{time_total}' \
        -F "file=@/var/tmp/chaos5-up.bin;filename=chaos5-$RUN-$i.bin" "$BASE/api/files" 2>/dev/null) || r="fail/-"
    echo "U $(date -u +%T) $phase $r $(head -c 160 "$body" | tr '\n' ' ')" >> "$OUT"
    rm -f "$body"
  fi
  if (( i % 15 == 0 )); then echo "A $(date -u +%T) $phase $(alerts)" >> "$OUT"; fi
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
python3 scripts/chaos-disk-summary.py "$OUT" "$CA" "$BASE"
echo "== MinIO: логи за опыт"
docker logs --since "$SINCE" minio 2>&1 | cut -c1-200 | sort | uniq -c | sort -rn | head -5
echo "== backend: 'upload to storage failed': $(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c 'upload to storage failed'), Traceback: $(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c Traceback)"
docker inspect -f 'minio: status={{.State.Status}} health={{.State.Health.Status}} перезапусков={{.RestartCount}}' minio
echo "== том после опыта (заглушка удалена?)"; ls -la "$VOL" | head -6; df -h "$VOL" | tail -1
cp "$OUT" evidence/chaos5-disk-full.txt
echo "готово"
