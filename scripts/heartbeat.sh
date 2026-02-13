#!/bin/bash
#===============================================================================
# Heartbeat script — runs on each VPN node via cron
# Reports to central panel that this node is alive
# Cron: */5 * * * * /opt/auto-vpn/heartbeat.sh
#===============================================================================

DATA_DIR="/opt/auto-vpn/data"
HEARTBEAT_CONF="$DATA_DIR/heartbeat.conf"

# Read config
if [[ ! -f "$HEARTBEAT_CONF" ]]; then
    exit 0
fi

source "$HEARTBEAT_CONF"

if [[ -z "$API_URL" || -z "$API_KEY" || -z "$NODE_ID" ]]; then
    exit 0
fi

# Check if xray is running
XRAY_STATUS="online"
if ! systemctl is-active --quiet xray; then
    XRAY_STATUS="offline"
    # Try to restart
    systemctl restart xray 2>/dev/null
    sleep 2
    if systemctl is-active --quiet xray; then
        XRAY_STATUS="online"
    fi
fi

# Send heartbeat
curl -sf -X POST "$API_URL/api/nodes/$NODE_ID/heartbeat" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"status\": \"$XRAY_STATUS\"}" \
    > /dev/null 2>&1 || true
