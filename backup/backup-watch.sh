#!/bin/bash
# Сторож: молчание не считается успехом. Аргументы: имя:файл_метки:макс_возраст_секунд
set -uo pipefail
bad=""
now=$(date +%s)
for spec in "$@"; do
  name=${spec%%:*}; rest=${spec#*:}; max=${rest##*:}; file=${rest%:*}
  if [[ ! -f "$file" ]]; then bad+="$name: нет метки успеха ($file)"$'\n'; continue; fi
  ts=$(cat "$file" 2>/dev/null || echo 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  age=$(( now - ts ))
  if (( age > max )); then bad+="$name: последний успех $((age / 3600)) ч назад (лимит $((max / 3600)) ч)"$'\n'; fi
done
[[ -z "$bad" ]] && exit 0
echo "$bad"
curl -fsS --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=$(hostname): бэкап не проходил"$'\n'"${bad}" > /dev/null
