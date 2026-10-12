# RUNBOOK: восстановление Postgres, MinIO и Redis из бэкапов

Документ для случая, когда данные одного, двух или всех трёх хранилищ потеряны (том пуст или удалён, база не стартует), а сами ВМ, Docker, репозиторий, `.env`, `~/certs` и systemd-таймеры целы.
Шаги проверены на учении (раздел «Результаты учения»). Пометка `(не проверено)` означает шаг, который на учении не выполнялся.

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

Автоматика остаётся включённой, но при учении она опасна: бэкап по таймеру, запущенный на пустом хранилище, снимет пустую копию и сдвинет ротацию.

VM-1:

```
sudo -v
```
```
sudo systemctl stop redis-backup.timer minio-backup.timer reconcile.timer
systemctl list-timers --all --no-legend | grep -E 'redis-backup|minio-backup|reconcile' || echo "таймеры остановлены"
```

VM-2:

```
sudo -v
```
```
sudo systemctl stop pg-backup.timer vm1-pull.timer
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

### 3.2 Создать пустой кластер (не проверено)

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

### 3.4 Роль `appuser` (не проверено)

Роли хранятся на уровне кластера, `pg_dump appdb` их не включает. Пароль должен совпасть с паролем в `DATABASE_URL` из `.env.backend` на VM-1. Вводится в терминале, без эха, в чат и в историю не попадает.

```
sudo -u postgres psql -c "CREATE ROLE appuser LOGIN"
sudo -u postgres psql
```

В открывшейся консоли `psql`:

```
\password appuser
\q
```

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

VM-1 (пароль пользователя `jaha_task_3` вводится вручную):

```
rm -rf ~/restore-minio
scp -r jaha_task_3@192.168.64.5:restore-minio ~/restore-minio
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

```
cd ~/devops-backend
envval() { grep -E "^$1=" .env | cut -d= -f2-; }
IMAGE=$(docker inspect minio --format '{{.Config.Image}}')
export MC_HOST_exp="http://$(envval MINIO_ROOT_USER):$(envval MINIO_ROOT_PASSWORD)@minio:9000"
docker run --rm --network app-net --user 0:0 --read-only --tmpfs /tmp \
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
scp -r jaha_task_3@192.168.64.5:restore-redis ~/restore-redis
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

### 5.3 Положить снимок в пустой том (не проверено)

```
IMAGE=$(docker inspect redis --format '{{.Config.Image}}')
docker run --rm --user 0:0 --entrypoint sh -v redis-data:/data -v "$HOME/restore-redis:/src:ro" "$IMAGE" \
  -c 'cp /src/redis-*.rdb /data/dump.rdb && chown redis:redis /data/dump.rdb && chmod 600 /data/dump.rdb && ls -la /data'
```

Ожидается: `dump.rdb` с владельцем `redis redis` и правами `-rw-------`.

### 5.4 Временный экземпляр без AOF (не проверено)

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

Ожидается: в журнале Redis загрузка из AOF, прежние `DBSIZE` и `XLEN`, worker без повторяющихся ошибок. Если worker пишет ошибку про отсутствующую группу или поток, перезапустить его командой `docker compose restart worker` (не проверено).

## 6. Проверка согласованности и возврат автоматики

1. Числа Postgres, MinIO и Redis совпадают с эталоном из шага 2.1.
2. Сверка строк и объектов (VM-1):

```
sudo systemctl start reconcile.service
journalctl -u reconcile -n 20 --no-pager
```

Ожидается: ни `ORPHAN_OBJECT`, ни `MISSING_OBJECT`.

3. Сквозная проверка (не проверено: команды загрузки и скачивания взять из README): загрузить новый файл, скачать по ссылке, сверить SHA-256.
4. `https://app.local/health` и `/health/deps` — все зависимости `ok`; в Prometheus аварийные алерты снялись.
5. Вернуть автоматику.

VM-1:

```
sudo systemctl start redis-backup.timer minio-backup.timer reconcile.timer
```

VM-2:

```
sudo systemctl start pg-backup.timer vm1-pull.timer
```

6. Снять новые бэкапы восстановленного состояния (шаг 2.2) и убедиться, что `.last-success` обновились.
7. Убрать временное: `~/restore-minio`, `~/restore-redis` на VM-1; `/home/jaha_task_3/restore-minio`, `/home/jaha_task_3/restore-redis`, `/var/lib/postgresql/18/main.lost` на VM-2.

## 7. Результаты учения

ЗАПОЛНИТЬ ПОСЛЕ УЧЕНИЯ

## 8. Что восстановление не покрывает

- Роль `appuser` и пароль не входят в дамп (`pg_dump` одной базы). Пароль хранится только в `.env.backend` на VM-1.
- Политика и пользователь MinIO не входят в копию объектов: шаг 4.3 воссоздаёт их по тексту выше.
- Метаданные объектов (тип содержимого) выгрузка на диск не сохраняет, при загрузке `mc mirror` определит их по расширению (по коду, не проверялось). Тип файла приложение хранит в Postgres.
- Служебный бакет `uploads-backup` внутри MinIO пересоздаётся ближайшим бэкапом.
- Дампы Postgres лежат только на VM-2. Потеря VM-2 вместе с базой уничтожает и дампы.
- Потеря Mac уничтожает обе ВМ.
- RPO равен возрасту последней копии: бэкап запускается раз за включение ВМ (README, «Когда бэкапы запускаются на самом деле»).
