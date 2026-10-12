#!/usr/bin/env python3
"""Сводка chaos-disk.sh: коды по фазам, загрузки, сверка размера и SHA-256 по итоговым статусам."""
import collections
import json
import re
import ssl
import sys
import urllib.request

out, ca, base = sys.argv[1:4]
by = collections.defaultdict(list)
for line in open(out):
    line = line.rstrip("\n")
    if line:
        by[line[0]].append(line)

print("== события")
run = exp_size = exp_sha = None
for l in by["E"]:
    print(" ", l[2:])
    m = re.search(r"RUN=(\d+) expect size=(\d+) sha=([0-9a-f]+)", l)
    if m:
        run, exp_size, exp_sha = m.group(1), int(m.group(2)), m.group(3)

print("== опрос раз в секунду (pre / full = диск заполнен / post = заглушка удалена)")
cnt, mx = collections.defaultdict(collections.Counter), {}
for l in by["P"]:
    p = l.split()
    for kv in p[3:]:
        n, v = kv.split("=", 1)
        c, _, sec = v.partition("/")
        cnt[(n, p[2])][c] += 1
        try:
            mx[(n, p[2])] = max(mx.get((n, p[2]), 0.0), float(sec))
        except ValueError:
            pass
for n in ("health", "file", "list"):
    for ph in ("pre", "full", "post"):
        if (n, ph) in cnt:
            print(f"  {n:6} {ph:5} {dict(cnt[(n, ph)])}  макс. время {mx.get((n, ph), 0):.3f} с")

print("== смены состояния MinIO, deps, bucket_objects, свободное место")
prev = {}
for l in by["M"]:
    p = l.split()
    t, ph = p[1], p[2]
    for kv in p[3:]:
        n, v = kv.split("=", 1)
        if n == "free":
            continue
        if prev.get(n) != v:
            print(f"  {n} -> {v} в {t} ({ph})")
            prev[n] = v
frees = [int(kv.split("=")[1]) for l in by["M"] for kv in l.split() if kv.startswith("free=")]
if frees:
    print(f"  свободно МиБ: минимум {min(frees)}, максимум {max(frees)}")

print("== загрузки (раз в 10 с)")
ids, uc, samples = [], collections.defaultdict(collections.Counter), {}
for l in by["U"]:
    p = l.split(None, 4)
    t, ph, res = p[1], p[2], p[3]
    c = res.split("/")[0]
    body = p[4] if len(p) > 4 else ""
    uc[ph][c] += 1
    samples.setdefault((ph, c), (t, res, body))
    m = re.search(r'"id":"([0-9a-f-]+)"', body)
    if c.startswith("2") and m:
        ids.append((t, ph, m.group(1)))
for ph in ("pre", "full", "post"):
    if ph in uc:
        print(f"  {ph:5} {dict(uc[ph])}")
for (ph, c), (t, res, body) in samples.items():
    print(f"    пример {ph} {c} в {t} ({res.split('/')[1][:5]} с): {body[:140]}")

print("== итог по файлам опыта (сверка с исходным файлом)")
ctx = ssl.create_default_context(cafile=ca)
ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT  # CA без keyUsage: curl принимает, строгий Python нет
try:
    items = json.load(urllib.request.urlopen(base + "/api/files?limit=200", context=ctx, timeout=10))["items"]
except Exception as e:
    items = []
    print("  список не получен:", e, "=> СВЕРКА НЕ ВЫПОЛНЕНА")
mine = [i for i in items if i["original_name"].startswith(f"chaos5-{run}-")]
silent = 0
for i in sorted(mine, key=lambda x: x["created_at"]):
    ok = i["status"] == "done" and i["size_bytes"] == exp_size and i["sha256"] == exp_sha
    got_201 = any(x[2] == i["id"] for x in ids)
    if got_201 and not ok:
        silent += 1
    print(f"  {i['id'][:8]} статус={i['status']:9} размер={i['size_bytes']} sha_совпал={i['sha256'] == exp_sha}  клиент получил 201: {got_201}  {'OK' if ok else ''}")
print(f"  ТИХИЙ УСПЕХ (клиент получил 201, а данных нет или они не те): {silent if mine else 'не определено (список пуст)'}")
print("== алерты Prometheus")
seen = {}
for l in by["A"]:
    p = l.split(None, 3)
    for it in (p[3].split() if len(p) > 3 else []):
        if "=" in it:
            n, st = it.split("=", 1)
            seen.setdefault(n, {}).setdefault(st, p[1])
if not seen:
    print("  ни одного алерта за время опыта")
for n, d in sorted(seen.items()):
    print(" ", n, d)
print("== статусы по ходу ожидания задач")
for l in by["S"]:
    print(" ", l[2:])
