#!/bin/bash
set -uo pipefail

HEALTH_URL="https://app.local/health"
CACERT="/home/jahongir/certs/ca.crt"
DISK_PATH="/"
DISK_THRESHOLD=85

send_telegram() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${message}" > /dev/null
}

if ! curl -fsS --max-time 5 --cacert "$CACERT" "$HEALTH_URL" > /dev/null; then
  send_telegram "⚠️ $(hostname): /health не отвечает (${HEALTH_URL})"
fi

USAGE=$(df --output=pcent "$DISK_PATH" | tail -1 | tr -dc '0-9')
if [[ -n "$USAGE" ]] && [[ "$USAGE" -ge "$DISK_THRESHOLD" ]]; then
  send_telegram "⚠️ $(hostname): диск ${DISK_PATH} заполнен на ${USAGE}% (порог ${DISK_THRESHOLD}%)"
fi
