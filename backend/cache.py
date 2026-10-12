import json
import logging
import os
import random
import threading
import time

import redis

from metrics import CACHE_ERRORS, CACHE_HITS, CACHE_MISSES

log = logging.getLogger("uvicorn.error")

TTL_BASE = int(os.environ.get("CACHE_TTL", "60"))
TTL_JITTER = float(os.environ.get("CACHE_TTL_JITTER", "0.3"))
BREAKER_SECONDS = float(os.environ.get("CACHE_BREAKER_SECONDS", "5"))
NO_CACHE_FLAG = os.environ.get("NO_CACHE_FLAG", "/var/uploads-tmp/NO_CACHE")  # только для замеров
# Выключатель single-flight: существование файла отключает коалесцирование.
# Нужен для опыта со stampede (до/после) без перезапуска контейнера.
FLAG = os.environ.get("CACHE_NO_SINGLEFLIGHT_FLAG", "/var/uploads-tmp/NO_SINGLEFLIGHT")

_pool = redis.ConnectionPool(
    host=os.environ.get("REDIS_HOST", "redis"),
    port=6379,
    password=os.environ.get("REDIS_PASSWORD"),
    socket_connect_timeout=0.3,
    socket_timeout=0.3,
    max_connections=64,  # больше потоков пула FastAPI (40): иначе под нагрузкой "Too many connections"
    decode_responses=True,
)
_client = redis.Redis(connection_pool=_pool)

_down_until = 0.0
_calls = {}  # single-flight: ключ -> идущая загрузка
SF_WAIT = float(os.environ.get("SINGLEFLIGHT_WAIT_S", "12"))  # дольше ожидания пула (2 с) + statement_timeout (8 с)


class _Call:
    __slots__ = ("done", "value", "exc")

    def __init__(self):
        self.done = threading.Event()
        self.value = None
        self.exc = None
_guard = threading.Lock()


def _available():
    return time.monotonic() >= _down_until


def _fail(op, exc):
    """Redis не ответил: считаем ошибку, пердупреждаем, на BREAKER_SECONDS обходим кеш."""
    global _down_until
    CACHE_ERRORS.inc()
    log.warning("redis unavailable (%s): %s; cache bypassed for %.0fs", op, exc, BREAKER_SECONDS)
    _down_until = time.monotonic() + BREAKER_SECONDS


def ttl():
    return int(TTL_BASE * (1 + random.uniform(0, TTL_JITTER)))


def get(key, count=True):
    if not _available():
        return None
    try:
        raw = _client.get(key)
    except redis.RedisError as exc:
        _fail("get", exc)
        return None
    if raw is None:
        if count:
            CACHE_MISSES.inc()
        return None
    if count:
        CACHE_HITS.inc()
    return json.loads(raw)


def put(key, value, ttl_seconds=None):
    if not _available():
        return
    try:
        _client.set(key, json.dumps(value), ex=ttl_seconds or ttl())
    except redis.RedisError as exc:
        _fail("set", exc)


def invalidate(key):
    if not _available():
        return
    try:
        _client.delete(key)
    except redis.RedisError as exc:
        _fail("delete", exc)


def ping():
    if not _available():
        return False
    try:
        return bool(_client.ping())
    except redis.RedisError as exc:
        _fail("ping", exc)
        return False


def get_or_load(key, loader):
    """Кеш -> при промахе одна загрузка из БД на ключ (single-flight) -> кеш."""
    if os.path.exists(NO_CACHE_FLAG):
        return loader()
    value = get(key)
    if value is not None:
        return value

    # Redis лежит или single-flight выключен: просто грузим из БД
    if not _available() or os.path.exists(FLAG):
        value = loader()
        if value is not None:
            put(key, value)
        return value

    with _guard:
        call = _calls.get(key)
        leader = call is None
        if leader:
            call = _calls[key] = _Call()
    if not leader:
        # Результат ведущего (значение или ошибка) получают все ожидающие сразу. Раньше каждый
        # ожидающий по очереди шёл в БД сам: при отказе пула очередь росла дольше 15 с.
        if call.done.wait(SF_WAIT):
            if call.exc is not None:
                raise call.exc
            return call.value
        return loader()  # ведущий не ответил за SF_WAIT: грузим сами
    try:
        value = get(key, count=False)  # между промахом и захватом ключа мог загрузить другой
        if value is None:
            value = loader()
            if value is not None:
                put(key, value)
        call.value = value
        return value
    except BaseException as exc:
        call.exc = exc
        raise
    finally:
        with _guard:
            if _calls.get(key) is call:
                del _calls[key]
        call.done.set()
