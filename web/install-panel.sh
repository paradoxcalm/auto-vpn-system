#!/bin/bash
#===============================================================================
# AUTO-VPN — Central Panel Installer
# Устанавливается на ОДНОМ сервере — это твоя панель управления.
# Все VPN-ноды будут слать сюда свои ключи.
#
# Usage: bash install-panel.sh [--domain your-panel.com]
#===============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }

PANEL_DOMAIN=""
PANEL_PORT=8080

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) PANEL_DOMAIN="$2"; shift 2 ;;
        --port)   PANEL_PORT="$2"; shift 2 ;;
        *)        log_err "Unknown: $1"; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_err "Run as root"
    exit 1
fi

# ======================== INSTALL DEPS ========================
log_step "Installing dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv nginx certbot python3-certbot-nginx ufw

log_ok "Dependencies installed"

# ======================== SETUP APP ========================
log_step "Setting up panel application"

PANEL_DIR="/opt/auto-vpn-panel"
mkdir -p "$PANEL_DIR/data" "$PANEL_DIR/templates" "$PANEL_DIR/static"

# Create virtual environment
python3 -m venv "$PANEL_DIR/venv"
"$PANEL_DIR/venv/bin/pip" install -q flask gunicorn

# Copy app files (or download from GitHub)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/app.py" ]]; then
    cp "$SCRIPT_DIR/app.py" "$PANEL_DIR/app.py"
    cp -r "$SCRIPT_DIR/templates/"* "$PANEL_DIR/templates/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/static/"* "$PANEL_DIR/static/" 2>/dev/null || true
else
    log_info "Downloading panel files from GitHub..."
    REPO_URL="https://raw.githubusercontent.com/paradoxcalm/auto-vpn-system/main/web"
    curl -sf "$REPO_URL/app.py" -o "$PANEL_DIR/app.py"
    curl -sf "$REPO_URL/templates/index.html" -o "$PANEL_DIR/templates/index.html"
    curl -sf "$REPO_URL/templates/login.html" -o "$PANEL_DIR/templates/login.html"
fi

# Generate API key
API_KEY=$(openssl rand -base64 32 | tr -d '=/+' | head -c 40)

# Save config
cat > "$PANEL_DIR/.env" << EOF
API_KEY=$API_KEY
DATA_DIR=$PANEL_DIR/data
HOST=127.0.0.1
PORT=$PANEL_PORT
EOF
chmod 600 "$PANEL_DIR/.env"

log_ok "Panel application configured"

# ======================== SYSTEMD ========================
log_step "Creating systemd service"

cat > /etc/systemd/system/auto-vpn-panel.service << SERVICEEOF
[Unit]
Description=Auto VPN Central Panel
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$PANEL_DIR
EnvironmentFile=$PANEL_DIR/.env
ExecStart=$PANEL_DIR/venv/bin/gunicorn \
    --bind 127.0.0.1:$PANEL_PORT \
    --workers 2 \
    --timeout 120 \
    app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

chown -R www-data:www-data "$PANEL_DIR"
systemctl daemon-reload
systemctl enable auto-vpn-panel
systemctl start auto-vpn-panel

log_ok "Panel service started"

# ======================== NGINX ========================
log_step "Configuring Nginx"

if [[ -n "$PANEL_DOMAIN" ]]; then
    cat > /etc/nginx/sites-available/auto-vpn-panel << NGINXEOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/auto-vpn-panel /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    log_ok "Nginx configured for $PANEL_DOMAIN"

    # SSL
    log_step "Setting up SSL certificate"
    certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos --email "admin@$PANEL_DOMAIN" 2>/dev/null && {
        log_ok "SSL certificate installed"
    } || {
        log_warn "Could not get SSL cert. Set up DNS A-record first, then run:"
        log_warn "  certbot --nginx -d $PANEL_DOMAIN"
    }
else
    # No domain — just proxy on port 80
    cat > /etc/nginx/sites-available/auto-vpn-panel << NGINXEOF
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/auto-vpn-panel /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    log_warn "No domain specified. Panel is on http://SERVER_IP"
fi

# ======================== FIREWALL ========================
log_step "Configuring firewall"

ufw --force reset > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable > /dev/null 2>&1

log_ok "Firewall configured"

# ======================== SUMMARY ========================
PANEL_IP=$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  AUTO-VPN CENTRAL PANEL INSTALLED${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
if [[ -n "$PANEL_DOMAIN" ]]; then
    echo -e "  ${BOLD}Panel URL:${NC}   https://$PANEL_DOMAIN"
else
    echo -e "  ${BOLD}Panel URL:${NC}   http://$PANEL_IP"
fi
echo -e "  ${BOLD}API Key:${NC}     ${YELLOW}$API_KEY${NC}"
echo ""
echo -e "  ${BOLD}To add VPN nodes, run on each server:${NC}"
echo ""
if [[ -n "$PANEL_DOMAIN" ]]; then
    echo -e "  ${CYAN}curl -sSL https://raw.githubusercontent.com/paradoxcalm/auto-vpn-system/main/install.sh | bash -s -- \\${NC}"
    echo -e "  ${CYAN}  --api-url https://$PANEL_DOMAIN \\${NC}"
    echo -e "  ${CYAN}  --api-key $API_KEY${NC}"
else
    echo -e "  ${CYAN}curl -sSL https://raw.githubusercontent.com/paradoxcalm/auto-vpn-system/main/install.sh | bash -s -- \\${NC}"
    echo -e "  ${CYAN}  --api-url http://$PANEL_IP \\${NC}"
    echo -e "  ${CYAN}  --api-key $API_KEY${NC}"
fi
echo ""
echo -e "  ${BOLD}Optional flags for nodes:${NC}"
echo -e "    --hysteria     Install Hysteria2 (UDP/QUIC)"
echo -e "    --warp         Add Cloudflare WARP outbound"
echo -e "    --sni DOMAIN   Custom SNI domain"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Manage:${NC}"
echo -e "    systemctl status auto-vpn-panel"
echo -e "    journalctl -u auto-vpn-panel -f"
echo -e "    cat $PANEL_DIR/.env   (see API key)"
echo ""
