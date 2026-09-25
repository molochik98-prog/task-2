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

Все три сервиса (`backend-blue`, `backend-green`, `nginx`) описаны в одном
`docker-compose.yml` — общие для обоих цветов настройки (`read_only`,
`cap_drop`, `env_file`, монтирование сертификата) заданы один раз через
YAML-якорь `x-backend-common`, а не дублируются. Секрет (`DATABASE_URL`)
живёт в `.env.backend` (вне git), читается через `env_file`.

**Принцип, нарушение которого уже дважды роняло сервис на практике:**
у всех трёх сервисов в compose стоит `restart: "no"` — перезапуском при
падении занимается не Docker, а systemd (`backend.service`/`nginx.service`).
Поэтому любое управление жизненным циклом контейнеров под systemd-
супервизией — **только через `systemctl`**, никогда напрямую
`docker restart`/`stop`/`kill` в обход юнита: см. инцидент в
`TROUBLESHOOTING.md`.

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

### deploy.sh и docker-compose

Новый цвет собирается и поднимается через compose:
```bash
docker compose build backend-$COLOR
docker compose up -d --no-deps backend-$COLOR
```
Старый цвет убирается напрямую через `docker stop`/`docker rm`, не через
`docker compose stop`/`rm` — сознательное решение: compose управляет только
контейнерами со своими лейблами (`com.docker.compose.*`), а гарантии, что
удаляемый контейнер был создан именно через compose, нет (на практике
несколько раз оказывалось не так). Голый `docker stop`/`rm` по имени
работает одинаково независимо от происхождения контейнера.

**Финальный, обязательный шаг** после переключения и уборки старого цвета:
```bash
sudo systemctl restart backend.service
```
`backend.service` фиксирует, какой контейнер супервизировать, только в
момент собственного запуска (`ExecStartPre` читает `nginx.conf` один раз) —
сам свап цвета он не отслеживает. Без этого шага юнит остаётся присоединён
к только что удалённому контейнеру.

### nginx тоже под compose

`nginx` мигрирован на compose так же, как backend. Правка `nginx.conf` для
переключения активного цвета по-прежнему идёт через безопасный
`sed ... > tmp && cat tmp > nginx.conf` (не `sed -i`, не `docker restart` —
см. `TROUBLESHOOTING.md`), затем `nginx -t` + `nginx -s reload` внутри уже
работающего контейнера — сам контейнер не пересоздаётся при обычном
деплое.

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

## Доступ

SSH на VM-2 — только по ключу, вход по паролю отключён
(`PasswordAuthentication no` в `/etc/ssh/sshd_config.d/50-cloud-init.conf` —
именно там, не в основном `sshd_config`, см. `TROUBLESHOOTING.md`). UFW на
VM-2 сужен: порт 22 открыт только из подсети `192.168.64.0/24`, не отовсюду.

## Известное ограничение (не блокер, задокументировано)

`main.py` открывает новое соединение к Postgres на каждый запрос
(`psycopg2.connect(DATABASE_URL)`, без пула) — источник стабильных ~145ms
задержки на каждый запрос (полный TCP+TLS+auth хендшейк каждый раз).
Не влияет на результат пункта 5, но следующий шаг для продакшн-качества —
connection pool (`psycopg2.pool` или переход на `asyncpg`/SQLAlchemy с пулом).

### Мониторинг-стек не под systemd-супервизией

`prometheus`/`grafana`/`cadvisor`/`node-exporter` не переживают падение
и не поднимаются сами при ребуте VM — в отличие от backend/nginx.
Обнаружено: весь стек лежал `Exited` шесть дней подряд незамеченным.
Не исправлено, задокументировано как техдолг.

Дополнительные известные артефакты/техдолг — см. `TROUBLESHOOTING.md`.

## Структура репозитория

```
~/devops-backend/
├── nginx/nginx.conf         # single-file bind-mount в контейнер nginx
├── deploy.sh                # blue/green деплой через docker compose
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
├── docker-compose.yml       # описывает backend-blue/backend-green/nginx
├── .env.backend              # DATABASE_URL, вне git
└── NETNS-LAB.md             # пункт 4: netns/bridge/veth/MASQUERADE/DNAT
```

**Не в репозитории (и не должно быть):** `~/certs/` (приватные ключи TLS —
физически лежит вне репозитория, так и должно оставаться),
`/etc/telegram-alert.env` (секреты Telegram-бота), файлы `*.dump`
(дампы БД).
