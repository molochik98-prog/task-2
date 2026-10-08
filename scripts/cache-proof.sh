#!/bin/bash
# Доказательство кеша: ключ появляется, TTL с разбросом, инвалидация при удалении.
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
rcli() { REDISCLI_AUTH="$(grep -E '^REDIS_PASSWORD=' .env | cut -d= -f2-)" docker exec -e REDISCLI_AUTH redis redis-cli "$@"; }
get() { curl -sS --cacert "$CA" -o /dev/null -w '%{http_code}' "https://app.local/api/files/$1"; }

echo "cache-proof-$(date +%s)" > /var/tmp/cp.txt
ID=$(curl -sS --cacert "$CA" -F file=@/var/tmp/cp.txt https://app.local/api/files | grep -oP '(?<="id":")[^"]+')
echo "ID=$ID"

echo "--- 1. ключ появляется после первого GET ---"
echo "до GET:    EXISTS=$(rcli EXISTS file:$ID)"
get "$ID" > /dev/null
echo "после GET: EXISTS=$(rcli EXISTS file:$ID) TTL=$(rcli TTL file:$ID)"

echo "--- 2. разброс TTL (DEL, GET, TTL по 8 раз; база 60 с, разброс до +30%) ---"
T=""
for i in 1 2 3 4 5 6 7 8; do rcli DEL "file:$ID" > /dev/null; get "$ID" > /dev/null; T="$T $(rcli TTL file:$ID)"; done
echo "TTL:$T"

echo "--- 3. инвалидация при удалении ---"
get "$ID" > /dev/null
echo "перед DELETE: EXISTS=$(rcli EXISTS file:$ID)"
echo "DELETE: http=$(curl -sS --cacert "$CA" -X DELETE -o /dev/null -w '%{http_code}' "https://app.local/api/files/$ID")"
echo "после DELETE: EXISTS=$(rcli EXISTS file:$ID), GET: http=$(get "$ID")  (ожидаем 0 и 404, а не устаревший 200)"
rm -f /var/tmp/cp.txt
