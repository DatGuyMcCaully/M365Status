#!/bin/bash
# ============================================================
#  M365 Service Health Dashboard — Uninstaller
#  Removes service, app files, nginx config, and service user.
#  Does NOT remove Node.js, nginx, or Let's Encrypt certs.
#
#  Usage:  sudo bash uninstall.sh
# ============================================================
set -e

APP_DIR="/opt/m365-dashboard"
SERVICE_NAME="m365-dashboard"
SERVICE_USER="m365dash"
NGINX_CONF="/etc/nginx/sites-available/m365-dashboard"
NGINX_ENABLED="/etc/nginx/sites-enabled/m365-dashboard"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}══ $1 ══${NC}"; }

[ "$EUID" -ne 0 ] && err "Please run as root:  sudo bash uninstall.sh"

echo ""
echo -e "${RED}  M365 Health Dashboard — Uninstaller${NC}"
echo ""
echo "  This will remove:"
echo "    • systemd service ($SERVICE_NAME)"
echo "    • App files ($APP_DIR)"
echo "    • nginx config ($NGINX_CONF)"
echo "    • Service user ($SERVICE_USER)"
echo ""
echo "  This will NOT remove:"
echo "    • Node.js"
echo "    • nginx"
echo "    • Let's Encrypt certificates"
echo ""
read -rp "  Are you sure? [y/N]: " CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]] && echo "  Aborted." && exit 0

# ── Backup option ─────────────────────────────────────────────
echo ""
read -rp "  Back up config.json and certs before removing? [Y/n]: " DO_BACKUP
DO_BACKUP="${DO_BACKUP,,}"

if [[ "$DO_BACKUP" != "n" && "$DO_BACKUP" != "no" ]]; then
  BACKUP_DIR="/root/m365-dashboard-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [ -f "$APP_DIR/config.json" ] && cp "$APP_DIR/config.json" "$BACKUP_DIR/" && info "config.json backed up"
  [ -d "$APP_DIR/certs" ]      && cp -r "$APP_DIR/certs" "$BACKUP_DIR/" && info "certs backed up"
  info "Backup saved to: $BACKUP_DIR"
fi

# ── Stop and disable service ──────────────────────────────────
section "Stopping service"
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl stop "$SERVICE_NAME"
  info "Service stopped"
else
  warn "Service was not running"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl disable "$SERVICE_NAME"
  info "Service disabled"
fi

# ── Remove systemd unit ───────────────────────────────────────
section "Removing systemd unit"
if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  info "Systemd unit removed"
else
  warn "Systemd unit not found — skipping"
fi

# ── Remove nginx config ───────────────────────────────────────
section "Removing nginx config"
NGINX_REMOVED=false
[ -f "$NGINX_ENABLED" ] && rm -f "$NGINX_ENABLED" && NGINX_REMOVED=true
[ -f "$NGINX_CONF" ]    && rm -f "$NGINX_CONF"    && NGINX_REMOVED=true

if [ "$NGINX_REMOVED" = true ]; then
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    info "nginx config removed and reloaded"
  else
    warn "nginx config test failed after removal — reload manually"
  fi
else
  warn "nginx config not found — skipping"
fi

# ── Remove app files ──────────────────────────────────────────
section "Removing app files"
if [ -d "$APP_DIR" ]; then
  rm -rf "$APP_DIR"
  info "App directory removed ($APP_DIR)"
else
  warn "App directory not found — skipping"
fi

# ── Remove service user ───────────────────────────────────────
section "Removing service user"
if id "$SERVICE_USER" &>/dev/null; then
  userdel "$SERVICE_USER" 2>/dev/null || true
  info "User '$SERVICE_USER' removed"
else
  warn "User '$SERVICE_USER' not found — skipping"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Uninstall complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
if [[ "$DO_BACKUP" != "n" && "$DO_BACKUP" != "no" ]]; then
  echo "  Your config and certs are at: $BACKUP_DIR"
  echo "  Keep these safe if you plan to reinstall."
fi
echo ""
