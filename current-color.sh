#!/bin/bash
# Определяет текущий активный blue/green-цвет из nginx.conf — тот же
# источник правды, что использует deploy.sh (пункт 5). Цвет нигде отдельно
# не хранится: если deploy.sh переключит nginx.conf, этот скрипт на
# следующий вызов (restart/reboot) подхватит новое значение автоматически.
#
# ВАЖНО: сверь регэксп ниже с реальным grep-паттерном в своём deploy.sh —
# они должны читать один и тот же формат строки. Если разойдутся, deploy.sh
# и systemd будут видеть разный "текущий цвет" — источник правды перестанет
# быть единственным.

set -euo pipefail

NGINX_CONF="/home/jahongir/devops-backend/nginx/nginx.conf"

COLOR=$(grep -oP 'set \$backend_upstream backend-\K(blue|green)' "$NGINX_CONF") || true

if [[ -z "${COLOR:-}" ]]; then
  echo "ERROR: не удалось определить активный цвет из $NGINX_CONF" >&2
  exit 1
fi

if [[ "${1:-}" == "--write" ]]; then
  echo "$COLOR" > "${2:?путь для записи не указан}"
else
  echo "$COLOR"
fi
