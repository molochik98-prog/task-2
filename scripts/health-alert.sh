#!/bin/bash
set -uo pipefail

HEALTH_URL="${HEALTH_URL:-https://app.local/health}"
CACERT="/home/jahongir/certs/ca.crt"
DISK_PATH="/"
DISK_THRESHOLD=85

send_telegram() {
  local message="$1"
  curl -sS --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${message}" > /dev/null
}

# Без -f: curl отдаёт код ответа, и в сообщение попадает HTTP-код (раньше он был виден только в журнале)
if CODE=$(curl -sS --max-time 5 --cacert "$CACERT" -o /dev/null -w '%{http_code}' "$HEALTH_URL"); then
  [[ "$CODE" == 200 ]] || send_telegram "⚠️ $(hostname): /health вернул HTTP ${CODE} (${HEALTH_URL})"
else
  RC=$?  # сразу: подстановка $(hostname) в тексте ниже сбросила бы $? в 0
  send_telegram "⚠️ $(hostname): /health не отвечает, curl rc=${RC} (${HEALTH_URL})"
fi

USAGE=$(df --output=pcent "$DISK_PATH" | tail -1 | tr -dc '0-9')
if [[ -n "$USAGE" ]] && [[ "$USAGE" -ge "$DISK_THRESHOLD" ]]; then
  send_telegram "⚠️ $(hostname): диск ${DISK_PATH} заполнен на ${USAGE}% (порог ${DISK_THRESHOLD}%)"
fi
