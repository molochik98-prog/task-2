import os
import uuid
from contextlib import asynccontextmanager

import psycopg2
from fastapi import FastAPI, File, UploadFile
from prometheus_fastapi_instrumentator import Instrumentator

import db
import storage

DATABASE_URL = os.environ["DATABASE_URL"]


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
