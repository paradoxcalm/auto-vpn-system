#!/bin/bash
#===============================================================================
# AUTO-VPN SYSTEM — Main Installer
# Автоматическая установка VPN-ноды с определением гео и отправкой ключа
#
# Usage: curl -sSL https://raw.githubusercontent.com/YOUR_USER/auto-vpn-system/main/install.sh | bash
#    or: bash install.sh [OPTIONS]
#
# Options:
#   --api-url URL        Central panel API URL to send keys to
#   --api-key KEY        API key for authentication
#   --sni DOMAIN         SNI domain for REALITY (default: auto-select)
#   --port PORT          Main VLESS port (default: 443)
#   --hysteria           Also install Hysteria2
#   --warp               Also setup Cloudflare WARP outbound
#   --panel              Also install 3X-UI management panel
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
SNI_DOMAIN=""
MAIN_PORT=443
INSTALL_HYSTERIA=false
INSTALL_WARP=false
INSTALL_PANEL=false
NODE_NAME=""
NO_REPORT=false

INSTALL_DIR="/opt/auto-vpn"
CONFIG_DIR="/etc/xray"
DATA_DIR="/opt/auto-vpn/data"
SCRIPTS_URL="https://raw.githubusercontent.com/YOUR_USER/auto-vpn-system/main"

# ======================== PARSE ARGS ========================
while [[ $# -gt 0 ]]; do
    case $1 in
        --api-url)   API_URL="$2"; shift 2 ;;
        --api-key)   API_KEY="$2"; shift 2 ;;
        --sni)       SNI_DOMAIN="$2"; shift 2 ;;
        --port)      MAIN_PORT="$2"; shift 2 ;;
        --hysteria)  INSTALL_HYSTERIA=true; shift ;;
        --warp)      INSTALL_WARP=true; shift ;;
        --panel)     INSTALL_PANEL=true; shift ;;
        --name)      NODE_NAME="$2"; shift 2 ;;
        --no-report) NO_REPORT=true; shift ;;
        *)           log_err "Unknown option: $1"; exit 1 ;;
    esac
done

# ======================== PRE-CHECKS ========================
log_step "Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    log_err "This script must be run as root"
    exit 1
fi

# Detect OS
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

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  XRAY_ARCH="64"; HYSTERIA_ARCH="amd64" ;;
    aarch64) XRAY_ARCH="arm64-v8a"; HYSTERIA_ARCH="arm64" ;;
    *)       log_err "Unsupported architecture: $ARCH"; exit 1 ;;
esac
log_ok "Architecture: $ARCH"

# ======================== GEO DETECTION ========================
log_step "Detecting server location"

detect_geo() {
    local geo_json
    # Try multiple APIs for reliability
    geo_json=$(curl -sf --max-time 10 "https://ipinfo.io/json" 2>/dev/null) || \
    geo_json=$(curl -sf --max-time 10 "https://ipapi.co/json" 2>/dev/null) || \
    geo_json=$(curl -sf --max-time 10 "http://ip-api.com/json" 2>/dev/null) || \
    { log_warn "Could not detect geo, using defaults"; echo '{}'; return; }

    echo "$geo_json"
}

GEO_JSON=$(detect_geo)

SERVER_IP=$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null || \
            curl -sf --max-time 10 https://ifconfig.me 2>/dev/null || \
            curl -sf --max-time 10 https://icanhazip.com 2>/dev/null || \
            echo "unknown")

COUNTRY_CODE=$(echo "$GEO_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('country_code', d.get('country', 'XX')))" 2>/dev/null || echo "XX")
COUNTRY_NAME=$(echo "$GEO_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('country_name', d.get('country', 'Unknown')))" 2>/dev/null || echo "Unknown")
CITY=$(echo "$GEO_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('city', 'Unknown'))" 2>/dev/null || echo "Unknown")
ISP=$(echo "$GEO_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('org', d.get('isp', 'Unknown')))" 2>/dev/null || echo "Unknown")

# Build node name
if [[ -z "$NODE_NAME" ]]; then
    # Format: 🇩🇪 DE-Frankfurt or US-NewYork
    CITY_CLEAN=$(echo "$CITY" | tr ' ' '-' | tr -cd '[:alnum:]-')
    NODE_NAME="${COUNTRY_CODE}-${CITY_CLEAN}"
