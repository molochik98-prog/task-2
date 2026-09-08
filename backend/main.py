import os
import psycopg2
from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI()
Instrumentator().instrument(app).expose(app)

DATABASE_URL = os.environ["DATABASE_URL"]

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
    return [{"id": r[0], "name": r [1]} for r in rows]
