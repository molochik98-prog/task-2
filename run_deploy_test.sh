#!/usr/bin/env bash
set -euo pipefail

NGINX_CONF="/home/jahongir/devops-backend/nginx/nginx.conf"
DEPLOY_SCRIPT="/home/jahongir/devops-backend/deploy.sh"

ACTIVE=$(grep -oP '(?<=backend-)[a-z]+(?=:8000)' "$NGINX_CONF" || true)
if [ -z "$ACTIVE" ]; then
    echo "ОШИБКА: не удалось распознать текущий цвет в $NGINX_CONF — конфиг битый, проверь руками:"
    grep backend "$NGINX_CONF"
    exit 1
fi
echo "Активен перед тестом: backend-$ACTIVE"

# Логи пишем в файл ДО старта нагрузки — иначе deploy.sh удалит старый
# контейнер посреди теста, и его логи исчезнут вместе с ним (json-file
# log-driver привязан к жизни контейнера).
# "docker logs -f ... &" — запускает команду в ФОНЕ (текущий шелл не ждёт
# её завершения, продолжает выполнять следующие строки скрипта сразу).
# На всякий случай убиваем осиротевшие docker logs -f от прошлых неудачных
# прогонов ЭТОГО скрипта — если предыдущий запуск упал между стартом
# фонового сбора логов и штатной очисткой, процесс мог остаться висеть и
# писать в тот же файл параллельно с новым запуском (см. NETNS-LAB/README).
pkill -f "docker logs --tail 0 -f nginx" 2>/dev/null || true
pkill -f "docker logs --tail 0 -f backend-" 2>/dev/null || true

# trap регистрирует функцию, которая выполнится ПРИ ЛЮБОМ выходе из
# скрипта — успешном завершении, ошибке под set -e, Ctrl+C. Это гарантирует
# очистку фоновых процессов, даже если что-то упадёт до штатного kill в
# конце скрипта (именно так в прошлый раз остался висеть орфан).
cleanup() {
    kill "${NGINX_LOG_PID:-}" "${OLD_LOG_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

docker logs --tail 0 -f nginx > /tmp/nginx-test.log 2>&1 &
NGINX_LOG_PID=$!
docker logs --tail 0 -f "backend-$ACTIVE" > /tmp/backend-old-test.log 2>&1 &
OLD_LOG_PID=$!

echo "Старт нагрузки: $(date)"
wrk -t2 -c50 -d60s --latency https://app.local/items > /tmp/wrk-result.log 2>&1 &
WRK_PID=$!

# Деплой запускается ГАРАНТИРОВАННО на 15-й секунде теста — не от руки во
# втором окне (там задержка непредсказуема), а по таймеру внутри одного
# скрипта, синхронно с уже запущенным wrk.
sleep 15
echo "=== Запускаю deploy.sh на 15-й секунде теста: $(date) ==="
export DB_PASSWORD="${DB_PASSWORD:?переменная DB_PASSWORD не установлена}"
"$DEPLOY_SCRIPT"

# "wait PID" — дожидается завершения конкретного фонового процесса по его
# ID (не всех фоновых сразу), не давая скрипту завершиться раньше wrk.
wait "$WRK_PID"
echo "wrk завершён: $(date)"

# Явный kill больше не нужен здесь — trap cleanup EXIT (см. выше)
# сработает автоматически при завершении скрипта.

echo ""
echo "=== Результат wrk ==="
cat /tmp/wrk-result.log
echo ""
echo "=== Итоговые файлы для анализа ==="
echo "/tmp/wrk-result.log        — результат нагрузки"
echo "/tmp/nginx-test.log        — access/error-лог nginx за весь тест"
echo "/tmp/backend-old-test.log  — лог старого backend'а (до переключения)"
