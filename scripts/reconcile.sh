#!/bin/bash
# Сверка Postgres и MinIO. Запускает reconcile.py внутри активного backend-контейнера:
# у него уже есть DATABASE_URL, ключи S3 и сеть app-net.
set -uo pipefail

REPO="/home/jahongir/devops-backend"

send_telegram() {
  curl -sS --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${1}" > /dev/null
}

COLOR=$(grep -oP '(?<=backend-)[a-z]+(?=:8000)' "$REPO/nginx/nginx.conf" | head -1)
if [[ -z "$COLOR" ]]; then
  echo "reconcile: не удалось определить активный цвет из nginx.conf"
  send_telegram "$(hostname): сверка не запущена, не найден активный цвет в nginx.conf"
  exit 2
fi

out=$(timeout 120 docker exec -e RECONCILE_GRACE_MIN="${RECONCILE_GRACE_MIN:-10}" "backend-$COLOR" python reconcile.py 2>&1)
rc=$?
echo "$out"

case $rc in
  0)  exit 0 ;;
  10) send_telegram "$(hostname): сверка нашла рассинхрон Postgres/MinIO"$'\n'"$(echo "$out" | head -15)"
      exit 10 ;;
  *)  send_telegram "$(hostname): сверка не отработала (код $rc)"$'\n'"$(echo "$out" | tail -5)"
      exit "$rc" ;;
esac
