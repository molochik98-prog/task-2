import os
from contextlib import contextmanager

from psycopg2.pool import ThreadedConnectionPool

_pool = None


def init_pool():
    global _pool
    _pool = ThreadedConnectionPool(
        int(os.environ.get("DB_POOL_MIN", "1")),
        int(os.environ.get("DB_POOL_MAX", "5")),
        os.environ["DATABASE_URL"],
    )


@contextmanager
def get_conn():
    conn = _pool.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        _pool.putconn(conn)


def insert_pending(file_id, object_key, original_name, content_type):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO files (id, object_key, original_name, content_type) "
            "VALUES (%s, %s, %s, %s)",
            (str(file_id), object_key, original_name, content_type),
        )


def set_status(file_id, status):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE files SET status = %s, updated_at = now() WHERE id = %s",
            (status, str(file_id)),
        )
