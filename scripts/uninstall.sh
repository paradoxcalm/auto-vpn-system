#!/bin/bash
#===============================================================================
# Uninstall auto-vpn from a node
#===============================================================================

set -euo pipefail

echo "This will remove Xray, Hysteria2, and all auto-vpn data."
read -p "Are you sure? (y/N) " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo "Stopping services..."
systemctl stop xray 2>/dev/null || true
systemctl stop hysteria 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
systemctl disable hysteria 2>/dev/null || true

echo "Removing files..."
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/hysteria.service
rm -f /usr/local/bin/xray
rm -f /usr/local/bin/hysteria
rm -rf /etc/xray
rm -rf /etc/hysteria
rm -rf /opt/auto-vpn
rm -rf /var/log/xray
rm -rf /usr/local/share/xray

systemctl daemon-reload

# Remove cron
crontab -l 2>/dev/null | grep -v "heartbeat.sh" | crontab - 2>/dev/null || true

echo "Done. Auto-VPN has been removed."
