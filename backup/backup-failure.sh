#!/bin/bash
# Вызывается из backup-failure@<unit>.service, когда упал unit с OnFailure=. Шлёт хвост журнала в Telegram.
set -uo pipefail
unit="${1:?usage: backup-failure.sh <unit>}"
tail_log=$(journalctl -u "$unit" -n 10 --no-pager -o cat 2>/dev/null)
curl -fsS --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=$(hostname): ${unit} FAILED"$'\n'"${tail_log}" > /dev/null
