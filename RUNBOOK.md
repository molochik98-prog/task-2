# RUNBOOK: восстановление Postgres, MinIO и Redis из бэкапов

Документ для случая, когда данные одного, двух или всех трёх хранилищ потеряны (том пуст или удалён, база не стартует), а сами ВМ, Docker, репозиторий, `.env`, `~/certs` и systemd-таймеры целы.
Шаги проверены на учении 2026-10-12 – 2026-10-14 (раздел «Результаты учения»). Пометка `(не проверено)` означает шаг или утверждение, которые на учении не выполнялись.

## 0. Что где лежит

| Хранилище | ВМ | Данные | Копия |
|---|---|---|---|
| Postgres 18 (кластер `main`) | VM-2 | `/var/lib/postgresql/18/main`, конфигурация и TLS-сертификат в `/etc/postgresql/18/main` | дампы `pg_dump -Fc` в `/var/backups/postgresql-appdb/appdb-*.dump` (7 последних, только на VM-2) |
| MinIO (контейнер `minio`) | VM-1 | `/srv/minio/data` (bind mount, отдельный том ext4 `/srv/minio`, владелец 10001:10001, права 750) | на VM-2: `/var/backups/vm1/minio/<время>/data` + `SHA256SUMS` + `COMPLETE`; на VM-1: `/var/backups/minio/latest` |
| Redis (контейнер `redis`) | VM-1 | именованный том Docker `redis-data` (`dump.rdb` и `appendonlydir`) | на VM-2: `/var/backups/vm1/redis/<время>/redis-*.rdb`; на VM-1: `/var/backups/redis/latest` |

Копия с VM-1 попадает на VM-2 таймером `vm1-pull.timer`, поэтому при потере только тома используется копия с VM-2, а не локальная.
Каталоги копий на VM-2 принадлежат `vm1-pull` и закрыты правами 700, поэтому все команды ниже, которые читают эти каталоги, выполняются через `sudo sh -c '...'`: раскрытие `*` обычным пользователем не сработает.

**Что остаётся целым и из чего собирается всё остальное:** репозиторий `~/devops-backend` (compose, скрипты), `.env` и `.env.backend` (секреты), `~/certs`, сеть Docker `app-net`, образы Docker, systemd-юниты и таймеры.
**Что пропадает вместе с хранилищем и не входит в бэкап:** роль Postgres `appuser` с паролем, политика и пользователь MinIO (S3-ключи приложения). Их создают шаги 3.4 и 4.3.

## 1. Порядок и почему

1. **Postgres.** Это источник истины о том, какие файлы существуют (`files`). Без него не с чем сверять объекты.
2. **MinIO.** Объекты без строк в Postgres бесполезны, а строки без объектов приложение показывает как ошибку.
3. **Redis.** Последним, потому что очередь восстанавливается из Postgres: sweeper в worker ставит в очередь файлы со статусом `uploaded` старше 2 минут и `processing` старше 10 минут.
4. **Проверка согласованности:** `reconcile` сверяет строки и объекты.

## 2. Подготовка к учению (не нужна при настоящей аварии)

Автоматику при учении нужно отключить (`disable --now`), а не просто остановить: ВМ при учении выключаются, а `stop` действует только до перезагрузки. После включения ВМ таймеры стартуют снова (они `enabled`), бэкап пустого хранилища снимет пустую копию и опубликует пустой `latest`, а `vm1-pull` заберёт его и сдвинет ротацию. Обратно таймеры включаются шагом 5 раздела 6 командой `enable --now`.

VM-1:

```
sudo -v
```
```
sudo systemctl disable --now redis-backup.timer minio-backup.timer reconcile.timer
systemctl list-timers --all --no-legend | grep -E 'redis-backup|minio-backup|reconcile' || echo "таймеры остановлены"
```

VM-2:

```
sudo -v
```
```
sudo systemctl disable --now pg-backup.timer vm1-pull.timer
systemctl list-timers --all --no-legend | grep -E 'pg-backup|vm1-pull' || echo "таймеры остановлены"
```

### 2.1 Эталон «до»

VM-2:

```
sudo -u postgres psql -d appdb -Atc "select status, count(*) from files group by 1 order by 1" -Atc "select 'items', count(*) from items"
```

VM-1:

