"""Worker: считает SHA-256, размер и тип файла, пишет результат в Postgres.

WORKER_MODE=streams (по умолчанию): Redis Streams + consumer group, подтверждение после
записи результата, возврат зависших задач, лимит доставок, мёртвая очередь.
WORKER_MODE=naive: список + BRPOP, без подтверждения. Только для опыта 4.1.
"""
import hashlib
import logging
import os
import signal
import socket
import time

import redis

import cache
import db
import storage
import tasks

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s worker %(message)s")
log = logging.getLogger("worker")

MODE = os.environ.get("WORKER_MODE", "streams")
CONSUMER = socket.gethostname()
DELAY = float(os.environ.get("PROCESS_DELAY_S", "0"))  # имитация тяжёлой обработки, для опытов
MIN_IDLE_MS = int(float(os.environ.get("MIN_IDLE_S", "60")) * 1000)  # должно быть больше времени обработки
MAX_DELIVERIES = int(os.environ.get("MAX_DELIVERIES", "3"))
RECOVER_EVERY = 5
SWEEP_EVERY = 60
STOP = False

MAGIC = [
    (b"\x89PNG\r\n\x1a\n", "image/png"), (b"\xff\xd8\xff", "image/jpeg"), (b"GIF8", "image/gif"),
    (b"%PDF-", "application/pdf"), (b"PK\x03\x04", "application/zip"), (b"\x1f\x8b", "application/gzip"),
]


def sniff(head, fallback):
    for magic, ctype in MAGIC:
        if head.startswith(magic):
            return ctype
    if head and b"\x00" not in head:
        try:
            head.decode("utf-8")
            return "text/plain"
        except UnicodeDecodeError:
            pass
    return fallback or "application/octet-stream"


def _stop(signum, frame):
    global STOP
    STOP = True
    log.info("signal %s received, finishing the current task", signum)


def process(file_id):
    """Идемпотентно: повторная доставка не портит данные."""
    row = db.get_file(file_id)
    if row is None:
        log.info("skip id=%s: row is gone (deleted while queued)", file_id)
        return
    if row["status"] == "done":
        log.info("skip id=%s: already done", file_id)
        return
    if row["status"] not in ("uploaded", "processing"):
        log.info("skip id=%s: status=%s", file_id, row["status"])
        return
    db.set_status(file_id, "processing")
    cache.invalidate(f"file:{file_id}")
    if DELAY:
        time.sleep(DELAY)
    h, size, head = hashlib.sha256(), 0, b""
    resp = storage.open_object(row["object_key"])
    try:
        for chunk in resp.stream(1024 * 1024):
            if not head:
                head = chunk[:4096]
            h.update(chunk)
            size += len(chunk)
    finally:
        resp.close()
        resp.release_conn()
    ctype = sniff(head, row["content_type"])
    if db.finish(file_id, size, h.hexdigest(), ctype) == 0:
        log.info("skip id=%s: nothing to update (already done or failed)", file_id)
    else:
        log.info("processed ok id=%s size=%d sha256=%s type=%s", file_id, size, h.hexdigest(), ctype)
    cache.invalidate(f"file:{file_id}")


# ---------- наивная версия (опыт 4.1) ----------
def run_naive():
    r = tasks.make_client(socket_timeout=15)
    log.info("mode=naive: BRPOP без подтверждения, задача, взятая из списка, при падении теряется")
    while not STOP:
        try:
            item = r.brpop(tasks.NAIVE, timeout=5)
        except redis.RedisError as exc:
            log.warning("redis error: %s", exc)
            time.sleep(2)
            continue
        if not item:
            continue
        file_id = item[1]
        try:
            process(file_id)
        except Exception:
            log.exception("task id=%s failed and is dropped (naive queue)", file_id)


# ---------- правильная версия ----------
def ensure_group(r):
    try:
        r.xgroup_create(tasks.STREAM, tasks.GROUP, id="0", mkstream=True)
    except redis.ResponseError as exc:
        if "BUSYGROUP" not in str(exc):
            raise


