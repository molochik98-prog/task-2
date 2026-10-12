#!/usr/bin/env python3
"""Сводка по файлу chaos-redis.sh: события, коды по фазам, метрики кеша, алерты, статусы задач."""
import collections
import sys

by = collections.defaultdict(list)
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line:
        by[line[0]].append(line)

print("== события")
for l in by["E"]:
    print(" ", l[2:])

print("== опрос раз в секунду (pre = до остановки, down = Redis остановлен, post = после запуска)")
cnt = collections.defaultdict(collections.Counter)
slow, first_bad, first_ok_after = {}, {}, {}
for l in by["P"]:
    parts = l.split()
    t, phase = parts[1], parts[2]
    for kv in parts[3:]:
        name, val = kv.split("=", 1)
        c, _, sec = val.partition("/")
        cnt[(phase, name)][c] += 1
        try:
            slow[(phase, name)] = max(slow.get((phase, name), 0.0), float(sec))
        except ValueError:
            pass
        if phase == "down" and not c.startswith("2"):
            first_bad.setdefault(name, t)
        if phase == "post" and c.startswith("2") and name in first_bad:
            first_ok_after.setdefault(name, t)
order = ["pre", "down", "post"]
for (phase, name), c in sorted(cnt.items(), key=lambda x: (x[0][1], order.index(x[0][0]))):
    print(f"  {name:6} {phase:5} {dict(c)}  макс. время ответа {slow.get((phase, name), 0):.3f} с")
for name in ("health", "file", "list"):
    print(f"  {name}: первый не-2xx при остановленном Redis: {first_bad.get(name, 'нет')}; "
          f"снова 2xx после запуска: {first_ok_after.get(name, 'не было сбоя')}")

print("== загрузки (раз в 10 с)")
uc, samples = collections.defaultdict(collections.Counter), {}
for l in by["U"]:
    parts = l.split(None, 4)
    phase, c = parts[2], parts[3].split("/")[0]
    uc[phase][c] += 1
    samples.setdefault((phase, c), parts[4] if len(parts) > 4 else "")
for phase in order:
    if phase in uc:
        print(f"  {phase:5} {dict(uc[phase])}")
for (phase, c), body in samples.items():
    print(f"    пример {phase} {c}: {body[:150]}")

def kv(line):
    return {k: v for k, v in (x.split("=", 1) for x in line.split()[3:] if "=" in x)}

def num(d, k):
    try:
        return float(d[k])
    except (KeyError, ValueError):
        return None

print("== метрики backend (снимок раз в 5 с)")
snaps = [(l.split()[1], l.split()[2], kv(l)) for l in by["M"]]
last = {}
for t, ph, d in snaps:
    last[ph] = (t, d)
prev = object()
for t, ph, d in snaps:
    u = num(d, "queue_stats_up")
    if u != prev:
        print(f"  queue_stats_up -> {u} в {t} ({ph})")
        prev = u
if "pre" in last and "down" in last:
    e0 = num(last["pre"][1], "cache_errors_total") or 0
    e1 = num(last["down"][1], "cache_errors_total")
    first_err = next((t for t, ph, d in snaps if ph == "down" and (num(d, "cache_errors_total") or 0) > e0), None)
    print(f"  cache_errors_total: {e0} перед остановкой -> {e1} в конце простоя; первая ошибка в снимке {first_err}")
if "down" in last:
    h1 = num(last["down"][1], "cache_hits_total") or 0
    m1 = num(last["down"][1], "cache_misses_total") or 0
    fh = next((t for t, ph, d in snaps if ph == "post" and (num(d, "cache_hits_total") or 0) > h1), None)
    fm = next((t for t, ph, d in snaps if ph == "post" and (num(d, "cache_misses_total") or 0) > m1), None)
    print(f"  после запуска Redis: первый промах кеша в снимке {fm}, первое попадание {fh}")

print("== алерты Prometheus (pending / firing: время первого снимка; firing_last: последнего)")
seen = {}
for l in by["A"]:
    parts = l.split(None, 3)
    t, txt = parts[1], (parts[3] if len(parts) > 3 else "")
    for it in txt.split():
        if "=" in it:
            n, st = it.split("=", 1)
            d = seen.setdefault(n, {})
            d.setdefault(st, t)
            d[st + "_last"] = t
for n, d in sorted(seen.items()):
    print(" ", n, d)
for n in ("RedisUnavailable", "CacheBypassed"):
    if n not in seen:
        print(" ", n, "ни разу не появился")

print("== статусы загруженных за опыт файлов (после запуска Redis)")
for l in by["S"]:
    print(" ", l[2:])