```
cd ~/devops-backend
envval() { grep -E "^$1=" .env | cut -d= -f2-; }
export MC_HOST_app="http://$(envval MINIO_ROOT_USER):$(envval MINIO_ROOT_PASSWORD)@localhost:9000"
mc() { docker exec -e MC_CONFIG_DIR=/tmp/.mc -e MC_HOST_app minio mc "$@"; }
export REDISCLI_AUTH="$(envval REDIS_PASSWORD)"
echo "объектов в uploads: $(mc ls --recursive app/uploads | wc -l)"
mc ls --recursive --json app/uploads | python3 -I -c 'import sys,json;print("байт в uploads:", sum(json.loads(l)["size"] for l in sys.stdin if l.strip() and json.loads(l).get("type")=="file"))'
echo "Redis DBSIZE: $(docker exec -e REDISCLI_AUTH redis redis-cli --no-auth-warning DBSIZE)"
echo "Redis XLEN мёртвой очереди: $(docker exec -e REDISCLI_AUTH redis redis-cli --no-auth-warning XLEN queue:files:dead)"
unset REDISCLI_AUTH MC_HOST_app
```

Результат записать: он понадобится в шаге 6.

### 2.2 Свежие бэкапы всех трёх

VM-2, затем VM-1, затем снова VM-2 (pull). Между шагами никаких загрузок.

VM-2:

```
sudo systemctl start pg-backup.service && sudo cat /var/backups/postgresql-appdb/.last-success
```

VM-1:

```
sudo systemctl start redis-backup.service && sudo systemctl start minio-backup.service && echo "бэкапы VM-1 готовы"
```

VM-2:

```
sudo systemctl start vm1-pull.service
sudo sh -c 'for s in redis minio; do echo "$s: $(ls -1d /var/backups/vm1/$s/[0-9]*-[0-9]* | sort | tail -1)"; done'
```

Ожидается: у `redis` и `minio` последняя копия имеет время, совпадающее с только что снятым бэкапом. Если последняя копия старая, pull не отработал, разбираться до учения.

## 3. Postgres (VM-2)

**Симптом аварии:** `/health` backend отвечает 503, в логе Postgres нет кластера или он не стартует, `pg_lsclusters` показывает `down`.

### 3.1 «Потерять» каталог данных (только для учения)

```
sudo systemctl stop postgresql@18-main
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.lost
```

Каталог переименован, а не удалён: так можно откатиться, если восстановление не получится. `main.lost` удаляется в конце.

### 3.2 Создать пустой кластер

Конфигурация (`postgresql.conf`, `pg_hba.conf`, TLS) лежит в `/etc/postgresql/18/main` и от потери данных не страдает, поэтому кластер не пересоздаётся командой `pg_createcluster`, которая её перезапишет.

```
sudo -u postgres /usr/lib/postgresql/18/bin/initdb -D /var/lib/postgresql/18/main --locale=en_US.UTF-8 --encoding=UTF8
sudo systemctl start postgresql@18-main
pg_lsclusters
```

Ожидается: статус `online`.

### 3.3 База

```
sudo -u postgres createdb -T template0 --locale=en_US.UTF-8 --encoding=UTF8 appdb
```

### 3.4 Роль `appuser` (проверено частично)

Роли хранятся на уровне кластера, `pg_dump appdb` их не включает. Роль нужна до восстановления данных (шаг 3.5): права из дампа применяются к уже существующей роли. Пароль должен совпасть с паролем в `DATABASE_URL` из `.env.backend` на VM-1. Знает его только этот файл, поэтому пароль не вводят по памяти: он едет файлом через Mac и не печатается на экран. `CREATE ROLE` выполнялся на учении; передача файлом через Mac, `ALTER ROLE` из stdin и сверка пароля в `.env.backend` проверены 2026-10-15 (раздел 9), а связка из этого шага целиком не прогонялась.

VM-2:

```
sudo -u postgres psql -c "CREATE ROLE appuser LOGIN"
```

Ожидается `CREATE ROLE`.

VM-1 (пароль из `.env.backend` в файл с правами 600, на экран ничего не выводится):

```
( umask 077; grep '^DATABASE_URL=' ~/devops-backend/.env.backend | sed -E 's#.*://[^:]+:([^@]+)@.*#\1#' > ~/appuser.pw )
wc -c ~/appuser.pw
```

Ожидается число символов пароля плюс один (перевод строки), не 0 и не 1.

Терминал Mac:

```
scp -3 jahongir@192.168.64.3:appuser.pw jaha_task_3@192.168.64.5:appuser.pw
```

VM-2 (если `log_statement` не `none`, Postgres записал бы пароль в свой журнал, поэтому смена идёт только при `none`):

```
chmod 600 ~/appuser.pw
LS=$(sudo -u postgres psql -Atc "show log_statement")
echo "log_statement=$LS"
[ "$LS" = none ] && printf "ALTER ROLE appuser PASSWORD '%s';\n" "$(cat ~/appuser.pw)" | sudo -u postgres psql -d appdb -v ON_ERROR_STOP=1
rm -f ~/appuser.pw
```

