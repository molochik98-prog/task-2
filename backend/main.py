import logging
import os
import uuid
from contextlib import asynccontextmanager

import psycopg2
from fastapi import FastAPI, File, HTTPException, Response, UploadFile
from prometheus_fastapi_instrumentator import Instrumentator

import db
import storage

DATABASE_URL = os.environ["DATABASE_URL"]
log = logging.getLogger("uvicorn.error")


@asynccontextmanager
async def lifespan(app):
    db.init_pool()
    yield


app = FastAPI(lifespan=lifespan)
Instrumentator().instrument(app).expose(app)


@app.get("/health")
def health():
    conn = psycopg2.connect(DATABASE_URL)
    conn.close()
    return {"status": "ok"}


@app.get("/items")
def get_items():
    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()
    cur.execute("SELECT id, name FROM items;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return [{"id": r[0], "name": r[1]} for r in rows]


@app.post("/api/files", status_code=201)
def upload_file(file: UploadFile = File(...)):
    file_id = uuid.uuid4()
    object_key = f"files/{file_id}"
    name = (file.filename or "unnamed")[:255]

    db.insert_pending(file_id, object_key, name, file.content_type)
    storage.put(object_key, file.file, file.size, file.content_type)
    db.set_status(file_id, "uploaded")

    return {"id": str(file_id), "status": "uploaded"}


@app.delete("/api/files/{file_id}", status_code=204)
def delete_file(file_id: uuid.UUID):
    # Порядок: сначала строка в БД, потом объект. Падение между шагами
    # оставляет потерянный объект (безопасно), а не битую ссылку.
    object_key = db.delete_row(file_id)
    if object_key is None:
        raise HTTPException(status_code=404, detail="file not found")
    try:
        storage.remove(object_key)
    except Exception:
        log.exception("orphan object after row delete: %s", object_key)
    return Response(status_code=204)
