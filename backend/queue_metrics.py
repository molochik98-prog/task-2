"""Метрики с внешними источниками (очередь, bucket, сверка). Считаются в фоновых потоках, при
скрапе только читаются готовые числа: недоступный Redis или MinIO не вешает /metrics."""
import json
import logging
import threading
import time

from prometheus_client import Gauge

import storage
import tasks

log = logging.getLogger("uvicorn.error")
NAN = float("nan")
_redis = tasks.make_client(0.5, max_connections=4)
_state = {"queue": None, "storage": None, "reconcile": None}
_started = False


def _refresh(name, fn):
    try:
        _state[name] = fn()
    except Exception as exc:
        log.warning("metrics source %s unavailable: %s", name, exc)
        _state[name] = None


def _storage():
    objects = size = 0
    for obj in storage.list_objects("files/"):
        objects += 1
        size += obj.size or 0
    return {"objects": objects, "bytes": size}


def _reconcile():
    raw = _redis.get("reconcile:last")
    return json.loads(raw) if raw else None


def _fast_loop():
    while True:
        _refresh("queue", lambda: tasks.stats(_redis))
        _refresh("reconcile", _reconcile)
        time.sleep(10)


def _slow_loop():
    while True:
        _refresh("storage", _storage)
        time.sleep(60)


def start():
    global _started
    if _started:
        return
    _started = True
    for fn in (_fast_loop, _slow_loop):
        threading.Thread(target=fn, daemon=True).start()


def _g(name, doc, source, key):
    def read():
        data = _state[source]
        return float(data[key]) if data and key in data else NAN
    Gauge(name, doc).set_function(read)


_g("queue_waiting_tasks", "Tasks not yet delivered to a worker", "queue", "waiting")
_g("queue_inflight_tasks", "Tasks delivered but not acknowledged", "queue", "pending")
_g("queue_oldest_task_age_seconds", "Age of the oldest unfinished task", "queue", "oldest_age_s")
_g("queue_dead_tasks", "Tasks in the dead-letter queue", "queue", "dead")
_g("bucket_objects", "Objects under files/ in the bucket", "storage", "objects")
_g("bucket_bytes", "Total size of objects under files/", "storage", "bytes")
_g("reconcile_last_run_timestamp_seconds", "Unix time of the last successful reconcile", "reconcile", "ts")
_g("reconcile_last_mismatches", "Mismatches found by the last reconcile", "reconcile", "mismatches")
Gauge("queue_stats_up", "1 if queue statistics could be read from Redis").set_function(
    lambda: 0.0 if _state["queue"] is None else 1.0
)
