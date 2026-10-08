import os
import threading
from contextlib import contextmanager

import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool

from metrics import DB_POOL_IN_USE, DB_POOL_SIZE, DB_POOL_TIMEOUTS


class PoolTimeout(Exception):
    """Все соединения пула заняты дольше DB_POOL_TIMEOUT секунд."""


_pool = None
_sem = None
_wait = float(os.environ.get("DB_POOL_TIMEOUT", "2"))


def init_pool():
    global _pool, _sem
    maxconn = int(os.environ.get("DB_POOL_MAX", "5"))
    # minconn = maxconn: ThreadedConnectionPool закрывает возвращаемые соединения
    # сверх minconn, при min=1 под нагрузкой он работал бы как «без пула».
    minconn = int(os.environ.get("DB_POOL_MIN", str(maxconn)))
    # statement_timeout: запрос, застрявший на блокировке, не держит соединение пула вечно
    stmt_ms = int(os.environ.get("DB_STATEMENT_TIMEOUT_MS", "8000"))
    _pool = ThreadedConnectionPool(
        minconn, maxconn, os.environ["DATABASE_URL"], options=f"-c statement_timeout={stmt_ms}"
    )
    _sem = threading.BoundedSemaphore(maxconn)
    DB_POOL_SIZE.set(maxconn)


NO_POOL_FLAG = os.environ.get("NO_POOL_FLAG", "/var/uploads-tmp/NO_POOL")


@contextmanager
def get_conn():
    if os.path.exists(NO_POOL_FLAG):
        # Тестовый режим для замеров (scripts/bench.sh): соединение на каждый запрос
        conn = psycopg2.connect(os.environ["DATABASE_URL"])
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        return
    # Семафор даёт ожидание с таймаутом: сам getconn при исчерпании пула падает сразу.
    if not _sem.acquire(timeout=_wait):
        DB_POOL_TIMEOUTS.inc()
        raise PoolTimeout()
    try:
        conn = _pool.getconn()
    except Exception:
        _sem.release()
        raise
    DB_POOL_IN_USE.inc()
    try:
        yield conn
        conn.commit()
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass
        raise
    finally:
        _pool.putconn(conn)
        DB_POOL_IN_USE.dec()
        _sem.release()


def _public(row):
    out = dict(row)
    out["id"] = str(out["id"])
    for k in ("created_at", "updated_at"):
        if out.get(k) is not None:
            out[k] = out[k].isoformat()
    return out


def ping():
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1")


def create_or_get(file_id, object_key, original_name, content_type, idem_key):
    """(строка, created). Повтор с тем же ключом возвращает прежнюю строку, а не новую."""
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "INSERT INTO files (id, object_key, original_name, content_type, idempotency_key) "
            "VALUES (%s, %s, %s, %s, %s) "
            "ON CONFLICT (idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING "
            "RETURNING id, object_key, status",
            (str(file_id), object_key, original_name, content_type, idem_key),
        )
        row = cur.fetchone()
        if row is not None:
            return row, True
        cur.execute(
            "SELECT id, object_key, status FROM files WHERE idempotency_key = %s",
            (idem_key,),
        )
        return cur.fetchone(), False


def reclaim(file_id):
    """Повторная попытка загрузки: берём failed или pending старше 10 минут. None, если нельзя."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE files SET status = 'pending', updated_at = now() "
            "WHERE id = %s AND (status = 'failed' OR "
            "(status = 'pending' AND updated_at < now() - interval '10 minutes')) "
            "RETURNING object_key",
            (str(file_id),),
        )
        row = cur.fetchone()
    return row[0] if row else None


def set_status(file_id, status):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE files SET status = %s, updated_at = now() WHERE id = %s",
            (status, str(file_id)),
        )


def delete_row(file_id):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "DELETE FROM files WHERE id = %s RETURNING object_key",
            (str(file_id),),
        )
        row = cur.fetchone()
    return row[0] if row else None


def get_file(file_id):
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "SELECT id, object_key, original_name, size_bytes, sha256, content_type, "
            "status, created_at, updated_at FROM files WHERE id = %s",
            (str(file_id),),
        )
        return cur.fetchone()


def get_file_public(file_id):
    row = get_file(file_id)
    return _public(row) if row else None


def list_files(limit, offset):
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "SELECT id, object_key, original_name, size_bytes, sha256, content_type, "
            "status, created_at, updated_at FROM files "
            "ORDER BY created_at DESC, id DESC LIMIT %s OFFSET %s",
            (limit, offset),
        )
        return [_public(r) for r in cur.fetchall()]


def finish(file_id, size, sha256, content_type):
    """Результат обработки. Пишет только из uploaded/processing: повторная доставка ничего не портит."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE files SET status = 'done', size_bytes = %s, sha256 = %s, "
            "content_type = COALESCE(%s, content_type), updated_at = now() "
            "WHERE id = %s AND status IN ('uploaded', 'processing')",
            (size, sha256, content_type, str(file_id)),
        )
        return cur.rowcount


def mark_failed(file_id):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE files SET status = 'failed', updated_at = now() WHERE id = %s AND status <> 'done'",
            (str(file_id),),
        )


def list_stale(limit=100):
    """uploaded дольше 2 минут или processing дольше 10 минут: задача, вероятно, не в очереди."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id FROM files WHERE "
            "(status = 'uploaded' AND updated_at < now() - interval '2 minutes') OR "
            "(status = 'processing' AND updated_at < now() - interval '10 minutes') "
            "ORDER BY updated_at LIMIT %s",
            (limit,),
        )
        return [r[0] for r in cur.fetchall()]
