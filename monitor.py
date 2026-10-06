#!/usr/bin/env python3
import os
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime

TG_TOKEN = os.environ["TG_TOKEN"]
TG_CHAT_ID = os.environ["TG_CHAT_ID"]
SERVER_NAME = os.environ.get("SERVER_NAME", os.uname().nodename)
INTERVAL = int(os.environ.get("INTERVAL", "300"))
DROP_PERCENT = float(os.environ.get("DROP_PERCENT", "50"))
MIN_PREV_MB = float(os.environ.get("MIN_PREV_MB", "20"))
COOLDOWN = int(os.environ.get("COOLDOWN", "1800"))
IFACE = os.environ.get("IFACE", "")


def log(msg):
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def detect_iface():
    out = subprocess.check_output(["ip", "route", "show", "default"]).decode()
    parts = out.split()
    return parts[parts.index("dev") + 1]


def read_bytes(iface):
    base = f"/sys/class/net/{iface}/statistics"
    with open(f"{base}/rx_bytes") as f:
        rx = int(f.read())
    with open(f"{base}/tx_bytes") as f:
        tx = int(f.read())
    return rx + tx


def send_telegram(text):
    url = f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage"
    body = urllib.parse.urlencode({"chat_id": TG_CHAT_ID, "text": text}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=30)
    except Exception as e:
        log(f"telegram error: {e}")


def human_rate(bps):
    units = ["B/s", "KB/s", "MB/s", "GB/s"]
    i = 0
    while bps >= 1024 and i < len(units) - 1:
        bps /= 1024
        i += 1
    return f"{bps:.1f} {units[i]}"


def main():
    iface = IFACE or detect_iface()
    min_prev_bps = (MIN_PREV_MB * 1024 * 1024) / INTERVAL
    log(f"started: iface={iface} interval={INTERVAL}s drop>={DROP_PERCENT}%")

    last_total = read_bytes(iface)
    last_ts = time.time()
    prev_rate = None
    last_alert = 0
    in_alert = False

    while True:
        time.sleep(INTERVAL)
        try:
            total = read_bytes(iface)
        except Exception as e:
            log(f"read error: {e}")
            continue

        now = time.time()
        delta = total - last_total
        elapsed = now - last_ts
        last_total, last_ts = total, now

        if delta < 0 or elapsed <= 0:  # counter reset (reboot)
            prev_rate = None
            continue

        rate = delta / elapsed

        if prev_rate is not None and prev_rate >= min_prev_bps:
            drop = (prev_rate - rate) / prev_rate * 100
            if drop >= DROP_PERCENT and now - last_alert >= COOLDOWN:
                send_telegram(
                    f"⚠️ هشدار افت ترافیک\n\n"
                    f"سرور: {SERVER_NAME}\n"
                    f"افت ترافیک: {drop:.0f}٪\n"
                    f"نرخ قبلی: {human_rate(prev_rate)}\n"
                    f"نرخ فعلی: {human_rate(rate)}\n\n"
                    f"احتمالاً سرویس قطع شده یا آیپی فیلتر شده است."
                )
                last_alert = now
                in_alert = True
                log(f"ALERT: -{drop:.0f}%")
                prev_rate = rate
                continue

        if in_alert and rate >= min_prev_bps:
            send_telegram(
                f"✅ ترافیک برگشت\n\n"
                f"سرور: {SERVER_NAME}\n"
                f"نرخ فعلی: {human_rate(rate)}"
            )
            in_alert = False

        prev_rate = rate


if __name__ == "__main__":
    main()
