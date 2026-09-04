# Task 2 - Backend + PostgreSQL + nginx

Бэкенд на FastAPI, читает данные из PostgreSQL (установлен на хосте, не в Docker),
за nginx-прокси. Деплой - через GitHub Actions на self-hosted runner.

## Архитектура


```
Внешний клиент
       |
       |:80(единственный порт открытый наружу)
       v
+---------------------Host (VM)-----------------------+
|                                                     |
|+-----------------app-net (docker)------------------+|
||                                                   ||
||nginx:80---DNS:backend:8000--->backend:8000        ||
||(публикует -p 80:80) (без -p, не наружу)           ||
||                                                   ||
|+---------------------------------------------------+|
|                       |                             |
|                       |172.19.0.1:5432              |
|                       v                             |
|                   PosctgreSQL                       |
|        (apt-пакет на хосте, не в Docker)            |
|  слушает:127.0.0.1,172.19.0.1(не внешний интерфейс) |
|                                                     |
+-----------------------------------------------------+
```


|Компонент   |Порт    |Кому виден                                                              |
|------------|--------|------------------------------------------------------------------------|
|nginx       |80      |снаружи (весь мир)                                                      |
|backend     |8000    |только внутри 'app-net', наружу не публикуется                          |
|PostgreSQL  |5432    |только '127.0.0.1' и '172.19.0.1' (docker мост), наружу не публикуется  |
|SSH         |22      |снаружи - администротивный доступ, не относится к приоржению            |


## Как задеплоить

Автоматически: push в 'main' -> GitHub Actions на self-hosted runner сам:
1. Собирает образ бэкенда с тегом `backend:<commit-sha>`
2. Останавливает и удаляет старый контейнер `backend`
3. Запускает новый в сети `app-net`, без публикации порта
4. Проверяет `/health' с ретраями (10 попыток по 3 сек) - если не поднялся, workflow падает

Пороль базы передается через `DATABASE_URL`, знаение приходит через GitHub Secrets `DB_PASSWORD`-
нигде в коде или истории коммитов не хранится.

**nginx в автодеплой не входит** - это осознанное решение: конфиг монтируется, как volume в обычный
`nginx:alpine`, а не собирается в отдельный образ. Если меняешь `nginx/nginx.conf`- нужно вручную:
```bash
docker stop nginx && docker rm nginx
docker run -d --name nginx --network app-net -p 80:80 \
    -v ~/devops-backend/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
    nginx:alpine
```

### Первоначальная настройка (уже сделана, для справки)
- PostgreSQL: пользоватеть `appuser`, база `appdb`, `listen_addresses` включает `172.19.0.1`,
                           `pg_hba.conf` разрешает подсеть 172.19.0.0/16
- Docker-сеть: `docker network create app-net`
- Секрет `DB_PASSWORD` - в Settings -> Secrets and variables -> Actions
- Self-hosted runner - зарегестрирован отдельно для этого репозитория (Settings -> Actions -> Runners)


## Как откатить

Образы тегированы SHA коммита, а не `latest` - именно для этого. Прошлые версии остаются на на ВМ и
никуда не пропадают при новом деплое.

Посмотреть, какие версии есть локально:
```bash
docker image | grep backend
```
Откатиться на конкретную версию:
```bash
docker stop backend && docker rm backend
docker run -d --name backend --network app-net \
    -e DATABASE_URL="postgresql://appuser:${DB_PASSWORD}@172.19.0.1:5432/appdb" \
    backend:<нужный sha>