fi

log_ok "IP: $SERVER_IP"
log_ok "Location: $CITY, $COUNTRY_NAME ($COUNTRY_CODE)"
log_ok "ISP: $ISP"
log_ok "Node name: $NODE_NAME"

# ======================== SYSTEM SETUP ========================
log_step "Updating system and installing dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget unzip jq openssl \
    python3 python3-pip \
    qrencode \
    ufw fail2ban \
    cron socat net-tools

log_ok "Dependencies installed"

# ======================== TCP BBR ========================
log_step "Enabling TCP BBR"

if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    cat >> /etc/sysctl.conf << 'SYSCTL'
# TCP BBR optimization
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

# ======================== CREATE DIRS ========================
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"

# ======================== GENERATE KEYS ========================
log_step "Generating cryptographic keys"

# Install Xray first to use its key generation
XRAY_VERSION=$(curl -sf "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' | tr -d 'v')
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

log_info "Downloading Xray-core v${XRAY_VERSION}..."
wget -q "$XRAY_URL" -O /tmp/xray.zip
unzip -qo /tmp/xray.zip -d /tmp/xray
cp /tmp/xray/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
cp /tmp/xray/*.dat /usr/local/share/xray/ 2>/dev/null || {
    mkdir -p /usr/local/share/xray
    cp /tmp/xray/*.dat /usr/local/share/xray/
}
rm -rf /tmp/xray /tmp/xray.zip

log_ok "Xray-core v${XRAY_VERSION} installed"

# Generate x25519 keypair
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

# Generate UUID
UUID=$(/usr/local/bin/xray uuid)

# Generate short ID (8 hex chars)
SHORT_ID=$(openssl rand -hex 8)

log_ok "Keys generated"
log_info "  UUID: $UUID"
log_info "  Public Key: $PUBLIC_KEY"
log_info "  Short ID: $SHORT_ID"

# Save keys to file
cat > "$DATA_DIR/keys.json" << EOF
{
    "node_name": "$NODE_NAME",
    "server_ip": "$SERVER_IP",
    "country_code": "$COUNTRY_CODE",
    "country_name": "$COUNTRY_NAME",
    "city": "$CITY",
    "uuid": "$UUID",
    "private_key": "$PRIVATE_KEY",
    "public_key": "$PUBLIC_KEY",
    "short_id": "$SHORT_ID",
    "port": $MAIN_PORT,
    "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
chmod 600 "$DATA_DIR/keys.json"

# ======================== SELECT SNI ========================
if [[ -z "$SNI_DOMAIN" ]]; then
    # Auto-select good SNI based on country
    declare -A SNI_MAP=(
        ["RU"]="www.microsoft.com"
        ["CN"]="www.samsung.com"
        ["IR"]="www.speedtest.net"
        ["DEFAULT"]="www.google.com"
    )
    SNI_DOMAIN="${SNI_MAP[$COUNTRY_CODE]:-${SNI_MAP[DEFAULT]}}"
    log_info "Auto-selected SNI: $SNI_DOMAIN"
fi

# ======================== XRAY CONFIG ========================
log_step "Configuring Xray VLESS + REALITY"

cat > "$CONFIG_DIR/config.json" << XRAYCONF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "inbounds": [
        {
            "tag": "vless-reality",
            "listen": "0.0.0.0",
            "port": $MAIN_PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision",
                        "email": "default@$NODE_NAME"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${SNI_DOMAIN}:443",
                    "xver": 0,
                    "serverNames": [
                        "$SNI_DOMAIN"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                        "$SHORT_ID",
                        ""
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom"
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "outboundTag": "block",
                "protocol": ["bittorrent"]
            },
            {
                "type": "field",
                "outboundTag": "block",
                "ip": ["geoip:private"]
            }
        ]
    }
}
XRAYCONF

mkdir -p /var/log/xray

log_ok "Xray config created"

# ======================== SYSTEMD SERVICE ========================
log_step "Creating systemd service"

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

# Verify
sleep 2
if systemctl is-active --quiet xray; then
    log_ok "Xray service is running"
else
    log_err "Xray failed to start. Check: journalctl -u xray"
    journalctl -u xray --no-pager -n 20
fi

# ======================== OPTIONAL: HYSTERIA2 ========================
if [[ "$INSTALL_HYSTERIA" == true ]]; then
    log_step "Installing Hysteria2"

    HYSTERIA_PORT=8443
    HYSTERIA_PASSWORD=$(openssl rand -base64 32)

    # Download Hysteria2
    HYSTERIA_VERSION=$(curl -sf "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r '.tag_name')
    HYSTERIA_URL="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/hysteria-linux-${HYSTERIA_ARCH}"
    wget -q "$HYSTERIA_URL" -O /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria

    # Generate self-signed cert for Hysteria
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/server.key \
        -out /etc/hysteria/server.crt \
        -subj "/CN=$SNI_DOMAIN" -days 36500 2>/dev/null

    cat > /etc/hysteria/config.yaml << HYSTCONF
listen: :$HYSTERIA_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $HYSTERIA_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$SNI_DOMAIN
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
HYSTCONF

    cat > /etc/systemd/system/hysteria.service << 'HYSTSERVICE'
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
HYSTSERVICE

    systemctl daemon-reload
    systemctl enable hysteria
    systemctl start hysteria

    # Save hysteria data
    cat > "$DATA_DIR/hysteria.json" << EOF
{
    "port": $HYSTERIA_PORT,
    "password": "$HYSTERIA_PASSWORD",
    "sni": "$SNI_DOMAIN"
}
EOF
    chmod 600 "$DATA_DIR/hysteria.json"

    log_ok "Hysteria2 installed on port $HYSTERIA_PORT"
fi

# ======================== OPTIONAL: WARP ========================
if [[ "$INSTALL_WARP" == true ]]; then
    log_step "Setting up Cloudflare WARP outbound"

    # Install wgcf for WARP credentials
    WGCF_URL="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${HYSTERIA_ARCH}"
    wget -q "$WGCF_URL" -O /usr/local/bin/wgcf 2>/dev/null && {
        chmod +x /usr/local/bin/wgcf

        cd /tmp
        /usr/local/bin/wgcf register --accept-tos 2>/dev/null || true
        /usr/local/bin/wgcf generate 2>/dev/null || true

        if [[ -f /tmp/wgcf-profile.conf ]]; then
            WARP_PRIVATE=$(grep "PrivateKey" /tmp/wgcf-profile.conf | awk -F'= ' '{print $2}')
            WARP_ADDRESS4=$(grep "Address" /tmp/wgcf-profile.conf | grep -v ":" | awk -F'= ' '{print $2}')
            WARP_ADDRESS6=$(grep "Address" /tmp/wgcf-profile.conf | grep ":" | awk -F'= ' '{print $2}')

            # Add WARP outbound to Xray config
            WARP_OUTBOUND=$(cat << WARPJSON
{
    "tag": "warp",
    "protocol": "wireguard",
    "settings": {
        "secretKey": "$WARP_PRIVATE",
        "address": ["$WARP_ADDRESS4", "$WARP_ADDRESS6"],
        "peers": [
            {
                "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                "allowedIPs": ["0.0.0.0/0", "::/0"],
                "endpoint": "engage.cloudflareclient.com:2408"
            }
        ],
        "mtu": 1280
    }
}
WARPJSON
)
            # Update xray config to add warp outbound
            python3 << PYEOF
import json
with open("$CONFIG_DIR/config.json") as f:
    cfg = json.load(f)
warp = json.loads('''$WARP_OUTBOUND''')
cfg["outbounds"].insert(1, warp)
# Add routing rule: route all non-blocked through warp
cfg["routing"]["rules"].append({
    "type": "field",
    "outboundTag": "warp",
    "network": "tcp,udp"
})
# Move direct to last
with open("$CONFIG_DIR/config.json", "w") as f:
    json.dump(cfg, f, indent=4)
PYEOF

            systemctl restart xray
            log_ok "Cloudflare WARP outbound configured"
        else
            log_warn "Could not generate WARP profile, skipping"
        fi

        cd - > /dev/null
    } || log_warn "Could not download wgcf, skipping WARP"
fi

# ======================== FIREWALL ========================
log_step "Configuring firewall"

ufw --force reset > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow "$MAIN_PORT"/tcp

if [[ "$INSTALL_HYSTERIA" == true ]]; then
    ufw allow 8443/udp
fi

ufw --force enable > /dev/null 2>&1
log_ok "Firewall configured"

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

# ======================== GENERATE CLIENT CONFIG ========================
log_step "Generating client configuration"

# VLESS share link
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${MAIN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}"

echo "$VLESS_LINK" > "$DATA_DIR/vless-link.txt"

# Generate QR code
qrencode -t UTF8 "$VLESS_LINK" > "$DATA_DIR/qr-code.txt" 2>/dev/null || true
qrencode -t PNG -o "$DATA_DIR/qr-code.png" "$VLESS_LINK" 2>/dev/null || true

# Hysteria link if installed
HYSTERIA_LINK=""
if [[ "$INSTALL_HYSTERIA" == true ]]; then
    HYSTERIA_LINK="hysteria2://${HYSTERIA_PASSWORD}@${SERVER_IP}:8443?insecure=1&sni=${SNI_DOMAIN}#${NODE_NAME}-HY2"
    echo "$HYSTERIA_LINK" > "$DATA_DIR/hysteria-link.txt"
fi

# ======================== REPORT TO CENTRAL PANEL ========================
if [[ "$NO_REPORT" == false && -n "$API_URL" ]]; then
    log_step "Reporting to central panel"

    REPORT_DATA=$(cat << REPORTJSON
{
    "node_name": "$NODE_NAME",
    "server_ip": "$SERVER_IP",
    "country_code": "$COUNTRY_CODE",
    "country_name": "$COUNTRY_NAME",
    "city": "$CITY",
    "isp": "$ISP",
    "vless_link": "$VLESS_LINK",
    "hysteria_link": "$HYSTERIA_LINK",
    "port": $MAIN_PORT,
    "public_key": "$PUBLIC_KEY",
    "uuid": "$UUID",
    "short_id": "$SHORT_ID",
    "sni": "$SNI_DOMAIN",
    "xray_version": "$XRAY_VERSION",
    "protocols": ["vless-reality"$([ "$INSTALL_HYSTERIA" == true ] && echo ',"hysteria2"')],
    "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
REPORTJSON
)

    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "$API_URL/api/nodes/register" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$REPORT_DATA" 2>/dev/null) || HTTP_CODE="000"

    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
        log_ok "Node registered at central panel"
    else
        log_warn "Failed to report to panel (HTTP $HTTP_CODE). You can do it manually later."
    fi
fi

# ======================== SUMMARY ========================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  AUTO-VPN NODE INSTALLED SUCCESSFULLY${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Node:${NC}       $NODE_NAME"
echo -e "  ${BOLD}Server:${NC}     $SERVER_IP"
echo -e "  ${BOLD}Location:${NC}   $CITY, $COUNTRY_NAME"
echo -e "  ${BOLD}Xray:${NC}       v$XRAY_VERSION"
echo ""
echo -e "  ${BOLD}VLESS + REALITY:${NC}"
echo -e "  ${CYAN}$VLESS_LINK${NC}"
echo ""
if [[ "$INSTALL_HYSTERIA" == true ]]; then
    echo -e "  ${BOLD}Hysteria2:${NC}"
    echo -e "  ${CYAN}$HYSTERIA_LINK${NC}"
    echo ""
fi
echo -e "  ${BOLD}QR Code:${NC}"
cat "$DATA_DIR/qr-code.txt" 2>/dev/null || echo "  (qrencode not available)"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Keys saved to: ${YELLOW}$DATA_DIR/keys.json${NC}"
echo -e "  Config:         ${YELLOW}$CONFIG_DIR/config.json${NC}"
echo -e "  Logs:           ${YELLOW}/var/log/xray/${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Manage:${NC}"
echo -e "    systemctl status xray"
echo -e "    systemctl restart xray"
echo -e "    journalctl -u xray -f"
echo ""
