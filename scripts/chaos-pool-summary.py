#!/usr/bin/env python3
"""Сводка chaos-pool.sh."""
import collections
import re
import statistics
import sys

by = collections.defaultdict(list)
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line:
        by[line[0]].append(line)


def fl(x):
    try:
        return float(x)
    except ValueError:
        return None


print("== события")
for l in by["E"]:
    print(" ", l[2:])

print("== список: 2 запроса в секунду параллельно, ответа не ждём")
rows = []
for l in by["L"]:
    m = re.match(r"L (\S+) (\w+)/(\S+) ra=(\S+) ?(.*)", l)
    if m:
        rows.append(m.groups())
kinds, samples = collections.defaultdict(list), {}
for t, code, sec, ra, body in rows:
    if code.startswith("2"):
        k = "200"
    elif "busy" in body:
        k = "503 busy (пул занят, ждал семафор)"
    elif "timeout" in body:
        k = "503 timeout (statement_timeout)"
    else:
        k = code + " другое"
    kinds[k].append((t, fl(sec), ra))
    samples.setdefault(k, body)
for k, v in sorted(kinds.items()):
    secs = [s for _, s, _ in v if s is not None]
    st = f"время: мин {min(secs):.2f}, медиана {statistics.median(secs):.2f}, макс {max(secs):.2f} с" if secs else ""
    print(f"  {k}: {len(v)} запросов; {st}; Retry-After {sorted({r for _, _, r in v})}")
    print(f"      пример: {samples[k][:100]}")
bad = sorted(t for k, v in kinds.items() if k != "200" for t, _, _ in v)
if bad:
    after = sorted(t for t, _, _ in kinds.get("200", []) if t > bad[-1])
    print(f"  первый не-200 (время старта): {bad[0]}; последний: {bad[-1]}; первый 200 после него: {after[0] if after else 'нет'}")

print("== пробы раз в секунду")
cnt, mx, badh = collections.defaultdict(collections.Counter), {}, collections.defaultdict(list)
for l in by["H"]:
    p = l.split()
    for kv in p[2:]:
        n, v = kv.split("=", 1)
        c, _, s = v.partition("/")
        cnt[n][c] += 1
        x = fl(s)
        if x is not None:
            mx[n] = max(mx.get(n, 0), x)
        if not c.startswith("2"):
            badh[n].append(p[1])
for n in ("health", "file"):
    extra = f"; не-2xx с {min(badh[n])} по {max(badh[n])}" if badh[n] else ""
    print(f"  {n:6} {dict(cnt[n])}  макс. время {mx.get(n, 0):.2f} с{extra}")

print("== загрузки раз в 10 с")
uc, us = collections.Counter(), {}
for l in by["U"]:
    p = l.split(None, 3)
    c = p[2].split("/")[0]
    uc[c] += 1
    us.setdefault(c, f"{p[2]} {p[3] if len(p) > 3 else ''}")
print(" ", dict(uc))
for c, v in us.items():
    print(f"    пример {c}: {v[:130]}")

print("== метрики пула")
snaps = []
for l in by["M"]:
    p = l.split()
    d = {kv.split("=", 1)[0]: fl(kv.split("=", 1)[1]) for kv in p[2:] if "=" in kv}
    snaps.append((p[1], d))
if snaps:
    size = snaps[-1][1].get("db_pool_size")
    used = [(t, d.get("db_pool_in_use") or 0) for t, d in snaps]
    full = [t for t, v in used if size and v >= size]
    nz = [t for t, v in used if v > 0]
    print(f"  db_pool_in_use: максимум {max(v for _, v in used)} из {size}; пул полон в снимках: {full[0] + ' .. ' + full[-1] if full else 'ни разу'}")
    print(f"  занято > 0: {nz[0] + ' .. ' + nz[-1] if nz else 'ни разу'}")
    print(f"  db_pool_timeouts_total: {snaps[0][1].get('db_pool_timeouts_total')} -> {snaps[-1][1].get('db_pool_timeouts_total')}")

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