```

Это быстрее чем откатывать сам код и ждать новую сборку - тот самый смысл SHA-тегов, а не `latest`.


# DevOps Backend Stack — README

## Что это

Учебный проект (Задание 3, стажировка DevOps): backend + nginx на одном хосте,
PostgreSQL — на втором, полная TLS-цепочка между всеми компонентами,
zero-downtime деплой через blue/green, контейнеры с минимальными привилегиями,
весь стек под systemd-управлением с бэкапом БД и алертингом.

## Архитектура

```
VM-1 (192.168.64.3)                                    VM-2 (192.168.64.5, task3test)
--------------------                                    ------------------------------
Docker network app-net (172.19.0.0/16)                  PostgreSQL 18
                                                          - привязан к private IP
  nginx  --TLS :443, 80->443--                           - hostssl-only
    |                                                     - UFW: разрешён только VM-1
    | resolver 127.0.0.11 valid=10s
    | proxy_pass http://$backend_upstream
    | $backend_upstream = backend-<color>:8000
    v
  backend-blue   ИЛИ   backend-green    ---- TLS (sslmode=verify-full) ---->  Postgres
  (активен только один из двух)

  Весь стек (обе VM) под systemd: crash-recovery + переживает реальный ребут,
  подтверждено на практике, не только в теории.
```

TLS построен на кастомном CA (`ca.crt`) с корректными SAN-полями
(`DNS:app.local`, `DNS:db`). CN сознательно не используется — современные
клиенты его игнорируют (RFC 6125), проверка идёт по SAN.

## Docker-хардненинг

| | До | После |
|---|---|---|
| Сборка образа | обычная | multi-stage build |
| Пользователь в контейнере | root | non-root `appuser` |
| Размер образа | 260 MB | 247 MB |
| Рантайм-флаги (backend) | — | `--read-only --cap-drop ALL` |

> TODO(Jahongir): вписать одной строкой, за счёт какого именно шага multi-stage
> ужалось 260 → 247 MB.

Хардненинг проверен не в теории, а прогоном реального стека с
`--read-only --cap-drop ALL`, отдельно подтверждено поведение при OOM.

**Известная асимметрия (см. TROUBLESHOOTING):** у `nginx`-контейнера сейчас
нет `--read-only`/`--cap-drop ALL` — в отличие от backend. Осознанно не
исправлено к моменту сдачи, задокументировано как техдолг.

## Zero-downtime деплой (blue/green)

Два контейнера backend (`backend-blue`, `backend-green`). Активный выбирается
одной строкой в `nginx.conf`:

```
set $backend_upstream backend-<color>:8000;
```

nginx резолвит DNS каждого апстрима динамически (`resolver 127.0.0.11 valid=10s`),
поэтому переключение — это правка конфига + `nginx -t` + `nginx -s reload`,
без пересоздания nginx-контейнера.

Единственный источник правды о текущем активном цвете — сам `nginx.conf`
(не отдельный state-файл): `deploy.sh` каждый раз вычисляет его через `grep -oP`.

### Результат нагрузочного теста

Деплой запущен на 15-й секунде 60-секундного теста под нагрузкой
(`wrk -t2 -c50 -d60s --latency https://app.local/items`):

```
Latency:   50% 141ms | 75% 164ms | 90% 191ms | 99% 240ms
Requests:  20338 total, 338.67 req/s
Socket errors: connect 0, read 9, write 0, timeout 0
Non-2xx/3xx: 0
```

Распределение статусов: 20335×200, 49×499 (обрывы соединений клиентом `wrk`
при завершении теста, к деплою отношения не имеют).

**Ноль 502/504 при деплое посреди нагрузки — воспроизведено дважды подряд.**

## Эксплуатационная устойчивость (пункт 6)

### systemd-управление стеком

`backend.service` и `nginx.service` (VM-1) держат весь стек живым:

- **crash-recovery** — `Type=simple` + `docker start -a <container>`:
  если контейнер падает, systemd видит ненулевой код выхода и перезапускает
  (`Restart=on-failure`). Проверено вручную (`docker kill backend-blue`) —
  контейнер поднялся сам за ~5 секунд.
- **переживает реальный ребут VM** — не гипотеза, проверено `sudo reboot`
  на обеих VM: после перезагрузки весь стек поднимается без единой ручной
  команды, `curl --cacert ca.crt https://app.local/health` отвечает сразу
  после переподключения по SSH.
