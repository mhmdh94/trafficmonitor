#!/bin/bash
set -e

# TODO: replace USERNAME/REPO with your own repo
REPO_RAW="https://raw.githubusercontent.com/mhmdh94/REPO/main"

INSTALL_DIR="/opt/traffic-monitor"
ENV_FILE="/etc/traffic-monitor.env"
SERVICE="traffic-monitor"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

if [ "$1" = "--uninstall" ]; then
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE.service" "$ENV_FILE"
  rm -rf "$INSTALL_DIR"
  systemctl daemon-reload
  echo "Uninstalled."
  exit 0
fi

# make sure curl and python3 exist
for pkg in curl python3; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq "$pkg"
  fi
done

# keep previous values as defaults when re-running
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

# works both with: bash <(curl ...)  and  curl ... | bash
if [ -t 0 ]; then TTY=/dev/stdin; else TTY=/dev/tty; fi

ask() {
  local var="$1" prompt="$2" def="$3" val
  while true; do
    if [ -n "$def" ]; then
      read -r -p "$prompt [$def]: " val < "$TTY" || true
      val="${val:-$def}"
    else
      read -r -p "$prompt: " val < "$TTY" || true
    fi
    [ -n "$val" ] && break
    echo "This value is required."
  done
  printf -v "$var" '%s' "$val"
}

echo "=== Traffic Monitor installer ==="
ask TG_TOKEN     "Telegram bot token"                       "${TG_TOKEN:-}"
ask TG_CHAT_ID   "Telegram chat id"                         "${TG_CHAT_ID:-}"
ask SERVER_NAME  "Server name"                              "${SERVER_NAME:-$(hostname)}"
ask INTERVAL     "Check interval in seconds"                "${INTERVAL:-300}"
ask DROP_PERCENT "Alert when traffic drops by (%)"          "${DROP_PERCENT:-50}"
ask MIN_PREV_MB  "Min traffic per interval to compare (MB)" "${MIN_PREV_MB:-20}"
ask COOLDOWN     "Seconds between repeated alerts"          "${COOLDOWN:-1800}"

# validate the bot token
if ! curl -fsS --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/getMe" >/dev/null; then
  echo "Telegram token is invalid or Telegram is unreachable from this server."
  exit 1
fi

mkdir -p "$INSTALL_DIR"
curl -fsSL "$REPO_RAW/monitor.py" -o "$INSTALL_DIR/monitor.py"

cat > "$ENV_FILE" << EOF
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"
INTERVAL="$INTERVAL"
DROP_PERCENT="$DROP_PERCENT"
MIN_PREV_MB="$MIN_PREV_MB"
COOLDOWN="$COOLDOWN"
EOF
chmod 600 "$ENV_FILE"

cat > "/etc/systemd/system/$SERVICE.service" << EOF
[Unit]
Description=Server traffic drop monitor
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 $INSTALL_DIR/monitor.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"

# test message
curl -fsS --max-time 15 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=✅ Traffic monitor installed on ${SERVER_NAME}" >/dev/null \
  && echo "Test message sent to Telegram." \
  || echo "Warning: could not send test message. Check chat id."

echo "Done. Logs: journalctl -u $SERVICE -f"
