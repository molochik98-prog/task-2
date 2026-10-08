"""Генерирует files-service.json (Classic JSON). Импорт в Grafana: Dashboards -> New -> Import -> Upload JSON file."""
import json

DS = {"type": "prometheus", "uid": "${DS}"}
HIGHR = "http_request_duration_highr_seconds_bucket"


def panel(pid, title, targets, x, y, w=8, h=7, unit="short", ptype="timeseries"):
    return {
        "id": pid, "title": title, "type": ptype, "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": DS}
                    for i, (e, l) in enumerate(targets)],
    }


hit = "sum(rate(cache_hits_total[5m]))"
miss = "sum(rate(cache_misses_total[5m]))"
panels = [
    panel(1, "Кеш: hit rate", [(f"{hit} / ({hit} + {miss})", "hit rate")], 0, 0, unit="percentunit"),
    panel(2, "Кеш: попадания и промахи в секунду", [(hit, "попадания"), (miss, "промахи"),
          ("sum(rate(cache_errors_total[5m]))", "ошибки Redis")], 8, 0),
    panel(3, "Очередь: ожидают и в работе", [("queue_waiting_tasks", "ожидают"), ("queue_inflight_tasks", "в работе")], 16, 0),
    panel(4, "Очередь: возраст самой старой задачи", [("queue_oldest_task_age_seconds", "возраст")], 0, 7, unit="s"),
    panel(5, "Мёртвая очередь", [("queue_dead_tasks", "задач")], 8, 7, ptype="stat"),
    panel(6, "Пул Postgres: занято и размер", [("db_pool_in_use", "занято"), ("db_pool_size", "размер"),
          ("increase(db_pool_timeouts_total[5m])", "отказов за 5 мин")], 16, 7),
    panel(7, "Латентность API (перцентили)", [(f"histogram_quantile({q}, sum by (le) (rate({HIGHR}[5m])))", f"p{int(q*100)}")
          for q in (0.5, 0.95, 0.99)], 0, 14, w=12, unit="s"),
    panel(8, "Запросы в секунду и доля ошибок", [("sum by (status) (rate(http_requests_total[5m]))", "{{status}}"),
          ('sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))', "доля 5xx")], 12, 14, w=12),
    panel(9, "Bucket: размер", [("bucket_bytes", "байт")], 0, 21, unit="bytes"),
    panel(10, "Bucket: число объектов", [("bucket_objects", "объектов")], 8, 21),
    panel(11, "Сверка: найдено рассинхронов и возраст последнего запуска",
          [("reconcile_last_mismatches", "рассинхронов"), ("time() - reconcile_last_run_timestamp_seconds", "секунд с запуска")], 16, 21),
]
dash = {
    "title": "Files service (Postgres + Redis + MinIO)", "uid": "files-service", "schemaVersion": 39,
    "version": 1, "refresh": "30s", "time": {"from": "now-1h", "to": "now"}, "tags": ["task4"],
    "templating": {"list": [{"name": "DS", "label": "Prometheus", "type": "datasource", "query": "prometheus",
                             "current": {}, "hide": 0}]},
    "panels": panels,
}
open("files-service.json", "w").write(json.dumps(dash, ensure_ascii=False, indent=1))
print("files-service.json: панелей", len(panels))