Ожидается `log_statement=none` и `ALTER ROLE`. Затем на VM-1: `rm -f ~/appuser.pw`.

### 3.5 Восстановить данные

```
DUMP=$(sudo sh -c 'ls -1t /var/backups/postgresql-appdb/appdb-*.dump | head -1')
echo "дамп: $DUMP"
sudo -u postgres pg_restore -d appdb --exit-on-error "$DUMP"
sudo -u postgres psql -d appdb -c "ANALYZE"
```

Ожидается: `pg_restore` завершается без вывода и с кодом 0. `--exit-on-error` остановит восстановление на первой ошибке, а не оставит полурабочую базу.

### 3.6 Проверка

VM-2:

```
sudo -u postgres psql -d appdb -Atc "select status, count(*) from files group by 1 order by 1" -Atc "select 'items', count(*) from items" -c '\dp files'
```

Ожидается: те же числа, что в эталоне, у `files` права `appuser=arwd/postgres`.

VM-1:

```
curl -sS --cacert ~/certs/ca.crt -w ' http=%{http_code}\n' https://app.local/health
```

Ожидается: `{"status":"ok"} http=200`. Пул backend сам отбросит мёртвые соединения (проверка `SELECT 1` при выдаче соединения), перезапуск backend не нужен.

## 4. MinIO (VM-1)

**Симптом аварии:** загрузка отвечает 503, `/health/deps` показывает MinIO не `ok`, срабатывает `StorageErrors`.

### 4.1 Перенести копию с VM-2 на VM-1

VM-2:

```
sudo sh -c 'D=$(ls -1d /var/backups/vm1/minio/[0-9]*-[0-9]* | sort | tail -1); echo "копия: $D"; rm -rf /home/jaha_task_3/restore-minio; cp -a "$D" /home/jaha_task_3/restore-minio; chown -R jaha_task_3: /home/jaha_task_3/restore-minio'
```

Копия идёт через Mac: у VM-1 намеренно нет доступа к VM-2 (бэкапы по pull-модели: VM-2 забирает копии с VM-1 ограниченным ключом), и прямой `scp` с VM-1 на VM-2 заканчивается `Permission denied (publickey)`. Это не поломка.

VM-1:

```
rm -rf ~/restore-minio
```

Терминал Mac (не ВМ; `-3` означает «копировать через локальную машину»):

```
scp -3 -r jaha_task_3@192.168.64.5:restore-minio jahongir@192.168.64.3:restore-minio
```

VM-1:

```
cd ~/restore-minio
sha256sum -c --quiet SHA256SUMS && echo "SHA-256: все файлы совпали"
echo "файлов в data: $(find data -type f | wc -l), строк в SHA256SUMS: $(wc -l < SHA256SUMS)"
```

Ожидается: «все файлы совпали» и равные числа.

### 4.2 «Потерять» том (только для учения)

```
cd ~/devops-backend
docker compose stop minio
sudo find /srv/minio/data -mindepth 1 -delete
sudo ls -ld /srv/minio/data
```

Ожидается: каталог пуст, владелец `10001 10001`, права `drwxr-x---`. Compose требует, чтобы каталог существовал (`create_host_path: false`).
Если потерян сам том (диск): создать файловую систему и смонтировать по UUID из `/etc/fstab`, затем `sudo install -d -o 10001 -g 10001 -m 750 /srv/minio/data` (не проверено).

### 4.3 Запустить пустой MinIO, создать бакет, политику и пользователя (не проверено)

```
cd ~/devops-backend
docker compose up -d minio
for i in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Health.Status}}' minio)" = healthy ] && break; sleep 2; done
docker inspect -f 'minio: {{.State.Health.Status}}' minio
```

Ожидается: `healthy` (около 30 с).

```
cd ~/devops-backend
envval() { grep -E "^$1=" .env | cut -d= -f2-; }
export MC_HOST_app="http://$(envval MINIO_ROOT_USER):$(envval MINIO_ROOT_PASSWORD)@localhost:9000"
export K="$(envval S3_ACCESS_KEY)" S="$(envval S3_SECRET_KEY)"
mc() { docker exec -e MC_CONFIG_DIR=/tmp/.mc -e MC_HOST_app minio mc "$@"; }
mc mb app/uploads
docker exec -i minio sh -c 'cat > /tmp/uploads-rw.json' <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::uploads"]},{"Effect":"Allow","Action":["s3:DeleteObject","s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::uploads/*"]}]}
JSON
mc admin policy create app uploads-rw /tmp/uploads-rw.json
docker exec -e MC_CONFIG_DIR=/tmp/.mc -e MC_HOST_app -e K -e S minio sh -c 'mc admin user add app "$K" "$S"'
docker exec -e MC_CONFIG_DIR=/tmp/.mc -e MC_HOST_app -e K minio sh -c 'mc admin policy attach app uploads-rw --user "$K"'
mc anonymous get app/uploads
unset K S MC_HOST_app
```

