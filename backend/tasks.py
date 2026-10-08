"""Очередь задач на Redis Streams: константы, producer, статистика."""
import logging
import os
import redis

STREAM = "queue:files"
GROUP = "workers"
DEAD = "queue:files:dead"
NAIVE = "queue:naive"  # только для опыта 4.1, в рабочем режиме не используется

log = logging.getLogger("uvicorn.error")


def make_client(socket_timeout, max_connections=64):
    pool = redis.ConnectionPool(
        host=os.environ.get("REDIS_HOST", "redis"),
        port=6379,
        password=os.environ.get("REDIS_PASSWORD"),
        socket_connect_timeout=1,
        socket_timeout=socket_timeout,
        max_connections=max_connections,
        decode_responses=True,
    )
    return redis.Redis(connection_pool=pool)


_producer = make_client(0.5)


def enqueue(file_id):
    """Поставить задачу. Сбой Redis не ломает загрузку: файл остаётся `uploaded`, сторож в worker подберёт."""
    try:
        _producer.xadd(STREAM, {"file_id": str(file_id)})
        return True
    except redis.RedisError as exc:
        log.warning("enqueue failed for %s: %s (sweeper will re-enqueue)", file_id, exc)
        return False


def _ts(msg_id):
    return int(msg_id.split("-")[0])


def stats(r):
    """waiting = ещё не выданы, pending = выданы, но не подтверждены, oldest_age_s = возраст самой старой."""
    sec, usec = r.time()
    now_ms = sec * 1000 + usec // 1000
    out = {"waiting": 0, "pending": 0, "oldest_age_s": 0.0, "dead": r.xlen(DEAD), "naive_list": r.llen(NAIVE)}
    try:
        groups = r.xinfo_groups(STREAM)
    except redis.ResponseError:
        groups = []
    g = next((x for x in groups if x["name"] == GROUP), None)
    candidates = []
    if g:
        out["pending"] = g["pending"]
        undelivered = r.xrange(STREAM, min="(" + g["last-delivered-id"], max="+", count=100000)
        out["waiting"] = len(undelivered)
        if undelivered:
            candidates.append(_ts(undelivered[0][0]))
        if g["pending"]:
            summary = r.xpending(STREAM, GROUP)
            if summary.get("min"):
                candidates.append(_ts(summary["min"]))
    else:
        out["waiting"] = r.xlen(STREAM)
        first = r.xrange(STREAM, min="-", max="+", count=1)
        if first:
            candidates.append(_ts(first[0][0]))
    if candidates:
        out["oldest_age_s"] = max(0.0, (now_ms - min(candidates)) / 1000)
    return out
