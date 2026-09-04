#!/usr/bin/env bash
set -euo pipefail
# -e: любая команда с ненулевым exit-кодом сразу останавливает скрипт
# -u: обращение к необъявленной переменной — ошибка (ловит опечатки вроде $COLR вместо $COLOR)
# -o pipefail: если в пайплайне (a | b) упадёт a, весь пайплайн считается упавшим, не только b

NGINX_CONF="/home/jahongir/devops-backend/nginx/nginx.conf"
BACKEND_DIR="/home/jahongir/devops-backend/backend"
CERT="/home/jahongir/certs/ca.crt"

# --- 1. Кто активен сейчас (источник правды — сам nginx.conf, не память/переменные) ---
CURRENT=$(grep -oP '(?<=backend-)[a-z]+(?=:8000)' "$NGINX_CONF" || true)
if [ -z "$CURRENT" ]; then
    echo "ОШИБКА: не удалось распознать текущий цвет в $NGINX_CONF — конфиг битый, проверь руками:"
    grep backend "$NGINX_CONF"
    exit 1
fi
echo "Текущий активный цвет: $CURRENT"

if [ "$CURRENT" = "blue" ]; then
    COLOR="green"
elif [ "$CURRENT" = "green" ]; then
    COLOR="blue"
else
    echo "Не удалось распознать текущий цвет в $NGINX_CONF"
    exit 1
fi
echo "Деплоим новый цвет: $COLOR"

# --- 2. Собрать новый образ ---
docker build -t backend:$COLOR "$BACKEND_DIR"

# --- 3. Поднять новый контейнер РЯДОМ со старым (старый не трогаем вообще) ---
docker run -d --name backend-$COLOR --network app-net \
  --read-only \
  --cap-drop ALL \
  --add-host db:192.168.64.5 \
  -v "$CERT":/certs/ca.crt:ro \
  -e DATABASE_URL="postgresql://appuser:${DB_PASSWORD}@db:5432/appdb?sslmode=verify-full&sslrootcert=/certs/ca.crt" \
  backend:$COLOR

# --- 4. Health-check с ретраями ---
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' backend-$COLOR)
HEALTHY=0
for i in $(seq 1 10); do
    if curl -f "http://$IP:8000/health"; then
        echo "backend-$COLOR healthy"
        HEALTHY=1
        break
    fi
    echo "Попытка $i не удалась, жду..."
    sleep 3
done

# --- 5. Если health-check не прошёл — откат нового, старый не тронут, скрипт падает с ошибкой для CI ---
if [ "$HEALTHY" -ne 1 ]; then
    echo "Health check не прошёл после 10 попыток — откатываю новый контейнер"
    docker stop backend-$COLOR
    docker rm backend-$COLOR
    exit 1
fi

# --- 6. Переключение nginx: перезапись СУЩЕСТВУЮЩЕГО inode (не sed -i!) ---
# sed -i делает temp-file + rename → новый inode → bind-mount контейнера "слепнет".
# cat > пишет в уже смонтированный inode на месте — контейнер видит изменения сразу.
sed "s/backend-$CURRENT/backend-$COLOR/" "$NGINX_CONF" > /tmp/nginx.conf.new
cat /tmp/nginx.conf.new > "$NGINX_CONF"
rm /tmp/nginx.conf.new

docker exec nginx nginx -t
docker exec nginx nginx -s reload

# После reload старые worker-процессы nginx не исчезают мгновенно — они
# доедают уже начатые запросы к СТАРОМУ backend'у (это и есть механизм
# zero-downtime reload). Если убить старый контейнер сразу, эти запросы
# оборвутся (RST/Connection refused) прямо посреди ответа — коротким,
# но реальным всплеском ошибок, подтверждённым нагрузочным тестом.
# Ждём, пока nginx сам не завершит все старые worker'ы (видно в выводе
# "docker top" как "is shutting down"), прежде чем убирать старый backend.
echo "Ожидаю завершения старых worker-процессов nginx (graceful drain)..."
for i in $(seq 1 20); do
    if ! docker top nginx | grep -q "is shutting down"; then
        break
    fi
    sleep 0.5
done

# --- 7. Только теперь, после подтверждённого переключения И слива старых
#        соединений — убираем старый ---
docker stop backend-$CURRENT
docker rm backend-$CURRENT

echo "Деплой завершён успешно: активен backend-$COLOR"