Ожидается: `Access permission for 'app/uploads' is 'private'`. Ключи приложения берутся из `.env` и не попадают в командную строку хоста: в `docker exec` передаются только имена переменных. Политика `uploads-rw` дословно повторяет действующую: `ListBucket` на бакет, `GetObject`, `PutObject`, `DeleteObject` на объекты бакета.

### 4.4 Загрузить объекты из копии

Тем же способом, что и скрипт бэкапа: одноразовый контейнер из образа MinIO с `mc`, без прав, только для чтения копии.

Контейнер запускается от пользователя, которому принадлежит копия (`--user "$(id -u):$(id -g)"`), а не от root: при `--cap-drop ALL` у root нет прав читать файлы копии с правами 600 и 700.

```
cd ~/devops-backend
envval() { grep -E "^$1=" .env | cut -d= -f2-; }
IMAGE=$(docker inspect minio --format '{{.Config.Image}}')
export MC_HOST_exp="http://$(envval MINIO_ROOT_USER):$(envval MINIO_ROOT_PASSWORD)@minio:9000"
docker run --rm --network app-net --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -e MC_HOST_exp -e MC_CONFIG_DIR=/tmp/.mc \
  -v "$HOME/restore-minio/data:/import:ro" \
  --entrypoint mc "$IMAGE" mirror --quiet /import exp/uploads
unset MC_HOST_exp
```

### 4.5 Проверка

```
cd ~/devops-backend
envval() { grep -E "^$1=" .env | cut -d= -f2-; }
export MC_HOST_app="http://$(envval MINIO_ROOT_USER):$(envval MINIO_ROOT_PASSWORD)@localhost:9000"
mc() { docker exec -e MC_CONFIG_DIR=/tmp/.mc -e MC_HOST_app minio mc "$@"; }
echo "объектов в uploads: $(mc ls --recursive app/uploads | wc -l)"
mc ls --recursive --json app/uploads | python3 -I -c 'import sys,json;print("байт в uploads:", sum(json.loads(l)["size"] for l in sys.stdin if l.strip() and json.loads(l).get("type")=="file"))'
read -r SUM P < ~/restore-minio/SHA256SUMS
KEY=${P#./data/}
echo "образец: $KEY"
echo "в копии: $SUM"
echo "в MinIO: $(mc cat "app/uploads/$KEY" | sha256sum | cut -d' ' -f1)"
unset MC_HOST_app
```

Ожидается: число объектов и байт как в эталоне, SHA-256 образца совпадает.

## 5. Redis (VM-1)

**Симптом аварии:** `queue_stats_up` равен 0, `RedisUnavailable` и `CacheBypassed` горят, `DBSIZE` пуст после перезапуска.

Redis запускается с `--appendonly yes`. При включённом AOF Redis после старта читает AOF и игнорирует `dump.rdb`, поэтому просто положить RDB в пустой том нельзя: он стартует пустым (по документации Redis, не проверено на 8.10.2). Порядок такой: поднять временный экземпляр с выключенным AOF, убедиться, что данные загрузились, включить AOF, дождаться перезаписи и только потом запускать штатный контейнер.

### 5.1 Перенести копию с VM-2

VM-2:

```
sudo sh -c 'D=$(ls -1d /var/backups/vm1/redis/[0-9]*-[0-9]* | sort | tail -1); echo "копия: $D"; rm -rf /home/jaha_task_3/restore-redis; cp -a "$D" /home/jaha_task_3/restore-redis; chown -R jaha_task_3: /home/jaha_task_3/restore-redis'
```

VM-1:

```
rm -rf ~/restore-redis
```

Терминал Mac (так же, как в 4.1: прямого доступа с VM-1 на VM-2 нет):

```
scp -3 -r jaha_task_3@192.168.64.5:restore-redis jahongir@192.168.64.3:restore-redis
```

VM-1:

```
cd ~/restore-redis && sha256sum -c --quiet SHA256SUMS && echo "SHA-256: совпало" && ls -la
```

### 5.2 «Потерять» том (только для учения)

```
cd ~/devops-backend
docker compose stop redis
docker compose rm -f redis
docker volume rm redis-data
docker compose create redis
docker volume inspect redis-data --format '{{.Name}} {{.Mountpoint}}'
```

`docker compose create` заново создаёт том с метками Compose и контейнер без запуска.

### 5.3 Положить снимок в пустой том

