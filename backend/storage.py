import os

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
