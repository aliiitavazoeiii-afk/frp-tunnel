#!/usr/bin/env bash
# Install adaptive SHADOW only. No production services or routing are changed.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'root required' >&2; exit 1; }
B=$(cd -- "$(dirname "$0")" && pwd)
BASE=/usr/local/lib/naive-mieru-adaptive
STATE=/var/lib/dual-trust-mieru/naive-mieru/adaptive
LIVE=(x-ui dual-dispatcher dual-xudp-bridge nm-naive-client dual-mieru-carrier)
[[ -s /etc/dual-trust-mieru/iran/controller.secret ]] || exit 1
grep -q 'strategy: round-robin' /etc/dual-trust-mieru/iran/dispatcher.yaml
for svc in "${LIVE[@]}"; do systemctl is-active --quiet "$svc.service" || exit 1; done
for f in nm-adaptive-core.py nm-adaptive-canary.py nm-adaptive-test.py nm-cli.sh nm-manager.sh; do test -s "$B/$f"; done
bash -n "$B/nm-cli.sh" "$B/nm-manager.sh"
python3 -m py_compile "$B/nm-adaptive-core.py" "$B/nm-adaptive-canary.py" "$B/nm-adaptive-test.py"
python3 "$B/nm-adaptive-test.py" -q
mkdir -p "$BASE" "$STATE"
chmod 0700 "$STATE"
BEFORE=$(for svc in "${LIVE[@]}"; do echo "$svc $(systemctl show -p MainPID --value "$svc.service")"; done)
BK="/var/lib/dual-trust-mieru/naive-mieru/adaptive/installer-backup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"
chmod 0700 "$BK"
for f in /usr/local/bin/dual /usr/local/sbin/dual-manager /usr/local/lib/naive-mieru-manager/nm-manager.sh /etc/systemd/system/nm-adaptive-shadow.service /etc/systemd/system/nm-adaptive-canary.service; do
  [[ ! -f "$f" ]] || cp -a "$f" "$BK/$(basename "$f")"
done
install -m 0750 "$B/nm-adaptive-core.py" "$BASE/nm-adaptive-core.py"
install -m 0750 "$B/nm-adaptive-canary.py" "$BASE/nm-adaptive-canary.py"
cat > /etc/systemd/system/nm-adaptive-shadow.service <<'UNIT'
[Unit]
Description=Naive/Mieru adaptive byte monitor - read-only shadow
After=network-online.target dual-dispatcher.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /usr/local/lib/naive-mieru-adaptive/nm-adaptive-core.py --run --interval 2 --window-seconds 600
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/dual-trust-mieru/naive-mieru/adaptive
MemoryMax=192M
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/nm-adaptive-canary.service <<'UNIT'
[Unit]
Description=Adaptive isolated localhost SOCKS5 TCP/UDP canary
After=nm-adaptive-shadow.service
Requires=nm-adaptive-shadow.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /usr/local/lib/naive-mieru-adaptive/nm-adaptive-canary.py
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
MemoryMax=256M
LimitNOFILE=4096
UNIT
chmod 0600 /etc/systemd/system/nm-adaptive-shadow.service /etc/systemd/system/nm-adaptive-canary.service
systemd-analyze verify /etc/systemd/system/nm-adaptive-shadow.service /etc/systemd/system/nm-adaptive-canary.service >/dev/null
systemctl daemon-reload
if systemctl is-active --quiet nm-adaptive-shadow.service; then
  systemctl restart nm-adaptive-shadow.service
else
  systemctl enable --now nm-adaptive-shadow.service
fi
systemctl is-active --quiet nm-adaptive-shadow.service
mkdir -p /usr/local/lib/naive-mieru-manager
install -m 0755 "$B/nm-manager.sh" /usr/local/lib/naive-mieru-manager/nm-manager.sh
install -m 0755 "$B/nm-cli.sh" /usr/local/bin/dual
install -m 0755 "$B/nm-cli.sh" /usr/local/sbin/dual-manager
AFTER=$(for svc in "${LIVE[@]}"; do echo "$svc $(systemctl show -p MainPID --value "$svc.service")"; done)
[[ "$BEFORE" == "$AFTER" ]] || { echo 'Unexpected protected PID change. Installer never restarted production.' >&2; exit 1; }
echo 'SHADOW INSTALLED. :7990 production unchanged. CANARY INSTALLED BUT DISABLED.'
echo "CLI: dual adaptive | Backup: $BK"
/usr/bin/python3 "$BASE/nm-adaptive-core.py" --status