```
IMAGE=$(docker inspect redis --format '{{.Config.Image}}')
docker run --rm --user 0:0 --entrypoint sh -v redis-data:/data -v "$HOME/restore-redis:/src:ro" "$IMAGE" \
  -c 'cp /src/redis-*.rdb /data/dump.rdb && chown redis:redis /data/dump.rdb && chmod 600 /data/dump.rdb && ls -la /data'
```

Ожидается: `dump.rdb` с владельцем `redis redis` и правами `-rw-------`.

### 5.4 Временный экземпляр без AOF

```
IMAGE=$(docker inspect redis --format '{{.Config.Image}}')
docker run -d --name redis-restore --network none --user redis -v redis-data:/data --entrypoint redis-server "$IMAGE" \
  --dir /data --dbfilename dump.rdb --appendonly no --save "" --bind 127.0.0.1 > /dev/null
for i in $(seq 1 20); do docker exec redis-restore redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 1; done
echo "DBSIZE: $(docker exec redis-restore redis-cli DBSIZE)"
echo "XLEN мёртвой очереди: $(docker exec redis-restore redis-cli XLEN queue:files:dead)"
```

Ожидается: те же `DBSIZE` и `XLEN`, что в эталоне. Если `DBSIZE` равен 0, а в эталоне нет, остановить и разбираться: RDB не загрузился.

### 5.5 Включить AOF и перенести данные в него

```
docker exec redis-restore redis-cli CONFIG SET appendonly yes
for i in $(seq 1 60); do
  info=$(docker exec redis-restore redis-cli INFO persistence | tr -d '\r')
  if grep -q '^aof_rewrite_in_progress:0' <<< "$info" && grep -q '^aof_last_bgrewrite_status:ok' <<< "$info"; then echo "перезапись AOF завершена"; break; fi
  sleep 1
done
docker exec redis-restore redis-cli DBSIZE
docker stop redis-restore && docker rm redis-restore
```

Ожидается: «перезапись AOF завершена» и прежний `DBSIZE`.

### 5.6 Штатный запуск

```
cd ~/devops-backend
envval() { grep -E "^$1=" .env | cut -d= -f2-; }
export REDISCLI_AUTH="$(envval REDIS_PASSWORD)"
docker compose up -d redis
sleep 3
docker logs redis 2>&1 | grep -iE 'append only file|DB loaded|Ready to accept' | tail -4
echo "DBSIZE: $(docker exec -e REDISCLI_AUTH redis redis-cli --no-auth-warning DBSIZE)"
echo "XLEN мёртвой очереди: $(docker exec -e REDISCLI_AUTH redis redis-cli --no-auth-warning XLEN queue:files:dead)"
unset REDISCLI_AUTH
docker logs --since 3m worker 2>&1 | tail -5
```

Ожидается: в журнале Redis загрузка из AOF (на учении `DB loaded from base file appendonly.aof.1.base.rdb`, `keys loaded: 5`), прежние `DBSIZE` и `XLEN`, worker без повторяющихся ошибок. Пока контейнер `redis` не запущен, worker пишет `Error -3 connecting to redis:6379. Temporary failure in name resolution` каждые 2 с (на учении последняя запись в 05:51:31) и после запуска Redis перезапуска не потребовал. Если worker пишет ошибку про отсутствующую группу или поток, перезапустить его командой `docker compose restart worker` (не проверено).

## 6. Проверка согласованности и возврат автоматики

1. Числа Postgres, MinIO и Redis совпадают с эталоном из шага 2.1.
2. Сверка строк и объектов (VM-1):

```
sudo systemctl start reconcile.service
journalctl -u reconcile -n 20 --no-pager
```

Ожидается: ни `ORPHAN_OBJECT`, ни `MISSING_OBJECT`. Код выхода 10 (`systemctl` при этом пишет `failed`, в журнале `status=10/n/a`) означает «найден рассинхрон», а не поломку самой сверки; четыре известных `STUCK_PENDING` описаны в разделе 7.

3. Сквозная проверка (VM-1): загрузка файла, обработка worker-ом (`"status":"done"` и поле `sha256`), ссылка на скачивание, скачивание по ней, сверка SHA-256 с ответом API, удаление и `404` после него. Скачивание по ссылке заодно доказывает, что приложение входит в MinIO под восстановленным пользователем, а presigned-ссылка работает через nginx. Команды выполнены 2026-10-15 на восстановленной системе после учения.

