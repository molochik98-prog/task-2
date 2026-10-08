"""Сверка Postgres и MinIO. Коды выхода: 0 - всё сходится, 10 - найден рассинхрон, 2 - не смогли проверить."""
import os
import sys
from datetime import datetime, timedelta, timezone

import psycopg2

import storage

# Свежие объекты и строки пропускаем: загрузка или удаление могут быть в полёте.
GRACE = timedelta(minutes=int(os.environ.get("RECONCILE_GRACE_MIN", "10")))
MAX_LINES = 50
DOWNLOADABLE = ("uploaded", "processing", "done")


def show(label, items):
    for line in items[:MAX_LINES]:
        print(f"{label} {line}")
    if len(items) > MAX_LINES:
        print(f"{label} ... и ещё {len(items) - MAX_LINES}")


def main():
    now = datetime.now(timezone.utc)

    def old(ts):
        return ts is None or now - ts > GRACE

    objects = {o.object_name: o for o in storage.list_objects("files/")}

    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id, object_key, status, updated_at FROM files")
            rows = cur.fetchall()
    finally:
        conn.close()

    keys_in_db = {r[1] for r in rows}

    orphan_objects = [
        f"{k} size={o.size}"
        for k, o in sorted(objects.items())
        if k not in keys_in_db and old(o.last_modified)
    ]
    missing_objects = [
        f"id={r[0]} key={r[1]} status={r[2]}"
        for r in rows
        if r[2] in DOWNLOADABLE and r[1] not in objects and old(r[3])
    ]
    stale_pending = [
        f"id={r[0]} key={r[1]} updated_at={r[3].isoformat()}"
        for r in rows
        if r[2] == "pending" and r[1] not in objects and old(r[3])
    ]
    stuck_pending = [
        f"id={r[0]} key={r[1]} updated_at={r[3].isoformat()}"
        for r in rows
        if r[2] == "pending" and r[1] in objects and old(r[3])
    ]
    failed = sum(1 for r in rows if r[2] == "failed")

    print(f"reconcile: objects={len(objects)} rows={len(rows)} grace={GRACE}")
    show("ORPHAN_OBJECT (объект без записи)", orphan_objects)
    show("MISSING_OBJECT (запись без объекта, ссылка битая)", missing_objects)
    show("STALE_PENDING (загрузка оборвалась, объекта нет)", stale_pending)
    show("STUCK_PENDING (объект есть, статус не дошёл до uploaded)", stuck_pending)
    print(f"INFO failed_rows={failed} (известный статус, в алерт не входят)")

    total = len(orphan_objects) + len(missing_objects) + len(stale_pending) + len(stuck_pending)
    print(
        f"RESULT orphan_objects={len(orphan_objects)} missing_objects={len(missing_objects)} "
        f"stale_pending={len(stale_pending)} stuck_pending={len(stuck_pending)}"
    )
    return 10 if total else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"RECONCILE ERROR: {type(exc).__name__}: {exc}")
        sys.exit(2)
