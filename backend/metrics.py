from prometheus_client import Counter, Gauge

CACHE_HITS = Counter("cache_hits_total", "Redis cache hits")
CACHE_MISSES = Counter("cache_misses_total", "Redis cache misses")
CACHE_ERRORS = Counter("cache_errors_total", "Redis errors (cache bypassed)")
FILE_DB_LOADS = Counter("file_db_loads_total", "File metadata reads that reached Postgres through the cache loader")
DB_POOL_IN_USE = Gauge("db_pool_in_use", "Postgres connections currently checked out of the pool")
DB_POOL_TIMEOUTS = Counter("db_pool_timeouts_total", "Requests that gave up waiting for a pooled connection")
DB_POOL_SIZE = Gauge("db_pool_size", "Configured max Postgres pool connections")