```
C="curl -sS --cacert $HOME/certs/ca.crt"
printf 'e2e check\n' > /tmp/e2e.txt
$C -F file=@/tmp/e2e.txt https://app.local/api/files > /tmp/e2e-up.json
ID=$(grep -oE '"id":"[^"]+"' /tmp/e2e-up.json | cut -d'"' -f4)
echo "ID=$ID"
sleep 6
$C https://app.local/api/files/$ID > /tmp/e2e-meta.json
grep -oE '"(status|sha256)":"[^"]*"' /tmp/e2e-meta.json
$C https://app.local/api/files/$ID/link > /tmp/e2e-link.json
URL=$(grep -oE '"url":"[^"]+"' /tmp/e2e-link.json | cut -d'"' -f4)
$C -o /tmp/e2e-dl.txt -w 'скачивание по ссылке: %{http_code}\n' "$URL"
API=$(grep -oE '"sha256":"[^"]+"' /tmp/e2e-meta.json | cut -d'"' -f4)
GOT=$(sha256sum /tmp/e2e-dl.txt | cut -d' ' -f1)
$C -X DELETE https://app.local/api/files/$ID
$C -o /dev/null -w 'после DELETE: %{http_code}\n' https://app.local/api/files/$ID
rm -f /tmp/e2e.txt /tmp/e2e-*.json /tmp/e2e-dl.txt
[ -n "$API" ] && [ "$API" = "$GOT" ] && echo "СКВОЗНОЙ ТЕСТ: OK" || { echo "СКВОЗНОЙ ТЕСТ: НЕ ПРОШЁЛ"; exit 1; }
```

Ожидается: `"status":"done"`, `скачивание по ссылке: 200`, `после DELETE: 404` и последняя строка `СКВОЗНОЙ ТЕСТ: OK`.

4. `https://app.local/health` и `/health/deps`: все зависимости `ok`. Аварийные алерты (`/health` 503, `RedisUnavailable`, `CacheBypassed`) снимаются; `ReconcileMismatch` остаётся, пока сверка находит расхождения (раздел 7).
5. Вернуть автоматику на VM-1. После `enable --now` бэкапы и сверка стартуют сразу (на учении в 08:57:14), то есть снимают то состояние, которое есть в эту минуту, поэтому включать только после пунктов 1–4. Именно `enable --now`, а не `start`: `start` не включает автозапуск, и после перезагрузки ВМ бэкапы молча перестали бы идти.

VM-1:

```
sudo systemctl enable --now redis-backup.timer minio-backup.timer reconcile.timer
```

6. Убедиться, что свежие бэкапы VM-1 не пусты, до включения VM-2. `vm1-pull` забирает то, что VM-1 опубликовала как `latest`, а ротация удаляет самые старые копии. Пустая копия проходит сверку по `SHA256SUMS` (она совпадает со своей же пустой суммой), поэтому проверять нужно источник.

VM-1:

```
journalctl -u redis-backup -n 12 --no-pager
journalctl -u minio-backup -n 5 --no-pager
sudo du -shL /var/backups/redis/latest /var/backups/minio/latest
```

Ожидается: у Redis «5 keys read» и «Бэкап проверен восстановлением», у MinIO «Выгрузка вне тома MinIO сверена ... (172 объектов)» и «Бэкап сверен по списку и размерам», размеры около 16K и 226M, не нули.

7. Вернуть автоматику на VM-2, снять свежий дамп и забрать копии с VM-1.

VM-2:

```
sudo systemctl enable --now pg-backup.timer vm1-pull.timer
sudo systemctl start pg-backup.service
sudo systemctl start vm1-pull.service
journalctl -u pg-backup -u vm1-pull -n 25 --no-pager
```

Ожидается: «Бэкап проверен восстановлением» для дампа (строки `files` и `items` как в эталоне) и «сохранена копия ... сверена по SHA256SUMS» для Redis и MinIO.

8. Убрать временное: `~/restore-minio`, `~/restore-redis` на VM-1; `/home/jaha_task_3/restore-minio`, `/home/jaha_task_3/restore-redis`, `/var/lib/postgresql/18/main.lost` на VM-2. Перед `rm -rf` выведите `du -sh` по тем же путям и убедитесь, что удаляется именно это.

## 7. Результаты учения

Учение шло с перерывами 2026-10-12 – 2026-10-14 (разрушение 2026-10-12 11:57 UTC). Общее время не измерялось; время отдельных этапов (UTC):

| Этап | Что выполнено | Время |
|---|---|---|
| Postgres (VM-2) | `initdb` 12:36:41, кластер и `appdb` 12:36:44, `pg_restore` 12:44:03 | 7 мин 22 с от `initdb` до `pg_restore`; сам `pg_restore` 1 с, почти всё время ушло на ручной ввод пароля роли (шаг 3.4 до переписывания) |
| MinIO (VM-1) | перенос копии проверен 05:17:49; пустой MinIO запущен 05:20:04, `healthy` 05:23:29; `mc mirror` 05:36:45 → 05:36:47 (225 MiB) | запуск с паузами между командами (чистое время не измерялось); `mirror` 2 с |
| Redis (VM-1) | снимок в том и временный экземпляр без AOF (5.3–5.4) 05:44:59 → 05:45:00; включение AOF и штатный запуск (5.5–5.6) 05:51:30 → 05:51:32 | 1 с и 2 с |

