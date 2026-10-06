#!/bin/bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/mhmdh94/trafficmonitor/main"
INSTALL_DIR="/opt/traffic-monitor"
ENV_FILE="/etc/traffic-monitor.env"
SERVICE="traffic-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
BIN_LINK="/usr/local/bin/tm"

# ---------- helpers ----------
need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)."
    exit 1
  fi
}

usage() {
  cat << EOF
Usage: tm [command] [options]

Commands:
  (no args) / menu   Interactive management menu
  install            Install or reconfigure
  start              Start the service
  stop               Stop the service
  restart            Restart the service
  status             Show status + last logs
  logs               Follow live logs
  edit               Edit config
  uninstall          Remove everything
  help               Show this help

Install options (can be passed with install):
  --token TOKEN          Telegram bot token
  --chat-id ID           Telegram chat id
  --name NAME            Server name
  --interval SECONDS     Check interval (default 300)
  --drop PERCENT         Drop percent to alert (default 50)
  --min-mb MB            Min traffic to compare (default 20)
  --cooldown SECONDS     Cooldown between alerts (default 1800)
  --iface NAME           Network interface (empty = auto)

Examples:
  # Interactive install
  curl -fsSL .../install.sh | sudo bash

  # Non-interactive install (token + chat-id required)
  curl -fsSL .../install.sh | sudo bash -s -- install \\
    --token "123456:ABC-DEF" \\
    --chat-id "97313299" \\
    --name "sweden1"

  # After install
  sudo tm                  # open menu
  sudo tm logs
  sudo tm restart
EOF
}

# ---------- commands ----------
cmd_start() {
  need_root
  systemctl start "$SERVICE"
  echo "✅ Started."
  systemctl --no-pager -l status "$SERVICE" || true
}

cmd_stop() {
  need_root
  systemctl stop "$SERVICE"
  echo "⏹  Stopped."
}

cmd_restart() {
  need_root
  systemctl restart "$SERVICE"
  echo "🔄 Restarted."
  systemctl --no-pager -l status "$SERVICE" || true
}

cmd_status() {
  systemctl --no-pager -l status "$SERVICE" || true
  echo
  echo "=== Last 20 log lines ==="
  journalctl -u "$SERVICE" -n 20 --no-pager || true
}

cmd_logs() {
  echo "Following logs (Ctrl+C to exit)..."
  journalctl -u "$SERVICE" -f
}

cmd_edit() {
  need_root
  if [ ! -f "$ENV_FILE" ]; then
    echo "Config file not found: $ENV_FILE"
    echo "Run install first."
    exit 1
  fi
  ${EDITOR:-nano} "$ENV_FILE"
  echo
  read -r -p "Restart service to apply changes? [Y/n] " ans || true
  if [[ "${ans:-Y}" =~ ^[Yy]$ ]]; then
    systemctl restart "$SERVICE"
    echo "✅ Service restarted."
  else
    echo "Remember to restart later: sudo tm restart"
  fi
}

cmd_uninstall() {
  need_root
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$ENV_FILE" "$BIN_LINK"
  rm -rf "$INSTALL_DIR"
  systemctl daemon-reload
  echo "🗑  Uninstalled completely."
}

cmd_menu() {
  need_root
  while true; do
    clear
    echo "========================================"
    echo "     Traffic Monitor - Management"
    echo "========================================"
    echo
    systemctl is-active --quiet "$SERVICE" 2>/dev/null && \
      echo "  Status:  🟢 Running" || echo "  Status:  🔴 Stopped"
    if [ -f "$ENV_FILE" ]; then
      # shellcheck disable=SC1090
      source "$ENV_FILE" 2>/dev/null || true
      echo "  Server:  ${SERVER_NAME:-?}"
      echo "  Iface:   ${IFACE:-auto}"
      echo "  Interval:${INTERVAL:-?}s | Drop: ${DROP_PERCENT:-?}%"
    fi
    echo
    echo "  1) Status + last logs"
    echo "  2) Live logs (follow)"
    echo "  3) Start"
    echo "  4) Stop"
    echo "  5) Restart"
    echo "  6) Edit config"
    echo "  7) Reinstall / Reconfigure"
    echo "  8) Uninstall"
    echo "  0) Exit"
    echo
    read -r -p "Choose [0-8]: " choice || true
    case "${choice:-}" in
      1) cmd_status; read -r -p "Press Enter..." ;;
      2) cmd_logs ;;
      3) cmd_start; read -r -p "Press Enter..." ;;
      4) cmd_stop; read -r -p "Press Enter..." ;;
      5) cmd_restart; read -r -p "Press Enter..." ;;
      6) cmd_edit; read -r -p "Press Enter..." ;;
      7) cmd_install; read -r -p "Press Enter..." ;;
      8)
        read -r -p "Are you sure? Type 'yes' to uninstall: " conf
        if [ "$conf" = "yes" ]; then
          cmd_uninstall
          exit 0
        fi
        ;;
      0|q|Q) exit 0 ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

