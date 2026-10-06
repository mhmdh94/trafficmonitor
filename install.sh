#!/bin/bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/mhmdh94/trafficmonitor/main"
INSTALL_DIR="/opt/traffic-monitor"
ENV_FILE="/etc/traffic-monitor.env"
SERVICE="traffic-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

# ---------- helpers ----------
need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)."
    exit 1
  fi
}

usage() {
  cat << EOF
Usage: $0 [command]

Commands:
  (no args)     Install or reconfigure
  start         Start the service
  stop          Stop the service
  restart       Restart the service
  status        Show service status + last logs
  edit          Edit config file (/etc/traffic-monitor.env)
  uninstall     Remove everything
  help          Show this help

Examples:
  curl -fsSL .../install.sh | sudo bash
  sudo bash install.sh start
  sudo bash install.sh edit
EOF
}

# ---------- commands ----------
cmd_start() {
  need_root
  systemctl start "$SERVICE"
  echo "Started."
  systemctl --no-pager -l status "$SERVICE" || true
}

cmd_stop() {
  need_root
  systemctl stop "$SERVICE"
  echo "Stopped."
}

cmd_restart() {
  need_root
  systemctl restart "$SERVICE"
  echo "Restarted."
  systemctl --no-pager -l status "$SERVICE" || true
}

cmd_status() {
  systemctl --no-pager -l status "$SERVICE" || true
  echo
  echo "=== Last 20 log lines ==="
  journalctl -u "$SERVICE" -n 20 --no-pager || true
}

cmd_edit() {
  need_root
  if [ ! -f "$ENV_FILE" ]; then
    echo "Config file not found: $ENV_FILE"
    echo "Run the installer first."
    exit 1
  fi
  ${EDITOR:-nano} "$ENV_FILE"
  echo
  read -r -p "Restart service to apply changes? [Y/n] " ans
  if [[ "${ans:-Y}" =~ ^[Yy]$ ]]; then
    systemctl restart "$SERVICE"
    echo "Service restarted."
  else
    echo "Remember to restart later: systemctl restart $SERVICE"
  fi
}

cmd_uninstall() {
  need_root
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$ENV_FILE"
  rm -rf "$INSTALL_DIR"
  systemctl daemon-reload
  echo "Uninstalled."
}

cmd_install() {
  need_root

  # dependencies
  for pkg in curl python3; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq "$pkg"
    fi
  done

  # keep previous values as defaults
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi

  if [ -t 0 ]; then TTY=/dev/stdin; else TTY=/dev/tty; fi

  ask() {
    local var="$1" prompt="$2" def="${3:-}" val
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

  # optional: force interface
  echo
  echo "Network interface (leave empty for auto-detect):"
  echo "  Common names: eth0, ens3, net0, enp0s3 ..."
  ask IFACE        "Interface name (empty = auto)"            "${IFACE:-}"

  # validate bot token
  if ! curl -fsS --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/getMe" >/dev/null; then
    echo "Telegram token is invalid or Telegram is unreachable from this server."
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$REPO_RAW/monitor.py" -o "$INSTALL_DIR/monitor.py"
  chmod +x "$INSTALL_DIR/monitor.py"

  cat > "$ENV_FILE" << EOF
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"
INTERVAL="$INTERVAL"
DROP_PERCENT="$DROP_PERCENT"
MIN_PREV_MB="$MIN_PREV_MB"
COOLDOWN="$COOLDOWN"
IFACE="$IFACE"
EOF
  chmod 600 "$ENV_FILE"

  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Server traffic drop monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 $INSTALL_DIR/monitor.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"

  # test message
  if curl -fsS --max-time 15 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=✅ Traffic monitor installed on ${SERVER_NAME}" >/dev/null; then
    echo "Test message sent to Telegram."
  else
    echo "Warning: could not send test message. Check chat id / start the bot with /start."
  fi

  echo
  echo "Done."
  echo "  Logs:    journalctl -u $SERVICE -f"
  echo "  Status:  systemctl status $SERVICE"
  echo "  Edit:    sudo bash $0 edit"
  echo "  Restart: sudo bash $0 restart"
}

# ---------- main ----------
case "${1:-}" in
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  status)     cmd_status ;;
  edit)       cmd_edit ;;
  uninstall|--uninstall)
              cmd_uninstall ;;
  help|-h|--help)
              usage ;;
  "")         cmd_install ;;
  *)
              echo "Unknown command: $1"
              usage
              exit 1
              ;;
esac