Сверка с эталоном (шаг 2.1):

- Postgres: `files` done 167, failed 32, pending 4 (всего 203), `items` 2, права `appuser=arwd/postgres`.
- MinIO: 172 объекта, 235931768 байт, `sha256sum -c` без расхождений. Сверка видит 171 (`objects=171 rows=203`), потому что считает только префикс `files/`; 172-й объект это `test/hello.txt`.
- Redis: `DBSIZE` 5, `XLEN queue:files:dead` 0; в журнале Redis при старте загрузка из `appendonly.aof.1.base.rdb`, `keys loaded: 5`.
- Сверка после учения (2026-10-14 06:18:44): `orphan_objects=0 missing_objects=0 stale_pending=0 stuck_pending=4`, код выхода 10. Те же четыре `STUCK_PENDING` (те же `id` и `updated_at`) были до учения (запуск 2026-10-12 11:54:02): из дампа они вернулись без изменений.
- Четыре `STUCK_PENDING` (`cb973de7`, `e4449724`, `ed412c14`, `caed995b`): строки `pending` с пустым `size_bytes`, созданные 2026-10-12 с 10:21:44 по 10:26:18 UTC; их объекты (по 7 байт) лежат в MinIO, то есть объект записан, а строка в `uploaded` не переведена. Сверка и `ReconcileMismatch` показывают их каждые 30 минут. Причина не выяснена: по времени совпадает с опытом 7 (`CHAOS.md`), но дата опыта не сверена.
- `/health` 200, `/health/deps`: `postgres`, `redis`, `minio` в состоянии `ok`.

Что оказалось неточным в черновике (исправлено в тексте разделов 2–6):

1. 4.1 и 5.1: копию нельзя перенести напрямую с VM-2 на VM-1. У VM-1 намеренно нет доступа к VM-2 (бэкапы по pull-модели), `scp` с VM-1 на VM-2 заканчивается `Permission denied (publickey)`. Теперь копия идёт через Mac: `scp -3`.
2. 4.4: контейнер `mc` с `--user 0:0` и `--cap-drop ALL` не читает файлы копии с правами 600 и 700. Теперь контейнер запускается от пользователя, которому принадлежит копия.
3. 3.4: пароль роли нельзя было ввести, не показав его (знает его только `.env.backend`). Шаг переписан: пароль едет файлом через Mac и не печатается. Во время учения этот шаг один раз был пропущен (роль осталась без пароля).
4. Раздел 2: `stop` у таймеров заменён на `disable --now`, потому что при выключении ВМ `stop` не действует.
5. Раздел 6: `start` у таймеров заменён на `enable --now`; добавлен порядок: сначала VM-1 и проверка `latest`, потом VM-2.

Другие находки:

- Бэкап пустого источника публикует пустой `latest` (раздел 8).
- Пароль роли `appuser` попал в чат; заменён 2026-10-15 по процедуре раздела 9.
- После `enable --now` на VM-1 бэкапы и сверка стартовали сразу (2026-10-15 08:57:14). Причину (`Persistent=true`) для таймеров бэкапов не проверяли.

## 8. Что восстановление не покрывает

- Роль `appuser` и пароль не входят в дамп (`pg_dump` одной базы). Пароль хранится только в `.env.backend` на VM-1.
- Политика и пользователь MinIO не входят в копию объектов: шаг 4.3 воссоздаёт их по тексту выше.
- Метаданные объектов (тип содержимого) выгрузка на диск не сохраняет, при загрузке `mc mirror` определит их по расширению (по коду, не проверялось). Тип файла приложение хранит в Postgres.
- Служебный бакет `uploads-backup` внутри MinIO пересоздаётся ближайшим бэкапом.
- Дампы Postgres лежат только на VM-2. Потеря VM-2 вместе с базой уничтожает и дампы.
- Потеря Mac уничтожает обе ВМ.
- RPO равен возрасту последней копии: бэкап запускается раз за включение ВМ (README, «Когда бэкапы запускаются на самом деле»).
- Бэкап пустого или разрушенного источника публикует пустой `latest`, и `vm1-pull` забирает его как свежую копию; со временем ротация вытеснит им хорошие. Поэтому при учении таймеры отключены (раздел 2). Команды 4.1 и 5.1 берут последнюю копию (`sort | tail -1`): это верно, только пока автоматика отключена, иначе выбирайте каталог копии по имени (метка времени до разрушения).
- Код выхода сверки 10 означает «найден рассинхрон», а не «сверка сломалась»; не смогла отработать сверка с кодом 2 (README, «Сверка»).

