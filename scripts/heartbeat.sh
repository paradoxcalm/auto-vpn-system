#!/bin/bash
#===============================================================================
# Heartbeat script — runs on each VPN node via cron
# 1. Collects server metrics (CPU, RAM, disk, connections, ping, speed)
# 2. Reports to central panel that this node is alive + metrics
# 3. Syncs client list (adds/removes user UUIDs in Xray)
# 4. Reports per-user traffic stats
# Cron: */5 * * * * /opt/auto-vpn/heartbeat.sh
#===============================================================================

DATA_DIR="/opt/auto-vpn/data"
HEARTBEAT_CONF="$DATA_DIR/heartbeat.conf"
SPEED_CACHE="$DATA_DIR/speed-cache.json"

if [[ ! -f "$HEARTBEAT_CONF" ]]; then
    exit 0
fi

source "$HEARTBEAT_CONF"

if [[ -z "$API_URL" || -z "$API_KEY" || -z "$NODE_ID" ]]; then
    exit 0
fi

# === 1. Collect server metrics ===

# CPU usage (average over 1 second)
CPU=$(python3 -c "
import subprocess
try:
    r = subprocess.run(['grep', 'cpu ', '/proc/stat'], capture_output=True, text=True)
    v1 = list(map(int, r.stdout.split()[1:]))
    import time; time.sleep(1)
    r = subprocess.run(['grep', 'cpu ', '/proc/stat'], capture_output=True, text=True)
    v2 = list(map(int, r.stdout.split()[1:]))
    d = [v2[i]-v1[i] for i in range(len(v1))]
    idle = d[3]
    total = sum(d)
    print(round((1 - idle/total)*100, 1) if total > 0 else 0)
except: print(0)
" 2>/dev/null || echo "0")

# RAM usage
RAM=$(python3 -c "
try:
    with open('/proc/meminfo') as f:
        lines = f.readlines()
    info = {}
    for line in lines:
        parts = line.split()
        info[parts[0].rstrip(':')] = int(parts[1])
    total = info['MemTotal']
    avail = info.get('MemAvailable', info.get('MemFree', 0))
    print(round((1 - avail/total)*100, 1) if total > 0 else 0)
except: print(0)
" 2>/dev/null || echo "0")

# Disk usage (root partition)
DISK=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo "0")

# Active VPN connections (Xray established connections on port 10001)
CONNS=$(ss -tn state established 2>/dev/null | grep -c ":10001 " || echo "0")

# System uptime in seconds
UPTIME=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")

# Ping to 1.1.1.1 (Cloudflare DNS — good proxy for latency)
PING=$(ping -c 3 -W 2 1.1.1.1 2>/dev/null | tail -1 | awk -F'/' '{printf "%.1f", $5}' || echo "0")
if [[ -z "$PING" || "$PING" == "0" ]]; then PING="0"; fi

# Speed test — run only once per hour (cached)
DL_SPEED="0"
UL_SPEED="0"

SPEED_AGE=9999
if [[ -f "$SPEED_CACHE" ]]; then
    SPEED_AGE=$(( $(date +%s) - $(stat -c %Y "$SPEED_CACHE" 2>/dev/null || echo "0") ))
fi

# Run speedtest every 60 minutes (3600 seconds)
if [[ $SPEED_AGE -gt 3600 ]]; then
    if command -v speedtest-cli &>/dev/null; then
        SPEED_JSON=$(speedtest-cli --json --timeout 30 2>/dev/null || echo "{}")
        if [[ -n "$SPEED_JSON" && "$SPEED_JSON" != "{}" ]]; then
            echo "$SPEED_JSON" > "$SPEED_CACHE"
        fi
    elif command -v speedtest &>/dev/null; then
        # Ookla speedtest
        SPEED_JSON=$(speedtest --format=json --accept-license 2>/dev/null || echo "{}")
        if [[ -n "$SPEED_JSON" && "$SPEED_JSON" != "{}" ]]; then
            echo "$SPEED_JSON" > "$SPEED_CACHE"
        fi
    fi
fi

# Parse cached speed result
if [[ -f "$SPEED_CACHE" ]]; then
    SPEED_DATA=$(cat "$SPEED_CACHE" 2>/dev/null || echo "{}")
    # speedtest-cli format: download/upload in bits/s
    DL_SPEED=$(echo "$SPEED_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # speedtest-cli: 'download' in bits/s
    if 'download' in d and isinstance(d['download'], (int,float)) and d['download'] > 1000:
        print(round(d['download']/1e6, 1))
    # ookla speedtest: 'download': {'bandwidth': bytes/s}
    elif 'download' in d and isinstance(d['download'], dict):
        print(round(d['download']['bandwidth']*8/1e6, 1))
    else:
        print(0)
except: print(0)
" 2>/dev/null || echo "0")
    UL_SPEED=$(echo "$SPEED_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'upload' in d and isinstance(d['upload'], (int,float)) and d['upload'] > 1000:
        print(round(d['upload']/1e6, 1))
    elif 'upload' in d and isinstance(d['upload'], dict):
        print(round(d['upload']['bandwidth']*8/1e6, 1))
    else:
        print(0)
except: print(0)
" 2>/dev/null || echo "0")
fi

# === 2. Check Xray & send heartbeat with metrics ===

XRAY_STATUS="online"
if ! systemctl is-active --quiet xray; then
    XRAY_STATUS="offline"
    systemctl restart xray 2>/dev/null
    sleep 2
    if systemctl is-active --quiet xray; then
        XRAY_STATUS="online"
    fi
fi

HEARTBEAT_JSON=$(cat << ENDJSON
{
    "status": "$XRAY_STATUS",
    "metrics": {
        "ping_ms": $PING,
        "download_mbps": $DL_SPEED,
        "upload_mbps": $UL_SPEED,
        "cpu_percent": $CPU,
        "ram_percent": $RAM,
        "disk_percent": $DISK,
        "connections": $CONNS,
        "uptime_seconds": $UPTIME
    }
}
ENDJSON
)

curl -sf -X POST "$API_URL/api/nodes/$NODE_ID/heartbeat" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$HEARTBEAT_JSON" \
    > /dev/null 2>&1 || true

# === 3. Sync client list ===

if [[ -f "/opt/auto-vpn/sync-clients.sh" ]]; then
    bash /opt/auto-vpn/sync-clients.sh
fi

# === 4. Report traffic stats ===

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
