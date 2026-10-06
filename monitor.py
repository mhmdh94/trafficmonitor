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
IFACE = os.environ.get("IFACE", "").strip()


def log(msg):
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def detect_iface():
    """Detect the main network interface.
    Priority:
      1. Default route interface (most accurate)
      2. Common names: eth0, ens3, ens33, enp0s3, net0, ...
      3. First non-loopback interface that has statistics
    """
    # 1. Default route
    try:
        out = subprocess.check_output(
            ["ip", "route", "show", "default"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        parts = out.split()
        if "dev" in parts:
            iface = parts[parts.index("dev") + 1]
            if os.path.exists(f"/sys/class/net/{iface}/statistics"):
                return iface
    except Exception as e:
        log(f"default route detection failed: {e}")

    # 2. Prefer common interface names
    preferred = [
        "eth0", "ens3", "ens33", "ens18", "enp0s3", "enp1s0",
        "net0", "eno1", "em1", "bond0"
    ]
    for name in preferred:
        if os.path.exists(f"/sys/class/net/{name}/statistics"):
            return name

    # 3. First non-loopback interface
    try:
        for name in sorted(os.listdir("/sys/class/net")):
            if name == "lo":
                continue
            if os.path.exists(f"/sys/class/net/{name}/statistics"):
                return name
    except Exception:
        pass

    raise RuntimeError("could not detect network interface")


def read_bytes(iface):
    base = f"/sys/class/net/{iface}/statistics"
    with open(f"{base}/rx_bytes") as f:
        rx = int(f.read().strip())
    with open(f"{base}/tx_bytes") as f:
        tx = int(f.read().strip())
    return rx + tx


def send_telegram(text):
    url = f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage"
    body = urllib.parse.urlencode(
        {"chat_id": TG_CHAT_ID, "text": text, "parse_mode": "HTML"}
    ).encode()
    try:
        urllib.request.urlopen(
            urllib.request.Request(url, data=body, method="POST"),
            timeout=30,
        )
        return True
    except Exception as e:
        log(f"telegram error: {e}")
        return False


def human_rate(bps: float) -> str:
    units = ["B/s", "KB/s", "MB/s", "GB/s"]
    i = 0
    while bps >= 1024 and i < len(units) - 1:
        bps /= 1024
        i += 1
    return f"{bps:.1f} {units[i]}"


def main():
    iface = IFACE or detect_iface()
    min_prev_bps = (MIN_PREV_MB * 1024 * 1024) / INTERVAL

    log(
        f"started | iface={iface} | interval={INTERVAL}s | "
        f"drop>={DROP_PERCENT}% | min_prev={MIN_PREV_MB}MB"
    )

    last_total = read_bytes(iface)
    last_ts = time.time()
    prev_rate = None
    last_alert = 0.0
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

        # counter reset (reboot or interface restart)
        if delta < 0 or elapsed <= 0:
            log("counter reset detected, skipping this cycle")
            prev_rate = None
            continue

        rate = delta / elapsed
        log(f"rate={human_rate(rate)} (prev={human_rate(prev_rate) if prev_rate else 'n/a'})")

        # only compare when previous rate was meaningful
        if prev_rate is not None and prev_rate >= min_prev_bps:
            drop = (prev_rate - rate) / prev_rate * 100.0

            if drop >= DROP_PERCENT:
                if now - last_alert >= COOLDOWN:
                    msg = (
                        f"⚠️ <b>هشدار افت ترافیک</b>\n\n"
                        f"سرور: <code>{SERVER_NAME}</code>\n"
                        f"افت ترافیک: <b>{drop:.0f}٪</b>\n"
                        f"نرخ قبلی: {human_rate(prev_rate)}\n"
                        f"نرخ فعلی: {human_rate(rate)}\n\n"
                        f"احتمالاً سرویس قطع شده یا آی‌پی فیلتر شده است."
                    )
                    if send_telegram(msg):
                        last_alert = now
                        in_alert = True
                        log(f"ALERT sent: -{drop:.0f}%")
                # update prev_rate so we don't keep comparing against the old high value
                prev_rate = rate
                continue

        # traffic recovered
        if in_alert and rate >= min_prev_bps:
            msg = (
                f"✅ <b>ترافیک برگشت</b>\n\n"
                f"سرور: <code>{SERVER_NAME}</code>\n"
                f"نرخ فعلی: {human_rate(rate)}"
            )
            if send_telegram(msg):
                in_alert = False
                log("recovery message sent")

        prev_rate = rate


if __name__ == "__main__":
    main()
