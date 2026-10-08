#!/bin/bash
# Доказательства этапа 4. Запуск: bash scripts/stage4-proof.sh naive|streams|dlq|all
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
TS=$(date +%s)
color() { grep -oP '(?<=backend-)[a-z]+(?=:8000)' nginx/nginx.conf | head -1; }
rcli() { REDISCLI_AUTH="$(grep -E '^REDIS_PASSWORD=' .env | cut -d= -f2-)" docker exec -e REDISCLI_AUTH redis redis-cli "$@"; }
upload() { echo "proof4-$1-$TS" > "/var/tmp/p4-$1.txt"; curl -sS --cacert "$CA" -F "file=@/var/tmp/p4-$1.txt" https://app.local/api/files | grep -oP '(?<="id":")[^"]+'; }
field() { curl -sS --cacert "$CA" "https://app.local/api/files/$1" | grep -oP "(?<=\"$2\":\")[^\"]+"; }
stats() { docker exec "backend-$(color)" python queue_stats.py; }
del() { curl -sS --cacert "$CA" -X DELETE -o /dev/null "https://app.local/api/files/$1"; }
restore() { docker compose up -d --no-deps --force-recreate worker > /dev/null 2>&1; rm -f /var/tmp/p4-*.txt; }

naive() {
  echo "=== 4.1 наивная очередь: список + BRPOP, без подтверждения ==="
  docker compose stop worker > /dev/null 2>&1
  docker rm -f worker-naive worker-naive2 > /dev/null 2>&1
  rcli DEL queue:naive queue:files > /dev/null
  IDS=(); for i in 1 2 3; do IDS+=("$(upload naive$i)"); done
  echo "созданы файлы: ${IDS[*]}"
  echo "LPUSH: в списке $(rcli LPUSH queue:naive "${IDS[@]}") задачи"
  docker compose run -d --no-deps --name worker-naive -e WORKER_MODE=naive -e PROCESS_DELAY_S=30 worker > /dev/null
  sleep 8
  echo "воркер взял первую задачу, BRPOP убрал её из списка: LLEN=$(rcli LLEN queue:naive)"
  for id in "${IDS[@]}"; do echo "  $id status=$(field "$id" status)"; done
  echo "--- docker kill посреди обработки ---"
  docker kill worker-naive > /dev/null; sleep 2
  echo "LLEN=$(rcli LLEN queue:naive) (две оставшиеся задачи на месте, а первой нет нигде)"
  docker compose run -d --no-deps --name worker-naive2 -e WORKER_MODE=naive -e PROCESS_DELAY_S=0 worker > /dev/null
  sleep 10
  echo "--- новый воркер отработал 10 секунд ---"
  for id in "${IDS[@]}"; do echo "  $id status=$(field "$id" status)"; done
  echo "LLEN=$(rcli LLEN queue:naive)"
  docker rm -f worker-naive worker-naive2 > /dev/null 2>&1
  rcli DEL queue:naive queue:files > /dev/null
  for id in "${IDS[@]}"; do del "$id"; done
}

streams() {
  echo "=== 4.2 Redis Streams: kill воркера посреди обработки десяти задач ==="
  rcli DEL queue:files queue:files:dead > /dev/null
  WORKER_DELAY_S=3 WORKER_MIN_IDLE_S=15 docker compose up -d --no-deps --force-recreate worker > /dev/null 2>&1
  sleep 4
  IDS=(); declare -A SHA
  for i in $(seq 1 10); do
    id=$(upload "s$i"); IDS+=("$id"); SHA[$id]=$(sha256sum "/var/tmp/p4-s$i.txt" | cut -d' ' -f1)
  done
  echo "загружено 10 файлов. $(stats)"
  sleep 8
  docker kill worker > /dev/null
  echo "--- docker kill после 8 секунд работы ---"
  for id in "${IDS[@]}"; do echo "  $id $(field "$id" status)"; done
  echo "очередь сразу после kill: $(stats)"
  docker start worker > /dev/null
  echo "--- worker запущен снова ---"
  for t in $(seq 1 24); do
    sleep 5
    n=0; for id in "${IDS[@]}"; do [[ "$(field "$id" status)" == "done" ]] && n=$((n+1)); done
    echo "  t=$((t*5))s done=$n/10  $(stats)"
    [[ $n -eq 10 ]] && break
  done
  echo "--- проверка результата ---"
  bad=0
  for id in "${IDS[@]}"; do
    got=$(field "$id" sha256); c=$(docker logs worker 2>&1 | grep -c "processed ok id=$id")
    ok=OK; [[ "$got" == "${SHA[$id]}" && "$c" == "1" ]] || { ok=ОШИБКА; bad=1; }
    echo "  $id sha=${got:0:12} ожидали=${SHA[$id]:0:12} processed_ok=$c $ok"
  done
  echo "возвратов зависших задач в логе: $(docker logs worker 2>&1 | grep -c 'reclaimed stuck task')"
  echo "итог: ошибок=$bad (0 = все десять обработаны, каждая по одному разу)"
  for id in "${IDS[@]}"; do del "$id"; done
}

dlq() {
  echo "=== 4.2 мёртвая очередь: задача, которая не обработается никогда ==="
  rcli DEL queue:files queue:files:dead > /dev/null
  WORKER_DELAY_S=0 WORKER_MIN_IDLE_S=15 docker compose up -d --no-deps --force-recreate worker > /dev/null 2>&1
  sleep 4
  docker stop worker > /dev/null
  id=$(upload dlq)
  docker exec "backend-$(color)" python -c "import storage; storage.remove('files/$id'); print('object removed')"
  echo "задача в очереди, объекта нет. $(stats)"
  docker start worker > /dev/null
  for t in $(seq 1 30); do
    sleep 5
    dead=$(rcli XLEN queue:files:dead)
    echo "  t=$((t*5))s dead=$dead  $(stats)"
    [[ "$dead" -ge 1 ]] && break
  done
  echo "--- содержимое DLQ ---"; rcli XRANGE queue:files:dead - +
  echo "статус файла: $(field "$id" status)"
  echo "--- лог worker ---"; docker logs worker 2>&1 | grep -E 'failed|reclaimed|DEAD' | cut -c1-190 | tail -8
  del "$id"
}

case "${1:-all}" in
  naive) naive ;; streams) streams ;; dlq) dlq ;;
  all) naive; streams; dlq ;;
esac
restore
