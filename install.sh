#!/bin/bash
#===============================================================================
# AUTO-VPN SYSTEM — Node Installer (Cloudflare CDN Edition)
# Автоматическая установка VPN-ноды: VLESS + WebSocket + Nginx + Cloudflare
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/ParadoxCalm/auto-vpn-system/main/install.sh | bash -s -- \
#     --api-url http://PANEL_IP --api-key YOUR_KEY --domain SUB.jetsflare.com
#
# Options:
#   --api-url URL        Central panel URL
#   --api-key KEY        API key for panel auth
#   --domain DOMAIN      Cloudflare subdomain (e.g. nl.jetsflare.com)
#   --name NAME          Custom node name (default: auto from geo)
#   --no-report          Don't send keys to central panel
#===============================================================================

set -euo pipefail

# ======================== COLORS ========================
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

# ======================== DEFAULTS ========================
API_URL=""
API_KEY=""
CF_DOMAIN=""
NODE_NAME=""
NO_REPORT=false
XRAY_PORT=10001
WS_PATH="/ws"

INSTALL_DIR="/opt/auto-vpn"
CONFIG_DIR="/etc/xray"
DATA_DIR="/opt/auto-vpn/data"
SCRIPTS_URL="https://raw.githubusercontent.com/ParadoxCalm/auto-vpn-system/main"

# ======================== PARSE ARGS ========================
while [[ $# -gt 0 ]]; do
    case $1 in
        --api-url)   API_URL="$2"; shift 2 ;;
        --api-key)   API_KEY="$2"; shift 2 ;;
        --domain)    CF_DOMAIN="$2"; shift 2 ;;
        --name)      NODE_NAME="$2"; shift 2 ;;
        --no-report) NO_REPORT=true; shift ;;
        *)           log_err "Unknown option: $1"; exit 1 ;;
    esac
done

# ======================== VALIDATE ========================
if [[ -z "$CF_DOMAIN" ]]; then
    log_err "--domain is required (e.g. --domain nl.jetsflare.com)"
    log_err "This must be a Cloudflare-proxied subdomain pointing to this server's IP"
    exit 1
fi

# ======================== PRE-CHECKS ========================
log_step "Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    log_err "This script must be run as root"
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$ID"
    OS_VERSION="$VERSION_ID"
else
    log_err "Cannot detect OS"
    exit 1
fi

if [[ "$OS_NAME" != "ubuntu" ]]; then
    log_err "Only Ubuntu 22.04/24.04 is supported. Detected: $OS_NAME $OS_VERSION"
    exit 1
fi

log_ok "OS: Ubuntu $OS_VERSION"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  XRAY_ARCH="64" ;;
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    *)       log_err "Unsupported architecture: $ARCH"; exit 1 ;;
esac
log_ok "Architecture: $ARCH"

# ======================== GEO DETECTION ========================
log_step "Detecting server location"

detect_geo() {
    local geo_json
    geo_json=$(curl -sf --max-time 10 "https://ipinfo.io/json" 2>/dev/null) || \
    geo_json=$(curl -sf --max-time 10 "https://ipapi.co/json" 2>/dev/null) || \
    geo_json=$(curl -sf --max-time 10 "http://ip-api.com/json" 2>/dev/null) || \
    { log_warn "Could not detect geo"; echo '{}'; return; }
    echo "$geo_json"
}

GEO_JSON=$(detect_geo)

SERVER_IP=$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null || \
            curl -sf --max-time 10 https://ifconfig.me 2>/dev/null || \
            echo "unknown")

