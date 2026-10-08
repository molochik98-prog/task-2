-- Вывод одной строкой: RPS, p50/p95/p99 (мс) и счётчики ошибок. wrk сам p95 не печатает.
done = function(summary, latency, requests)
  local rps = summary.requests / (summary.duration / 1000000)
  io.write(string.format(
    "RESULT rps=%.0f p50=%.1f p95=%.1f p99=%.1f non2xx=%d connect=%d read=%d write=%d timeout=%d\n",
    rps, latency:percentile(50) / 1000, latency:percentile(95) / 1000, latency:percentile(99) / 1000,
    summary.errors.status, summary.errors.connect, summary.errors.read, summary.errors.write, summary.errors.timeout))
end
