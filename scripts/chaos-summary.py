#!/usr/bin/env python3
"""Сводка по файлу chaos-pg.sh: коды по пробам, первый и последний сбой, момент восстановления."""
import collections
import sys

rows = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) < 2 or p[0] == "готово":
        continue
    rows.append((p[0], dict(x.split("=", 1) for x in p[1:] if "=" in x)))

for name in ("health", "file", "list", "upload"):
    seq = [(t, d[name].split("/")[0]) for t, d in rows if d.get(name, "-") != "-"]
    cnt = collections.Counter(c for _, c in seq)
    bad = [i for i, (_, c) in enumerate(seq) if not c.startswith("2")]
    out = f"{name:7} {dict(cnt)}"
    if bad:
        rec = seq[bad[-1] + 1][0] if bad[-1] + 1 < len(seq) else "нет"
        out += f"  первый не-2xx {seq[bad[0]][0]}, последний {seq[bad[-1]][0]}, снова 2xx {rec}"
    print(out)
prev = None
for t, d in rows:
    if d.get("docker") != prev:
        prev = d.get("docker")
        print(f"docker {t} -> {prev}")
