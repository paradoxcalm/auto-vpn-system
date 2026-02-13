#!/bin/bash
#===============================================================================
# Add a new user/client to existing Xray node
# Usage: bash add-user.sh [--name username] [--email user@example.com]
#===============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="/etc/xray/config.json"
DATA_DIR="/opt/auto-vpn/data"
USER_NAME="${1:-user-$(date +%s | tail -c 5)}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Xray config not found at $CONFIG_FILE${NC}"
    exit 1
fi

# Generate new credentials
NEW_UUID=$(/usr/local/bin/xray uuid)
NEW_SHORT_ID=$(openssl rand -hex 8)

# Read existing config data
SERVER_IP=$(jq -r '.server_ip' "$DATA_DIR/keys.json" 2>/dev/null || curl -sf https://api.ipify.org)
PUBLIC_KEY=$(jq -r '.public_key' "$DATA_DIR/keys.json")
NODE_NAME=$(jq -r '.node_name' "$DATA_DIR/keys.json")
MAIN_PORT=$(jq -r '.port' "$DATA_DIR/keys.json")
SNI_DOMAIN=$(jq -r '.sni // empty' "$DATA_DIR/keys.json")

if [[ -z "$SNI_DOMAIN" ]]; then
    SNI_DOMAIN=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
fi

# Add client to Xray config
python3 << PYEOF
import json

with open("$CONFIG_FILE") as f:
    cfg = json.load(f)

new_client = {
    "id": "$NEW_UUID",
    "flow": "xtls-rprx-vision",
    "email": "$USER_NAME@$NODE_NAME"
}

# Add to first VLESS inbound
for inbound in cfg["inbounds"]:
    if inbound.get("protocol") == "vless":
        inbound["settings"]["clients"].append(new_client)
        # Add short ID
        sids = inbound["streamSettings"]["realitySettings"]["shortIds"]
        if "$NEW_SHORT_ID" not in sids:
            sids.append("$NEW_SHORT_ID")
        break

with open("$CONFIG_FILE", "w") as f:
    json.dump(cfg, f, indent=4)
PYEOF

# Restart Xray
systemctl restart xray

# Generate link
VLESS_LINK="vless://${NEW_UUID}@${SERVER_IP}:${MAIN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${NEW_SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}-${USER_NAME}"

# Save user info
mkdir -p "$DATA_DIR/users"
cat > "$DATA_DIR/users/${USER_NAME}.json" << EOF
{
    "name": "$USER_NAME",
    "uuid": "$NEW_UUID",
    "short_id": "$NEW_SHORT_ID",
    "vless_link": "$VLESS_LINK",
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# QR code
qrencode -t UTF8 "$VLESS_LINK" 2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}User added: $USER_NAME${NC}"
echo -e "${CYAN}$VLESS_LINK${NC}"
echo ""