def handle(r, msg_id, fields):
    file_id = fields.get("file_id")
    try:
        process(file_id)
    except Exception:
        # Без подтверждения: задача останется в pending и вернётся после MIN_IDLE_S
        log.exception("task %s failed (id=%s), will be retried after idle", msg_id, file_id)
        return
    r.xack(tasks.STREAM, tasks.GROUP, msg_id)
    r.xdel(tasks.STREAM, msg_id)


def dead_letter(r, msg_id, reason):
    entries = r.xrange(tasks.STREAM, min=msg_id, max=msg_id)
    fields = dict(entries[0][1]) if entries else {}
    r.xadd(tasks.DEAD, {**fields, "orig_id": msg_id, "reason": reason, "at": str(int(time.time()))})
    r.xack(tasks.STREAM, tasks.GROUP, msg_id)
    r.xdel(tasks.STREAM, msg_id)
    file_id = fields.get("file_id")
    log.error("DEAD LETTER task=%s id=%s reason=%s", msg_id, file_id, reason)
    if file_id:
        try:
            db.mark_failed(file_id)
            cache.invalidate(f"file:{file_id}")
        except Exception:
            log.exception("could not mark id=%s failed", file_id)


def recover(r):
    """Зависшие задачи: простой дольше MIN_IDLE_S. Много доставок -> DLQ, иначе забираем себе и повторяем."""
    pending = r.xpending_range(tasks.STREAM, tasks.GROUP, min="-", max="+", count=100, idle=MIN_IDLE_MS)
    for p in pending:
        if STOP:
            return
        msg_id = p["message_id"]
        if p["times_delivered"] >= MAX_DELIVERIES:
            dead_letter(r, msg_id, f"delivered {p['times_delivered']} times without ack")
            continue
        claimed = r.xclaim(tasks.STREAM, tasks.GROUP, CONSUMER, min_idle_time=MIN_IDLE_MS, message_ids=[msg_id])
        for cid, fields in claimed:
            if not fields:
                continue
            log.warning("reclaimed stuck task %s (delivery #%d, idle %.0fs) id=%s",
                        cid, p["times_delivered"] + 1, p["time_since_delivered"] / 1000, fields.get("file_id"))
            handle(r, cid, fields)


def sweep(r):
    """Файлы, для которых задача не дошла до очереди (Redis был недоступен при загрузке) или потерялась."""
    for file_id in db.list_stale():
        if r.set(f"sweep:{file_id}", "1", nx=True, ex=600):
            r.xadd(tasks.STREAM, {"file_id": str(file_id)})
            log.warning("sweeper re-enqueued id=%s (no result for too long)", file_id)


def run_streams():
    r = tasks.make_client(socket_timeout=15)
    log.info("mode=streams consumer=%s delay=%ss min_idle=%sms max_deliveries=%s",
             CONSUMER, DELAY, MIN_IDLE_MS, MAX_DELIVERIES)
    last_recover = last_sweep = 0.0
    while not STOP:
        try:
            ensure_group(r)
            now = time.time()
            if now - last_recover >= RECOVER_EVERY:
                last_recover = now
                recover(r)
            if now - last_sweep >= SWEEP_EVERY:
                last_sweep = now
                try:
                    sweep(r)
                except redis.RedisError:
                    raise
                except Exception:
                    log.exception("sweeper failed")
            resp = r.xreadgroup(tasks.GROUP, CONSUMER, {tasks.STREAM: ">"}, count=1, block=5000)
            for _stream, msgs in resp or []:
                for msg_id, fields in msgs:
                    handle(r, msg_id, fields)
        except redis.RedisError as exc:
            log.warning("redis error: %s", exc)
            time.sleep(2)


def main():
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    os.environ.setdefault("DB_POOL_MAX", "2")  # worker берёт одну задачу за раз
    db.init_pool()
    if MODE == "naive":
        run_naive()
    else:
        run_streams()
    log.info("stopped")


if __name__ == "__main__":
    main()
