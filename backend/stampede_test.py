"""Опыт со stampede: 200 одновременных GET за ключом, которого нет в кеше.
Запуск внутри контейнера: python stampede_test.py <file_id>
Загрузка из БД замедляется флаг-файлом (имитация тяжёлого запроса), чтобы все
промахи были одновременными. Потолок "до" = размер пула потоков (40), а не 200."""
import http.client
import os
import sys
import threading
import time
import urllib.request

import cache

N = 200
DELAY_MS = 200
HOST, PORT = "localhost", 8000
DELAY_FLAG = os.environ.get("LOAD_DELAY_FLAG", "/var/uploads-tmp/LOAD_DELAY_MS")


def metric(name):
    body = urllib.request.urlopen(f"http://{HOST}:{PORT}/metrics", timeout=5).read().decode()
    for line in body.splitlines():
        if line.startswith(name + " "):
            return float(line.split()[1])
    return 0.0


def rm(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def run(file_id, singleflight):
    if singleflight:
        rm(cache.FLAG)
    else:
        open(cache.FLAG, "w").close()
    cache.invalidate(f"file:{file_id}")
    loads0, errs0 = metric("file_db_loads_total"), metric("cache_errors_total")
    statuses, lock, barrier = [], threading.Lock(), threading.Barrier(N)

    def worker():
        barrier.wait()
        c = http.client.HTTPConnection(HOST, PORT, timeout=30)
        c.request("GET", f"/api/files/{file_id}")
        r = c.getresponse()
        r.read()
        with lock:
            statuses.append(r.status)

    threads = [threading.Thread(target=worker) for _ in range(N)]
    t0 = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    dt = time.time() - t0
    return (int(metric("file_db_loads_total") - loads0),
            int(metric("cache_errors_total") - errs0), statuses.count(200), dt)


def main():
    file_id = sys.argv[1]
    with open(DELAY_FLAG, "w") as f:
        f.write(str(DELAY_MS))
    try:
        for sf in (False, True):
            loads, errs, ok, dt = run(file_id, sf)
            label = "С  single-flight" if sf else "БЕЗ single-flight"
            print(f"{label}: запросов {N}, ответов 200: {ok}, ушло в Postgres: {loads}, "
                  f"ошибок кеша: {errs}, время {dt:.2f}s")
            if errs:
                print("  ВНИМАНИЕ: кеш выдавал ошибки, этот прогон невалиден")
            if not sf:
                time.sleep(6)  # выключатель кеша (5 с) должен успеть закрыться
    finally:
        rm(cache.FLAG)
        rm(DELAY_FLAG)


main()
