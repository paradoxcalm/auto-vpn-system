#!/bin/bash
#===============================================================================
# sync-clients.sh — Pull active client list from panel, update Xray config
# Called by heartbeat.sh every 5 minutes
#===============================================================================

CONF_FILE="/opt/auto-vpn/data/heartbeat.conf"
XRAY_CONFIG="/etc/xray/config.json"

if [[ ! -f "$CONF_FILE" ]]; then
    exit 0
fi

source "$CONF_FILE"

if [[ -z "$API_URL" || -z "$API_KEY" || -z "$NODE_ID" ]]; then
    exit 0
fi

# Fetch client list from panel
CLIENTS=$(curl -sf --max-time 15 \
    -H "Authorization: Bearer $API_KEY" \
    "$API_URL/api/nodes/$NODE_ID/clients" 2>/dev/null)

if [[ -z "$CLIENTS" || "$CLIENTS" == "null" ]]; then
    exit 0
fi

# Use python3 to merge clients into Xray config
python3 - "$CLIENTS" "$XRAY_CONFIG" << 'PYEOF'
import json, sys

clients_json = sys.argv[1]
config_path = sys.argv[2]

try:
    new_clients = json.loads(clients_json)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

if not isinstance(new_clients, list):
    sys.exit(0)

try:
    with open(config_path) as f:
        config = json.load(f)
except (IOError, json.JSONDecodeError):
    sys.exit(0)

# Find the VLESS inbound (not the API inbound)
changed = False
for inbound in config.get("inbounds", []):
    if inbound.get("protocol") == "vless" and inbound.get("tag") != "api-in":
        current = inbound.get("settings", {}).get("clients", [])
        current_ids = set(c.get("id", "") for c in current)

        # Build new client list with level 0 for stats
        new_list = []
        new_ids = set()
        for c in new_clients:
            cid = c.get("id", "")
            if cid:
                new_list.append({
                    "id": cid,
                    "email": c.get("email", f"user@panel"),
                    "level": 0
                })
                new_ids.add(cid)

        if current_ids != new_ids:
            inbound["settings"]["clients"] = new_list
            changed = True
        break

if changed:
    with open(config_path, "w") as f:
        json.dump(config, f, indent=4)
    sys.exit(42)  # Signal restart needed

sys.exit(0)
PYEOF

EXIT_CODE=$?
if [[ $EXIT_CODE -eq 42 ]]; then
    systemctl restart xray 2>/dev/null || true
fi
