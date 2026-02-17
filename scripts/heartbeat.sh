#!/bin/bash
#===============================================================================
# Heartbeat script — runs on each VPN node via cron
# 1. Reports to central panel that this node is alive
# 2. Syncs client list (adds/removes user UUIDs in Xray)
# 3. Reports per-user traffic stats
# Cron: */5 * * * * /opt/auto-vpn/heartbeat.sh
#===============================================================================

DATA_DIR="/opt/auto-vpn/data"
HEARTBEAT_CONF="$DATA_DIR/heartbeat.conf"

if [[ ! -f "$HEARTBEAT_CONF" ]]; then
    exit 0
fi

source "$HEARTBEAT_CONF"

if [[ -z "$API_URL" || -z "$API_KEY" || -z "$NODE_ID" ]]; then
    exit 0
fi

# === 1. Check Xray & send heartbeat ===

XRAY_STATUS="online"
if ! systemctl is-active --quiet xray; then
    XRAY_STATUS="offline"
    systemctl restart xray 2>/dev/null
    sleep 2
    if systemctl is-active --quiet xray; then
        XRAY_STATUS="online"
    fi
fi

curl -sf -X POST "$API_URL/api/nodes/$NODE_ID/heartbeat" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"status\": \"$XRAY_STATUS\"}" \
    > /dev/null 2>&1 || true

# === 2. Sync client list ===

if [[ -f "/opt/auto-vpn/sync-clients.sh" ]]; then
    bash /opt/auto-vpn/sync-clients.sh
fi

# === 3. Report traffic stats ===

if [[ "$XRAY_STATUS" == "online" ]] && command -v xray &>/dev/null; then
    TRAFFIC_DATA=$(python3 - << 'PYEOF'
import subprocess, json

try:
    result = subprocess.run(
        ["xray", "api", "statsquery", "-server=127.0.0.1:10085", "-pattern", "user>>>", "-reset"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        print("{}")
        exit()

    data = json.loads(result.stdout) if result.stdout.strip() else {}
    stats = {}

    for stat in data.get("stat", []):
        name = stat.get("name", "")
        value = int(stat.get("value", 0))
        # Format: "user>>>email>>>traffic>>>uplink" or "user>>>email>>>traffic>>>downlink"
        parts = name.split(">>>")
        if len(parts) == 4 and parts[0] == "user":
            email = parts[1]
            direction = parts[3]
            if email not in stats:
                stats[email] = {"uplink": 0, "downlink": 0}
            stats[email][direction] = value

    print(json.dumps(stats))
except Exception:
    print("{}")
PYEOF
    )

    if [[ -n "$TRAFFIC_DATA" && "$TRAFFIC_DATA" != "{}" ]]; then
        curl -sf -X POST "$API_URL/api/nodes/$NODE_ID/traffic" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d "$TRAFFIC_DATA" \
            > /dev/null 2>&1 || true
    fi
fi
