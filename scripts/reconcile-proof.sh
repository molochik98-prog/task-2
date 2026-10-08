#!/bin/bash
# Доказательство работы сверки: создаём рассинхрон мимо приложения и смотрим, находит ли его reconcile.
set -uo pipefail
cd /home/jahongir/devops-backend
CA=/home/jahongir/certs/ca.crt
COLOR=$(grep -oP '(?<=backend-)[a-z]+(?=:8000)' nginx/nginx.conf | head -1)
BE="backend-$COLOR"
TS=$(date +%s)

up() {
  echo "proof-$1-$TS" > "/var/tmp/proof-$1.txt"
  curl -sS --cacert "$CA" -H "Idempotency-Key: proof-$1-$TS" \
    -F "file=@/var/tmp/proof-$1.txt" https://app.local/api/files | grep -oP '(?<="id":")[^"]+'
}
A=$(up a); B=$(up b)
if [[ -z "$A" || -z "$B" ]]; then echo "загрузка через API не удалась: A='$A' B='$B'"; exit 1; fi
echo "A=$A (строку удалим из БД мимо приложения)"
echo "B=$B (объект удалим из MinIO мимо приложения)"

echo "--- 1. строка A удалена напрямую в Postgres ---"
docker exec "$BE" python -c "
import os, sys, psycopg2
c = psycopg2.connect(os.environ['DATABASE_URL'])
cur = c.cursor()
cur.execute('DELETE FROM files WHERE id = %s', (sys.argv[1],))
print('rows deleted:', cur.rowcount)
c.commit()" "$A"

echo "--- 2. объект B удалён напрямую из MinIO ---"
docker exec "$BE" python -c "import sys, storage; storage.remove('files/' + sys.argv[1]); print('object removed')" "$B"

echo "--- 3. посторонний объект залит в bucket ---"
docker exec "$BE" python -c "import io, storage; storage.put('files/manual-orphan-test', io.BytesIO(b'manual'), 6, 'text/plain'); print('object put')"

echo "--- 4. сверка (grace=0) ---"
docker exec -e RECONCILE_GRACE_MIN=0 "$BE" python reconcile.py; echo "rc=$?"

echo "--- 5. то же через systemd (проверка алерта в Telegram) ---"
sudo systemd-run --wait --pipe --collect -p EnvironmentFile=/etc/telegram-alert.env \
  --setenv=RECONCILE_GRACE_MIN=0 /usr/local/bin/reconcile.sh; echo "rc=$?"

echo "--- 6. уборка ---"
curl -sS --cacert "$CA" -X DELETE -o /dev/null -w 'delete B: http=%{http_code}\n' "https://app.local/api/files/$B"
docker exec "$BE" python -c "import storage; [storage.remove(k) for k in ('files/$A', 'files/manual-orphan-test')]; print('cleaned')"
rm -f /var/tmp/proof-a.txt /var/tmp/proof-b.txt /var/tmp/idem.txt

echo "--- 7. контрольная сверка: рассинхронов быть не должно ---"
docker exec -e RECONCILE_GRACE_MIN=0 "$BE" python reconcile.py; echo "rc=$?"
