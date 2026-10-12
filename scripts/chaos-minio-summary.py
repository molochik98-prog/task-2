#!/usr/bin/env python3
"""Сводка по файлу chaos-minio.sh."""
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

print("== опрос (pre = до остановки, down = MinIO остановлен, post = после запуска)")
cnt, mx = collections.defaultdict(collections.Counter), {}
first_bad, first_ok = {}, {}
trans, last = collections.defaultdict(list), {}
for l in by["P"]:
    p = l.split()
    t, phase = p[1], p[2]
    for kv in p[3:]:
        n, v = kv.split("=", 1)
        if n in ("minio", "deps"):
            if last.get(n) != v:
                trans[n].append(f"{t} ({phase}) -> {v}")
                last[n] = v
            continue
        c, _, sec = v.partition("/")
        cnt[(n, phase)][c] += 1
        try:
            mx[(n, phase)] = max(mx.get((n, phase), 0.0), float(sec))
        except ValueError:
            pass
        if phase == "down" and not c.startswith("2"):
            first_bad.setdefault(n, t)
        if phase == "post" and c.startswith("2") and n in first_bad:
            first_ok.setdefault(n, t)
order = ["pre", "down", "post"]
for name in ("health", "file", "list", "link", "dl"):
    for ph in order:
        if (name, ph) in cnt:
            print(f"  {name:6} {ph:5} {dict(cnt[(name, ph)])}  макс. время {mx.get((name, ph), 0):.3f} с")
    if name in first_bad:
        print(f"  {name}: первый не-2xx при остановленном MinIO {first_bad[name]}; снова 2xx после запуска {first_ok.get(name, 'нет')}")
for n in ("minio", "deps"):
    print(f"  смены {n}: " + "; ".join(trans[n]))

print("== загрузки раз в 10 с (без ключа)")
uc, samples, first_201 = collections.defaultdict(collections.Counter), {}, None
for l in by["U"]:
    p = l.split(None, 4)
    phase, c = p[2], p[3].split("/")[0]
    uc[phase][c] += 1
    samples.setdefault((phase, c), p[4] if len(p) > 4 else "")
    if phase == "post" and c.startswith("2") and first_201 is None:
        first_201 = p[1]
for ph in order:
    if ph in uc:
        print(f"  {ph:5} {dict(uc[ph])}")
for (ph, c), b in samples.items():
    print(f"    пример {ph} {c}: {b[:150]}")
print(f"  первая успешная загрузка после запуска: {first_201}")

print("== повтор с Idempotency-Key")
for l in by["K"]:
    print(" ", l[2:])

print("== метрики backend (смены значений)")
prev = {}
for l in by["M"]:
    p = l.split()
    t, ph = p[1], p[2]
    for kv in p[3:]:
        if "=" not in kv:
            continue
        n, v = kv.split("=", 1)
        if prev.get(n) != v:
            print(f"  {n} -> {v} в {t} ({ph})")
            prev[n] = v

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
if not seen or all(set(d) <= {"none"} for d in seen.values()):
    print("  ни одного алерта за время опыта")
for n, d in sorted(seen.items()):
    if n != "none":
        print(" ", n, d)

print("== статусы файлов опыта после запуска MinIO")
for l in by["S"]:
    print(" ", l[2:])
