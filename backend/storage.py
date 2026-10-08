import os
from datetime import timedelta
from urllib.parse import urlsplit, urlunsplit

from minio import Minio

BUCKET = os.environ["S3_BUCKET"]
PART_SIZE = 10 * 1024 * 1024

_client = Minio(
    os.environ["S3_ENDPOINT"],
    access_key=os.environ["S3_ACCESS_KEY"],
    secret_key=os.environ["S3_SECRET_KEY"],
    secure=False,
    region=os.environ.get("S3_REGION", "us-east-1"),
)


def put(key, stream, size, content_type):
    return _client.put_object(
        BUCKET,
        key,
        stream,
        length=size if size is not None else -1,
        part_size=PART_SIZE,
        content_type=content_type or "application/octet-stream",
    )


def remove(key):
    _client.remove_object(BUCKET, key)


PUBLIC_ENDPOINT = os.environ.get("S3_PUBLIC_ENDPOINT", "app.local")
LINK_TTL = timedelta(minutes=5)

# Клиент только для подписи ссылок: регион задан, поэтому сетевых запросов он
# не делает. Подписываем для публичного хоста, а не для minio:9000.
_signer = Minio(
    PUBLIC_ENDPOINT,
    access_key=os.environ["S3_ACCESS_KEY"],
    secret_key=os.environ["S3_SECRET_KEY"],
    secure=True,
    region=os.environ.get("S3_REGION", "us-east-1"),
)


def presigned_get_url(key):
    url = _signer.presigned_get_object(BUCKET, key, expires=LINK_TTL)
    parts = urlsplit(url)
    # /s3 дописываем после подписи: nginx отрежет его, MinIO увидит подписанный путь
    return urlunsplit(parts._replace(path="/s3" + parts.path))


def list_objects(prefix="files/"):
    return _client.list_objects(BUCKET, prefix=prefix, recursive=True)


def ping():
    # Лёгкая проверка с жёстким таймаутом: клиент minio при недоступном хосте долго ретраит.
    import urllib.request

    try:
        url = "http://%s/minio/health/live" % os.environ["S3_ENDPOINT"]
        with urllib.request.urlopen(url, timeout=1) as resp:
            return resp.status == 200
    except Exception:
        return False
