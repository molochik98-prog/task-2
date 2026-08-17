## Проблема 1: Connection refused при подключении из контейнера к Postgres

**Симптом:** `psycopg2.OperationalError: connection to sserver at "172.17.0.1", port 5432 faild: Connection refused`

**Как искал:** ошибка "refused" (а не timeout) означала, что пакет дошел до хоста, 
но порт там закрыт для этого адреса. Проверил `listen_addresses = postgresql.conf` и `ss -tulnp | grep 5432` -
 Postgres слушал только `127.0.0.1`.

**Причина:** `listen_addresses = 'localhost'` (дефолт) - сокет открыт только на loopback, а контейнер стучится через
 IP шлюза docker-моста (172.17.0.1), это не тоже самое, что localhost хоста.

**Фикс:** `listen_addresses = 'localhost,172.17.0.1'` в postgresql.conf, затем `systemctl restart postgresql`
(не reload - это настройка меняет сам список открываемых сокетов).


## Проблема 2: Postgres откланяет подключение - нет записи в pg_hga.conf

**Симптомы:** `FATAL: no pg_hba.conf entry for host "172.17.0.3", user "appuser", database "appdb", SSL encryption`

**Как искал:** заметил что ошибка изменилась по сравнению с прошлой - это уже не "Connection refused", а FATAL с явным 
тестом про pg_hba.conf. Значит, TCP-уровень пройден, проблема сместилась с "слушает ли Postgres" на "пускает ли Postgres".
 Проверил pg_hba.conf — в нём были только записи под 127.0.0.1/32 и ::1/128, записи под docker-подсеть не было вообще.
 Две строчки в самой ошибке (SSL / no encryption) — не два отдельных диагноза, а одна причина: psycopg2 сам пробует
 сначала зашифрованное соединение, потом откатывается на незашифрованное, и оба раза получает один и тот же отказ.

**Причина:** в ошибке 172.17.0.3, а не 172.17.0.1 это не опечатка и не баг — важный концептуальный момент. 172.17.0.1 в моем 
DATABASE_URL — это адрес назначения (куда стучимся). А pg_hba.conf матчит совсем другое поле — адрес источника, 
то есть с какого IP пришёл клиент. Docker при старте контейнера в дефолтной bridge-сети сам назначил ему динамический адрес
`(.2 уже занят другим контейнером — помнишь devops-app в выводе docker ps? — поэтому новому достался .3)`.
То есть Postgres корректно увидел, кто на самом деле стучится, и именно этого адреса нет в списке разрешённых.

**Фикс:** добавил в конец `pg_hba.conf`:
`sudo nano /etc/postgresql/18/main/pg_hba.conf`
Добавляешь в конец файла:
`host    appdb           appuser         172.17.0.0/16           scram-sha-256`
Применил через `sudo systemctl reload postgresql`.


## Проблема 3: Порт 80 занят нативным nginx

**Симтом:** `faild to bind host port 0.0.0.0:80/tcp: address already in use`

**Как искал:** Ключивая улика находится в самом низу вывода ss -tulpn:
`tcp LISTEN 0 511 0.0.0.0:80...users:(("nginx",pid=1219,fd=5),("nginx",pid=1218,fd=5),...)`

**Причина:** Порт :80 уже занимал нативный `nginx`- systemd-сервис, установленный на ВМ (`apt install nginx`) до этого задания,
никак не связан с контейнером devops-app с первого задания (тот был на порту 8080).

**Фикс:** `sudo systemctl stop nginx`
          `sudo systemctl disable nginx`
Звтем пересоздал Docker контейнер:
`docker rm nginx`
`docker run -d --name nginx --network app-net \`
`-p 80:80 \`
`-v ~/devops-backend/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \`
`nginx:alpine`


## Проблема 4: Опечатка в конфиге

**Симптом:** Конфиг не запустился.`unknown "backend_upstrem" variable`

**Как искал:** сравнил строки `set $backend_upstream backend:8000;` и `proxy pass http://$backend_upstem;`
Имена не совпадают на одну букву "а".

**Причина:** `backend_upstream` в set и `backend_upstrem` в proxy_pass - не совпадают не хватает одной `а`.

**Фикс:** `set $backend_upstream backend:8000;`
           proxy pass http://$backend_upstream;


## Проблема 5: Postgres не слушает адрес app-net

**Симптом:** `tcp LIISTEN 0 200 127.0.0.1:5432...users:(("postgres",pid=1290,fd=6))`

**Как искал:** Тут сверяюсь с фактами, которые уже есть на экране. В файле `pg_hba.conf` добавил `172.19.0.0/16`(кого пускать),
но `listen_addresses`(на чем слушать) с тех пор не трогал - а это независимые шаги, Смотрю на ss:
`tcp LISTEN 0 200 127.0.0.1:5432 ... users:(("postgres",pid=1290,fd=6))`

**Причина:** Только 127.0.0.1 - даже 172.17.0.1, который добавил раньше, сейчас не виден, из за того что ВМ перезагружалась 
между сессиями. Раз `backend` стучится на 172.19.0.1 - Postgres там сейчвс не слушает, в следствии та же ошибка `Connection refuseed`,
что и на первом шаге, просто с новым адресом.

**Фикс:** `sudo nano /etc/postgresql/18/main/postgresql.conf`
          # listen_addresses = 'localhost,172.19.0.1' 
          
          sudo systemctl restart postgresql