# parse install flags into variables
parse_install_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --token)
        TG_TOKEN="$2"; shift 2 ;;
      --chat-id|--chatid)
        TG_CHAT_ID="$2"; shift 2 ;;
      --name|--server)
        SERVER_NAME="$2"; shift 2 ;;
      --interval)
        INTERVAL="$2"; shift 2 ;;
      --drop|--drop-percent)
        DROP_PERCENT="$2"; shift 2 ;;
      --min-mb|--min-prev-mb)
        MIN_PREV_MB="$2"; shift 2 ;;
      --cooldown)
        COOLDOWN="$2"; shift 2 ;;
      --iface|--interface)
        IFACE="$2"; shift 2 ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
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

  # parse any CLI flags passed after "install"
  parse_install_args "$@"

  if [ -t 0 ]; then TTY=/dev/stdin; else TTY=/dev/tty; fi

  # ask that REQUIRES a value (only if not already set via flag/env)
  ask_required() {
    local var="$1" prompt="$2" def="${3:-}" val
    # if already has value → skip asking
    eval "local current=\${$var:-}"
    if [ -n "$current" ]; then
      return 0
    fi
    while true; do
      if [ -n "$def" ]; then
        read -r -p "$prompt [$def]: " val < "$TTY" || true
        val="${val:-$def}"
      else
        read -r -p "$prompt: " val < "$TTY" || true
      fi
      if [ -n "$val" ]; then
        break
      fi
      echo "This value is required."
    done
    printf -v "$var" '%s' "$val"
  }

  # ask that ALLOWS empty value
  ask_optional() {
    local var="$1" prompt="$2" def="${3:-}" val
    eval "local current=\${$var:-}"
    if [ -n "${current+x}" ] && [ -n "$current" ]; then
      return 0
    fi
    # even if empty string was explicitly set via --iface "", respect it
    if [ -n "${current+x}" ]; then
      return 0
    fi
    if [ -n "$def" ]; then
      read -r -p "$prompt [$def]: " val < "$TTY" || true
      val="${val:-$def}"
    else
      read -r -p "$prompt: " val < "$TTY" || true
    fi
    printf -v "$var" '%s' "$val"
  }

  echo "=== Traffic Monitor installer ==="

  # Required
  ask_required TG_TOKEN     "Telegram bot token"                       "${TG_TOKEN:-}"
  ask_required TG_CHAT_ID   "Telegram chat id"                         "${TG_CHAT_ID:-}"
  ask_required SERVER_NAME  "Server name"                              "${SERVER_NAME:-$(hostname)}"
  ask_required INTERVAL     "Check interval in seconds"                "${INTERVAL:-300}"
  ask_required DROP_PERCENT "Alert when traffic drops by (%)"          "${DROP_PERCENT:-50}"
  ask_required MIN_PREV_MB  "Min traffic per interval to compare (MB)" "${MIN_PREV_MB:-20}"
  ask_required COOLDOWN     "Seconds between repeated alerts"          "${COOLDOWN:-1800}"

  # Optional interface
  echo
  echo "Network interface (leave empty for auto-detect):"
  echo "  Common names: eth0, ens3, net0, enp0s3 ..."
  # special handling: if IFACE was never set, allow empty
  if [ -z "${IFACE+x}" ]; then
    ask_optional IFACE "Interface name (empty = auto)" ""
  fi

  # final safety defaults
  INTERVAL="${INTERVAL:-300}"
  DROP_PERCENT="${DROP_PERCENT:-50}"
  MIN_PREV_MB="${MIN_PREV_MB:-20}"
  COOLDOWN="${COOLDOWN:-1800}"
  IFACE="${IFACE:-}"

  # validate bot token
  if ! curl -fsS --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/getMe" >/dev/null; then
    echo "Telegram token is invalid or Telegram is unreachable from this server."
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$REPO_RAW/monitor.py" -o "$INSTALL_DIR/monitor.py"
  chmod +x "$INSTALL_DIR/monitor.py"

  # install this script itself so "tm" command works offline
  curl -fsSL "$REPO_RAW/install.sh" -o "$INSTALL_DIR/install.sh"
  chmod +x "$INSTALL_DIR/install.sh"
  ln -sf "$INSTALL_DIR/install.sh" "$BIN_LINK"

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
  echo "✅ Done."
  echo
  echo "  Management menu:  sudo tm"
  echo "  Live logs:        sudo tm logs"
  echo "  Status:           sudo tm status"
  echo "  Edit config:      sudo tm edit"
  echo "  Uninstall:        sudo tm uninstall"
}

# ---------- main ----------
# Collect remaining args after the command
CMD="${1:-}"
shift || true

case "$CMD" in
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  status)     cmd_status ;;
  logs)       cmd_logs ;;
  edit)       cmd_edit ;;
  uninstall|--uninstall)
              cmd_uninstall ;;
  menu)       cmd_menu ;;
  install)
              cmd_install "$@" ;;
  help|-h|--help)
              usage ;;
  "")
              # if already installed → open menu, otherwise install
              if [ -f "$SERVICE_FILE" ] || [ -f "$ENV_FILE" ]; then
                cmd_menu
              else
                cmd_install
              fi
              ;;
  # also allow flags directly as first args (treat as install)
  --token|--chat-id|--chatid|--name|--server|--interval|--drop|--min-mb|--cooldown|--iface|--interface)
              cmd_install "$CMD" "$@"
              ;;
  *)
              echo "Unknown command: $CMD"
              usage
              exit 1
              ;;
esac