- `backend.service` не хранит активный цвет сам — определяет его тем же
  способом, что и `deploy.sh` (чтение из `nginx.conf`), чтобы не заводить
  второй источник правды.
- `nginx.service` зависит от `backend.service` через `Wants=`, не
  `Requires=` — мягкая зависимость, потому что nginx с динамическим
  resolver'ом переживает временное отсутствие backend'а и сам
  перерезолвит DNS.

### Backup БД

`pg-backup.timer` (VM-2, ежедневно в 03:00) → `pg-backup.sh`:

- `pg_dump -Fc` (custom-формат) локально через Unix-сокет (peer auth,
  без TCP/TLS)
- ротация: держит последние 7 дампов
- **проверка восстановления не опциональна** — каждый прогон сразу
  накатывает свежий дамп в одноразовую scratch-БД (`pg_restore`) и удаляет
  её; непроверенный бэкап не считается успешным

### Алертинг

`health-alert.timer` (VM-1, каждые 5 минут) → `health-alert.sh` →
Telegram-бот:

- проверка `/health` через `curl --cacert`
- проверка использования диска (`df`), порог 85%
- секреты бота (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`) — в
  `/etc/telegram-alert.env` (права `600`, **не в git**, читается только
  самим systemd до понижения привилегий)

Известное упрощение: алерт шлётся при каждом срабатывающем запуске, без
дедупликации состояния (нет отдельного алерта только "на переход
ok→плохо" — повторяется каждые 5 минут, пока проблема не устранена).

## Известное ограничение (не блокер, задокументировано)

`main.py` открывает новое соединение к Postgres на каждый запрос
(`psycopg2.connect(DATABASE_URL)`, без пула) — источник стабильных ~145ms
задержки на каждый запрос (полный TCP+TLS+auth хендшейк каждый раз).
Не влияет на результат пункта 5, но следующий шаг для продакшн-качества —
connection pool (`psycopg2.pool` или переход на `asyncpg`/SQLAlchemy с пулом).

Дополнительные известные артефакты/техдолг — см. `TROUBLESHOOTING.md`.

## Структура репозитория

```
~/devops-backend/
├── nginx/nginx.conf         # single-file bind-mount в контейнер nginx
├── deploy.sh                # blue/green деплой
├── run_deploy_test.sh       # оркестратор нагрузочного теста
├── current-color.sh         # определение активного цвета (используется systemd)
├── systemd/                 # копии unit-файлов для версионирования
│   ├── backend.service      # деплоится в /etc/systemd/system/ на VM-1
│   ├── nginx.service        # деплоится в /etc/systemd/system/ на VM-1
│   ├── health-alert.service # деплоится в /etc/systemd/system/ на VM-1
│   └── health-alert.timer   # деплоится в /etc/systemd/system/ на VM-1
├── scripts/
│   └── health-alert.sh      # деплоится в /usr/local/bin/ на VM-1
├── db-backup/                # относится к VM-2, хранится здесь для единой истории
│   ├── pg-backup.sh          # деплоится в /usr/local/bin/ на VM-2
│   ├── pg-backup.service     # деплоится в /etc/systemd/system/ на VM-2
│   └── pg-backup.timer       # деплоится в /etc/systemd/system/ на VM-2
├── .github/workflows/deploy.yml  # устаревший CI-артефакт, см. TROUBLESHOOTING
├── README.md
├── RUNBOOK.md
├── TROUBLESHOOTING.md
└── NETNS-LAB.md             # пункт 4: netns/bridge/veth/MASQUERADE/DNAT
```

**Не в репозитории (и не должно быть):** `~/certs/` (приватные ключи TLS —
физически лежит вне репозитория, так и должно оставаться),
`/etc/telegram-alert.env` (секреты Telegram-бота), файлы `*.dump`
(дампы БД).
