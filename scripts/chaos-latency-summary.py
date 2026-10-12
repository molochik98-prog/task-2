#!/usr/bin/env python3
"""Сводка chaos-latency.sh: wrk по кускам, пробы, пул, алерты."""
import collections
import statistics
import sys

by = collections.defaultdict(list)
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line:
        by[line[0]].append(line)
fl = lambda x: float(x) if x not in ("", None) else None

print("== события")
for l in by["E"]:
    print(" ", l[2:])

print("== wrk по 30-секундным кускам (время НАЧАЛА куска; фаза по моменту начала, поэтому кусок на стыке относится к предыдущей)")
on = off = None
for l in by["E"]:
    if "включена" in l:
        on = l.split()[1]
    if "снята" in l and "tc" not in l:
        off = l.split()[1]
for l in by["W"]:
    t = l.split()[1]
    ph = "pre" if (on is None or t < on) else ("delay" if (off is None or t < off) else "post")
    print(f"  {t} {ph:5} {' '.join(l.split()[2:])}")

print("== пробы раз в секунду")
cnt, secs, bad = collections.defaultdict(collections.Counter), collections.defaultdict(list), collections.defaultdict(list)
for l in by["P"]:
    p = l.split()
    ph = p[2]
    for kv in p[3:]:
        n, v = kv.split("=", 1)
        c, _, s = v.partition("/")
        cnt[(n, ph)][c] += 1
        if s not in ("", "-"):
            secs[(n, ph)].append(float(s))
        if not c.startswith("2"):
            bad[n].append(p[1])
for n in ("health", "file", "list1"):
    for ph in ("pre", "delay", "post"):
        if (n, ph) in cnt:
            s = secs[(n, ph)]
            q = (f"p50 {statistics.median(s):.3f}  p95 {sorted(s)[int(len(s) * .95) - 1]:.3f}  макс {max(s):.3f} с") if s else ""
            print(f"  {n:6} {ph:5} {dict(cnt[(n, ph)])}  {q}")
    if bad[n]:
        print(f"  {n}: не-2xx с {min(bad[n])} по {max(bad[n])}")

print("== загрузки раз в 10 с")
uc = collections.defaultdict(collections.Counter)
for l in by["U"]:
    p = l.split()
    uc[p[2]][p[3].split("/")[0]] += 1
for ph in ("pre", "delay", "post"):
    if ph in uc:
        print(f"  {ph:5} {dict(uc[ph])}")

print("== пул и Docker healthcheck (смены)")
prev = {}
for l in by["M"]:
    p = l.split()
    for kv in p[3:]:
        n, v = kv.split("=", 1)
        if n == "db_pool_in_use":
            continue
        if prev.get(n) != v:
            print(f"  {n} -> {v} в {p[1]} ({p[2]})")
            prev[n] = v
mx = max((fl(kv.split("=")[1]) for l in by["M"] for kv in l.split() if kv.startswith("db_pool_in_use=")), default=None)
print(f"  db_pool_in_use максимум: {mx}")

print("== алерты Prometheus")
seen = {}
for l in by["A"]:
    p = l.split(None, 3)
    for it in (p[3].split() if len(p) > 3 else []):
        if "=" in it:
            n, st = it.split("=", 1)
            d = seen.setdefault(n, {})
            d.setdefault(st, p[1])
            d[st + "_last"] = p[1]
if not seen:
    print("  ни одного алерта за время опыта")
for n, d in sorted(seen.items()):
    print(" ", n, d)
bad_snap = [l for l in by["A"] if "prometheus-unavailable" in l]
print(f"  снимков с недоступным Prometheus: {len(bad_snap)} из {len(by['A'])}")
