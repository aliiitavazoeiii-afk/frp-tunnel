#!/usr/bin/env bash
set -euo pipefail
SERVICE=anytls-tunnel
STATE_DIR=/var/lib/anytls-tunnel
CONFIG_DIR=/etc/anytls-tunnel
UNIT=/etc/systemd/system/anytls-tunnel.service

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
latest=$(find "$STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -n1 || true)
[[ -n "$latest" ]] || { echo "No backup snapshots found" >&2; exit 1; }
b="$STATE_DIR/backups/$latest"
echo "Restoring snapshot: $b"
[[ -f "$b/config.yaml" ]] || { echo "Snapshot has no previous config; refusing destructive rollback." >&2; exit 1; }
cp -a "$CONFIG_DIR/config.yaml" "$CONFIG_DIR/config.yaml.before-rollback.$(date +%s)" 2>/dev/null || true
cp -a "$b/config.yaml" "$CONFIG_DIR/config.yaml"
if [[ -f "$b/anytls-tunnel.service" ]]; then cp -a "$b/anytls-tunnel.service" "$UNIT"; fi
if [[ -f "$b/sysctl.conf" ]]; then cp -a "$b/sysctl.conf" /etc/sysctl.d/99-anytls-tunnel.conf; fi
/usr/local/bin/mihomo-anytls-tunnel -t -d "$CONFIG_DIR" -f "$CONFIG_DIR/config.yaml"
systemctl daemon-reload
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE"
echo "Rollback complete."
