#!/usr/bin/env python3
"""Prometheus -> Telegram: по одному сообщению на переход (сработал / снялся), без повторов."""
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

PROM = "monitoring-stack-prometheus-1"
STATE = os.path.join(os.environ.get("STATE_DIRECTORY", "/var/lib/alert-notifier"), "state.json")
TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT = os.environ["TELEGRAM_CHAT_ID"]
HOST = os.uname().nodename


def send(text):
    data = urllib.parse.urlencode({"chat_id": CHAT, "text": f"{HOST}: {text}"}).encode()
    urllib.request.urlopen(f"https://api.telegram.org/bot{TOKEN}/sendMessage", data, timeout=10).read()


def firing():
    out = subprocess.run(
        ["docker", "exec", PROM, "wget", "-qO-", "http://localhost:9090/api/v1/alerts"],
        capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "wget failed")
    alerts = {}
    for a in json.loads(out.stdout)["data"]["alerts"]:
        if a["state"] != "firing":
            continue
        lb = a["labels"]
        key = "|".join([lb.get("alertname", "?"), lb.get("job", ""), lb.get("instance", "")])
        alerts[key] = f'{lb.get("alertname", "?")}: {a["annotations"].get("summary", "")}'
    return alerts


def main():
    try:
        state = json.load(open(STATE))
    except Exception:
        state = {"firing": {}, "fails": 0}
    try:
        now = firing()
    except Exception as exc:
        state["fails"] = state.get("fails", 0) + 1
        print(f"Prometheus недоступен ({state['fails']}): {exc}")
        if state["fails"] == 3:
            send("🔕 Prometheus недоступен 3 минуты подряд: алерты не проверяются")
        json.dump(state, open(STATE, "w"))
        return 0
    if state.get("fails", 0) >= 3:
        send("Prometheus снова доступен")
    state["fails"] = 0

    prev, keep, rc = state.get("firing", {}), {}, 0
    for key, text in now.items():
        if key in prev:
            keep[key] = text
            continue
        try:
            send(f"🔥 СРАБОТАЛ {text}")
            keep[key] = text
        except Exception as exc:
            print(f"не отправлено ({key}): {exc}")
            rc = 1  # состояние не обновляем, повторим в следующую минуту
    for key, text in prev.items():
        if key in now:
            continue
        try:
            send(f"✅ СНЯТ {text.split(':')[0]}")
        except Exception as exc:
            print(f"не отправлено ({key}): {exc}")
            keep[key] = text
            rc = 1
    state["firing"] = keep
    json.dump(state, open(STATE, "w"))
    print(f"firing={len(now)} notified_state={len(keep)}")
    return rc


sys.exit(main())