read -r COUNTRY_CODE COUNTRY_NAME CITY ISP < <(echo "$GEO_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    cc = d.get('country_code') or d.get('countryCode') or d.get('country') or 'XX'
    if len(cc) > 2:
        cc = d.get('countryCode', 'XX')
    name = d.get('country_name') or d.get('country') or 'Unknown'
    if len(name) == 2:
        name = 'Unknown'
    city = d.get('city') or 'Unknown'
    isp = d.get('org') or d.get('isp') or 'Unknown'
    print(f'{cc}\t{name}\t{city}\t{isp}')
except:
    print('XX\tUnknown\tUnknown\tUnknown')
" 2>/dev/null || echo "XX	Unknown	Unknown	Unknown")

COUNTRY_CODE="${COUNTRY_CODE:-XX}"
COUNTRY_NAME="${COUNTRY_NAME:-Unknown}"
CITY="${CITY:-Unknown}"
ISP="${ISP:-Unknown}"

if [[ -z "$NODE_NAME" ]]; then
    CITY_CLEAN=$(echo "$CITY" | tr ' ' '-' | tr -cd '[:alnum:]-')
    NODE_NAME="${COUNTRY_CODE}-${CITY_CLEAN}"
fi

log_ok "IP: $SERVER_IP"
log_ok "Location: $CITY, $COUNTRY_NAME ($COUNTRY_CODE)"
log_ok "Node name: $NODE_NAME"
log_ok "Cloudflare domain: $CF_DOMAIN"

# ======================== INSTALL DEPS ========================
log_step "Installing dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget unzip jq openssl \
    python3 python3-pip nginx \
    qrencode \
    ufw fail2ban \
    cron socat net-tools

# Install speedtest-cli for bandwidth monitoring
pip3 install speedtest-cli -q 2>/dev/null || true

log_ok "Dependencies installed"

# ======================== WARP (IP PROTECTION) ========================
log_step "Installing Cloudflare WARP (outbound IP protection)"

WARP_INSTALLED=false

# Check if WARP is already running
if command -v warp-cli &>/dev/null && warp-cli status 2>/dev/null | grep -qi "connected"; then
    log_ok "WARP already running"
    WARP_INSTALLED=true
else
    # Add Cloudflare WARP repo
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq 2>/dev/null

    if apt-get install -y -qq cloudflare-warp 2>/dev/null; then
        # Register WARP (free tier — enough for IP masking)
        warp-cli --accept-tos registration new 2>/dev/null || true
        # Set WARP to proxy mode (SOCKS5 on 127.0.0.1:40000) — won't touch system routes
        warp-cli --accept-tos mode proxy 2>/dev/null || true
        warp-cli --accept-tos proxy port 40000 2>/dev/null || true
        warp-cli --accept-tos connect 2>/dev/null || true

        sleep 3
        if warp-cli status 2>/dev/null | grep -qi "connected"; then
            log_ok "WARP installed (SOCKS5 proxy on 127.0.0.1:40000)"
            WARP_INSTALLED=true
        else
            log_warn "WARP installed but not connected — VPS IP will be visible to websites"
        fi
    else
        log_warn "Could not install WARP — VPS IP will be visible to websites"
    fi
fi

# ======================== TCP BBR ========================
log_step "Enabling TCP BBR"

if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    cat >> /etc/sysctl.conf << 'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
SYSCTL
    sysctl -p > /dev/null 2>&1
    log_ok "TCP BBR enabled"
else
    log_ok "TCP BBR already active"
fi

# ======================== INSTALL XRAY ========================
log_step "Installing Xray-core"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"

MIN_XRAY_VERSION="25.12.8"
XRAY_VERSION=$(curl -sf "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' | tr -d 'v')

# Verify minimum version (v25.12.8+ required for Aparecium resistance)
XRAY_MAJOR=$(echo "$XRAY_VERSION" | cut -d. -f1)
XRAY_MINOR=$(echo "$XRAY_VERSION" | cut -d. -f2)
XRAY_PATCH=$(echo "$XRAY_VERSION" | cut -d. -f3)
if [[ "$XRAY_MAJOR" -lt 25 ]] || [[ "$XRAY_MAJOR" -eq 25 && "$XRAY_MINOR" -lt 12 ]] || [[ "$XRAY_MAJOR" -eq 25 && "$XRAY_MINOR" -eq 12 && "$XRAY_PATCH" -lt 8 ]]; then
    log_warn "Latest Xray ($XRAY_VERSION) is below minimum v$MIN_XRAY_VERSION — forcing $MIN_XRAY_VERSION"
    XRAY_VERSION="$MIN_XRAY_VERSION"
fi

XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

log_info "Downloading Xray-core v${XRAY_VERSION}..."
wget -q "$XRAY_URL" -O /tmp/xray.zip
unzip -qo /tmp/xray.zip -d /tmp/xray
cp /tmp/xray/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
mkdir -p /usr/local/share/xray
cp /tmp/xray/*.dat /usr/local/share/xray/ 2>/dev/null || true
rm -rf /tmp/xray /tmp/xray.zip

log_ok "Xray-core v${XRAY_VERSION} installed"

# ======================== GENERATE UUID ========================
log_step "Generating keys"

UUID=$(/usr/local/bin/xray uuid)

log_ok "UUID: $UUID"

# ======================== XRAY CONFIG (VLESS + WebSocket) ========================
log_step "Configuring Xray (VLESS + WebSocket)"

cat > "$CONFIG_DIR/config.json" << XRAYCONF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "stats": {},
    "api": {
        "tag": "api",
        "listen": "127.0.0.1:10085",
        "services": ["HandlerService", "StatsService"]
    },
    "policy": {
        "levels": {
            "0": {
                "statsUserUplink": true,
                "statsUserDownlink": true
            }
        },
        "system": {
            "statsInboundUplink": true,
            "statsInboundDownlink": true
        }
    },
    "inbounds": [
        {
            "tag": "api-in",
            "listen": "127.0.0.1",
            "port": 10085,
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"}
        },
        {
            "tag": "vless-ws",
            "listen": "127.0.0.1",
            "port": $XRAY_PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "email": "default@panel",
                        "level": 0
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "$WS_PATH"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        {
            "tag": "warp",
            "protocol": "socks",
            "settings": {
                "servers": [{"address": "127.0.0.1", "port": 40000}]
            }
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
            {"type": "field", "outboundTag": "block", "protocol": ["bittorrent"]},
            {"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]},
            {"type": "field", "outboundTag": "warp", "inboundTag": ["vless-ws"]}
        ]
    }
}
XRAYCONF

mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray
chmod 755 /var/log/xray

log_ok "Xray config created (VLESS+WS on 127.0.0.1:$XRAY_PORT)"

# ======================== XRAY SERVICE ========================
log_step "Creating Xray service"

cat > /etc/systemd/system/xray.service << 'SERVICE'
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable xray
systemctl start xray

sleep 2
if systemctl is-active --quiet xray; then
    log_ok "Xray service is running"
else
    log_err "Xray failed to start. Check: journalctl -u xray"
    journalctl -u xray --no-pager -n 10
fi

# ======================== SSL CERTIFICATE ========================
log_step "Generating SSL certificate for Cloudflare"

mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/cloudflare.key \
    -out /etc/nginx/ssl/cloudflare.pem \
    -days 3650 -subj "/CN=$CF_DOMAIN" 2>/dev/null

log_ok "SSL certificate generated"

# ======================== NGINX (WebSocket Reverse Proxy) ========================
log_step "Configuring Nginx reverse proxy"

cat > /etc/nginx/sites-available/vless-ws << NGINXEOF
server {
    listen 443 ssl http2;
    server_name $CF_DOMAIN;

    ssl_certificate /etc/nginx/ssl/cloudflare.pem;
    ssl_certificate_key /etc/nginx/ssl/cloudflare.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # WebSocket proxy to Xray
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Normal page — looks like regular website
    location / {
        return 200 '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome to $CF_DOMAIN</h1></body></html>';
        add_header Content-Type text/html;
    }
}

server {
    listen 80;
    server_name $CF_DOMAIN;
    return 301 https://\$host\$request_uri;
}
NGINXEOF

ln -sf /etc/nginx/sites-available/vless-ws /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t 2>/dev/null && systemctl restart nginx
log_ok "Nginx configured ($CF_DOMAIN:443 → Xray WS)"

# ======================== FIREWALL ========================
log_step "Configuring firewall"

ufw --force reset > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable > /dev/null 2>&1
log_ok "Firewall configured (SSH, 80, 443)"

# ======================== FAIL2BAN ========================
log_step "Configuring fail2ban"

cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 3
F2B

systemctl enable fail2ban
systemctl restart fail2ban
log_ok "Fail2ban configured"

# ======================== LOG ROTATION ========================
cat > /etc/logrotate.d/xray << 'LOGROTATE'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl restart xray > /dev/null 2>&1 || true
    endscript
}
LOGROTATE

log_ok "Log rotation configured"

# ======================== GENERATE CLIENT LINK ========================
log_step "Generating client configuration"

VLESS_LINK="vless://${UUID}@${CF_DOMAIN}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&fp=chrome&type=ws&path=%2Fws&host=${CF_DOMAIN}#${NODE_NAME}"
VLESS_TEMPLATE="vless://{uuid}@${CF_DOMAIN}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&fp=chrome&type=ws&path=%2Fws&host=${CF_DOMAIN}#{node_name}"

echo "$VLESS_LINK" > "$DATA_DIR/vless-link.txt"

# Save node data
cat > "$DATA_DIR/keys.json" << EOF
{
    "node_name": "$NODE_NAME",
    "server_ip": "$SERVER_IP",
    "cf_domain": "$CF_DOMAIN",
    "country_code": "$COUNTRY_CODE",
    "country_name": "$COUNTRY_NAME",
    "city": "$CITY",
    "uuid": "$UUID",
    "ws_path": "$WS_PATH",
    "xray_port": $XRAY_PORT,
    "vless_link": "$VLESS_LINK",
    "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
chmod 600 "$DATA_DIR/keys.json"

# QR code
qrencode -t UTF8 "$VLESS_LINK" > "$DATA_DIR/qr-code.txt" 2>/dev/null || true

# ======================== REPORT TO PANEL ========================
if [[ "$NO_REPORT" == false && -n "$API_URL" && -n "$API_KEY" ]]; then
    log_step "Reporting to central panel"

    REPORT_DATA=$(cat << REPORTJSON
{
    "node_name": "$NODE_NAME",
    "server_ip": "$SERVER_IP",
    "cf_domain": "$CF_DOMAIN",
    "country_code": "$COUNTRY_CODE",
    "country_name": "$COUNTRY_NAME",
    "city": "$CITY",
    "isp": "$ISP",
    "vless_link": "$VLESS_LINK",
    "vless_link_template": "$VLESS_TEMPLATE",
    "uuid": "$UUID",
    "ws_path": "$WS_PATH",
    "xray_version": "$XRAY_VERSION",
    "protocols": ["vless-ws-tls"],
    "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
REPORTJSON
)

    REGISTER_RESPONSE=$(curl -sf --max-time 15 \
        -X POST "$API_URL/api/nodes/register" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$REPORT_DATA" 2>/dev/null) || REGISTER_RESPONSE=""

    if [[ -n "$REGISTER_RESPONSE" && "$REGISTER_RESPONSE" == *"node_id"* ]]; then
        log_ok "Node registered at central panel"

        NODE_ID=$(echo "$REGISTER_RESPONSE" | jq -r '.node_id // empty' 2>/dev/null) || true

        if [[ -n "$NODE_ID" ]]; then
            cat > "$DATA_DIR/heartbeat.conf" << HBEOF
API_URL="$API_URL"
API_KEY="$API_KEY"
NODE_ID="$NODE_ID"
HBEOF
            chmod 600 "$DATA_DIR/heartbeat.conf"

            curl -sf "$SCRIPTS_URL/scripts/heartbeat.sh" -o "$INSTALL_DIR/heartbeat.sh" 2>/dev/null || true
            curl -sf "$SCRIPTS_URL/scripts/sync-clients.sh" -o "$INSTALL_DIR/sync-clients.sh" 2>/dev/null || true
            chmod +x "$INSTALL_DIR/heartbeat.sh" "$INSTALL_DIR/sync-clients.sh" 2>/dev/null || true

            (crontab -l 2>/dev/null | grep -v "heartbeat.sh"; echo "*/5 * * * * $INSTALL_DIR/heartbeat.sh") | crontab -
            log_ok "Heartbeat + client sync configured (every 5 min)"
        fi
    else
        log_warn "Could not report to panel. Register manually or check --api-url / --api-key"
    fi
fi

# ======================== SUMMARY ========================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  VPN NODE INSTALLED SUCCESSFULLY${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Node:${NC}       $NODE_NAME"
echo -e "  ${BOLD}Server:${NC}     $SERVER_IP"
echo -e "  ${BOLD}Domain:${NC}     $CF_DOMAIN"
echo -e "  ${BOLD}Location:${NC}   $CITY, $COUNTRY_NAME"
echo -e "  ${BOLD}Xray:${NC}       v$XRAY_VERSION"
echo -e "  ${BOLD}Transport:${NC}  VLESS + WebSocket + TLS (Cloudflare CDN)"
echo ""
echo -e "  ${BOLD}VLESS Link:${NC}"
echo -e "  ${CYAN}$VLESS_LINK${NC}"
echo ""
echo -e "  ${BOLD}QR Code:${NC}"
cat "$DATA_DIR/qr-code.txt" 2>/dev/null || echo "  (qrencode not available)"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}IMPORTANT:${NC} Make sure in Cloudflare DNS:"
echo -e "    1. A-record: ${YELLOW}$CF_DOMAIN${NC} → ${YELLOW}$SERVER_IP${NC} (Proxied / orange cloud)"
echo -e "    2. SSL/TLS mode: ${YELLOW}Full${NC}"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Keys: ${YELLOW}$DATA_DIR/keys.json${NC}"
echo -e "  Config: ${YELLOW}$CONFIG_DIR/config.json${NC}"
echo -e "  Logs: ${YELLOW}/var/log/xray/${NC}"
echo ""
echo -e "  ${BOLD}Manage:${NC}"
echo -e "    systemctl status xray"
echo -e "    systemctl status nginx"
echo -e "    journalctl -u xray -f"
echo ""