## 9. Замена пароля `appuser`

Когда: пароль мог попасть в чат, историю команд, журнал или к постороннему (на учении так и было). Процедура выполнена 2026-10-15.

Порядок и почему. Postgres проверяет пароль только при открытии нового соединения: соединения пула, уже открытые, после `ALTER ROLE` продолжают работать, ошибки начинаются, когда приложению нужно новое соединение (пул заменил мёртвое, перезапустился worker). Поэтому сначала меняется роль, сразу после этого `.env.backend` и `./deploy.sh`; шаги 3 и 4 делаются подряд. Обратный порядок не годится: новая версия с новым паролем не пройдёт `/health`, и деплой не переключится (по логике `deploy.sh`, не проверялось).

Пароль не печатается и не попадает в аргументы команд: он генерируется в файл с правами 600, едет на VM-2 через Mac и попадает в `psql` через stdin.

Шаг 1, VM-1:

```
cd ~/devops-backend
( umask 077; openssl rand -hex 24 > ~/newpw )
wc -c ~/newpw
```

Ожидается `49`.

Шаг 2, терминал Mac:

```
scp -3 jahongir@192.168.64.3:newpw jaha_task_3@192.168.64.5:newpw
```

Шаг 3, VM-2 (`sudo -v` отдельной командой перед блоком):

```
chmod 600 ~/newpw
LS=$(sudo -u postgres psql -Atc "show log_statement")
echo "log_statement=$LS"
[ "$LS" = none ] && printf "ALTER ROLE appuser PASSWORD '%s';\n" "$(cat ~/newpw)" | sudo -u postgres psql -d appdb -v ON_ERROR_STOP=1
```

Ожидается `log_statement=none` и `ALTER ROLE`. Если `log_statement` не `none`, Postgres записал бы пароль в свой журнал: дальше не идти.

Шаг 4, VM-1, сразу после шага 3:

```
cd ~/devops-backend
install -m 600 .env.backend ~/env.backend.old
grep -c '^DATABASE_URL=' .env.backend
sed -E -i "s#^(DATABASE_URL=[^:]+://[^:/]+:)[^@]+(@)#\1$(cat ~/newpw)\2#" .env.backend
[ "$(grep '^DATABASE_URL=' .env.backend | sed -E 's#.*://[^:]+:([^@]+)@.*#\1#')" = "$(cat ~/newpw)" ] && echo "env: совпал" || echo "env: НЕ совпал"
grep '^DATABASE_URL=' .env.backend | sed -E 's#(://[^:]+:)[^@]+@#\1***@#'
./deploy.sh
```

Ожидается `1`, `env: совпал`, строка `DATABASE_URL` с `***` вместо пароля и «Деплой завершён успешно». Если `НЕ совпал`, `./deploy.sh` не запускать.

Шаг 5, VM-1:

```
curl -sS --cacert ~/certs/ca.crt -o /dev/null -w 'health: %{http_code}\n' https://app.local/health
curl -sS --cacert ~/certs/ca.crt https://app.local/health/deps; echo
docker compose ps
docker compose logs --tail 15 worker
```

Ожидается `200`, три `ok`, все контейнеры `Up`, в логе worker нет `password authentication failed`. Затем сквозная проверка из раздела 6, пункт 3.

Шаг 6, когда проверка прошла: удалить файлы с паролем. VM-1: `rm -f ~/newpw ~/env.backend.old`. VM-2: `rm -f /home/jaha_task_3/newpw`, затем `hostname` и `ls -l /home/jaha_task_3/newpw` (ожидается `task3test` и «No such file»). 2026-10-15 команду удаления для VM-2 по ошибке выполнили на VM-1, и файл с паролем на VM-2 остался до проверки.

Осторожно: `docker compose up` без `-d` привязывает терминал к логам, и `Ctrl+C` останавливает все контейнеры проекта (случай 2026-10-15, `CHAOS.md`). Статус смотрят командой `docker compose ps`. Если остановка всё же случилась, политика `unless-stopped` сама не поднимет вручную остановленные контейнеры. Нужно удалить пересозданный лишний неактивный цвет (`docker rm backend-blue`) и запустить по порядку, nginx последним:

```
docker start redis minio
docker start backend-green worker
docker start nginx
```

`backend-green` это активный цвет на 2026-10-15; активный цвет печатает `./deploy.sh`.
