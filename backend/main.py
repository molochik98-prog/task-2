import logging
import os
import re
import time
import uuid
from contextlib import asynccontextmanager

import psycopg2
from fastapi import FastAPI, File, Header, HTTPException, Query, Response, UploadFile
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator

import cache
import db
import storage
import tasks
from metrics import FILE_DB_LOADS

DATABASE_URL = os.environ["DATABASE_URL"]
log = logging.getLogger("uvicorn.error")

IDEM_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
DOWNLOADABLE = {"uploaded", "processing", "done"}
DELAY_FLAG = os.environ.get("LOAD_DELAY_FLAG", "/var/uploads-tmp/LOAD_DELAY_MS")


def _test_delay():
    # Тестовый крючок для опыта со stampede (stampede_test.py): файл с числом миллисекунд
    # замедляет загрузку из БД, имитируя тяжёлый запрос. Нет файла - нет задержки.
    try:
        with open(DELAY_FLAG) as f:
            time.sleep(int(f.read().strip() or "0") / 1000)
    except (OSError, ValueError):
        pass


@asynccontextmanager
async def lifespan(app):
    db.init_pool()
    yield


app = FastAPI(lifespan=lifespan)
Instrumentator().instrument(app).expose(app)


@app.exception_handler(db.PoolTimeout)
async def pool_timeout_handler(request, exc):
    return JSONResponse(
        status_code=503,
        content={"detail": "database busy, try again later"},
        headers={"Retry-After": "1"},
    )


@app.get("/live")
def live():
    # Liveness: процесс жив и отвечает. Никаких зависимостей.
    return {"status": "alive"}


@app.get("/health")
def health(response: Response):
    # Readiness: нужна только критичная зависимость, Postgres.
    # Redis и MinIO сюда не входят: без них сервис деградирует, но работает.
    try:
        db.ping()
    except Exception as exc:
        log.error("health: postgres check failed: %s", exc)
        response.status_code = 503
        return {"status": "unavailable"}
    return {"status": "ok"}


@app.get("/health/deps")
def health_deps():
    # Информационная проверка: никогда не 5xx.
    try:
        db.ping()
        pg = "ok"
    except Exception:
        pg = "down"
    return {
        "postgres": pg,
        "redis": "ok" if cache.ping() else "degraded",
        "minio": "ok" if storage.ping() else "degraded",
    }


@app.get("/items")
def get_items():
    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()
    cur.execute("SELECT id, name FROM items;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return [{"id": r[0], "name": r[1]} for r in rows]


@app.post("/api/files")
def upload_file(
    response: Response,
    file: UploadFile = File(...),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    if idempotency_key is not None and not IDEM_RE.match(idempotency_key):
        raise HTTPException(status_code=422, detail="bad Idempotency-Key")

    new_id = uuid.uuid4()
    name = (file.filename or "unnamed")[:255]
    row, created = db.create_or_get(
        new_id, f"files/{new_id}", name, file.content_type, idempotency_key
    )
    file_id, object_key = str(row["id"]), row["object_key"]

    if not created:
        if row["status"] in DOWNLOADABLE:
            response.status_code = 200
            return {"id": file_id, "status": row["status"], "duplicate": True}
        if db.reclaim(file_id) is None:
            raise HTTPException(
                status_code=409,
                detail="upload with this Idempotency-Key is still in progress",
            )
        cache.invalidate(f"file:{file_id}")

    try:
        storage.put(object_key, file.file, file.size, file.content_type)
    except Exception:
        log.exception("upload to storage failed: %s", object_key)
        db.set_status(file_id, "failed")
        cache.invalidate(f"file:{file_id}")
        raise HTTPException(status_code=503, detail="storage unavailable, try again later")
    db.set_status(file_id, "uploaded")
    cache.invalidate(f"file:{file_id}")
    tasks.enqueue(file_id)

    response.status_code = 201
    return {"id": file_id, "status": "uploaded"}


@app.get("/api/files")
def list_files(limit: int = Query(50, ge=1, le=200), offset: int = Query(0, ge=0)):
    return {"items": db.list_files(limit, offset), "limit": limit, "offset": offset}


@app.get("/api/files/{file_id}")
def get_file_meta(file_id: uuid.UUID):
    def load():
        FILE_DB_LOADS.inc()
        _test_delay()
        return db.get_file_public(file_id)

    item = cache.get_or_load(f"file:{file_id}", load)
    if item is None:
        raise HTTPException(status_code=404, detail="file not found")
    return item


@app.delete("/api/files/{file_id}", status_code=204)
def delete_file(file_id: uuid.UUID):
    # Порядок: сначала строка в БД, потом объект. Падение между шагами
    # оставляет потерянный объект (безопасно), а не битую ссылку.
    object_key = db.delete_row(file_id)
    if object_key is None:
        raise HTTPException(status_code=404, detail="file not found")
    cache.invalidate(f"file:{file_id}")
    try:
        storage.remove(object_key)
    except Exception:
        log.exception("orphan object after row delete: %s", object_key)
    return Response(status_code=204)


@app.get("/api/files/{file_id}/link")
def file_link(file_id: uuid.UUID):
    row = db.get_file(file_id)
    if row is None:
        raise HTTPException(status_code=404, detail="file not found")
    # pending/failed: загрузка не завершена, объекта может не быть. Ссылку не даём.
    if row["status"] not in DOWNLOADABLE:
        raise HTTPException(status_code=409, detail="file is not ready")
    return {
        "url": storage.presigned_get_url(row["object_key"]),
        "expires_in": int(storage.LINK_TTL.total_seconds()),
    }
