#!/usr/bin/env bash
# Repair ONLY the isolated failed dual-ha-mita service, preserving credentials.
# Does not download packages, rotate keys, change firewalls or touch x-ui / Xray.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
CONF=/etc/dual-ha/mita.json
BUNDLE=/etc/dual-ha/mieru-bundle.env
UNIT=/etc/systemd/system/dual-ha-mita.service
BIN=/opt/dual-ha/bin/mita
for path in "$CONF" "$BUNDLE" "$UNIT" "$BIN"; do
  [[ -f "$path" ]] || { echo "Missing required staging component: $path"; exit 2; }
done
[[ -x "$BIN" ]] || { echo "mita binary not executable"; exit 2; }
python3 - "$CONF" "$BUNDLE" <<'PY'
import json, os, re, sys
cfg = json.load(open(sys.argv[1]))
ports = cfg.get("portBindings", [])
if ports != [{"port":28443, "protocol":"TCP"}]:
    raise SystemExit("Config is not expected TCP-only staging profile; refusing repair.")
if not cfg.get("users"):
    raise SystemExit("No configured Mita users; refusing repair.")
b = open(sys.argv[2]).read()
if not re.search(r"(?m)^MIERU_REMOTE_IP='152\.237\.230\.248'$", b):
    raise SystemExit("Bundle Foreign-2 IP mismatch.")
if not re.search(r"(?m)^MIERU_TCP_PORT='28443'$", b):
    raise SystemExit("Bundle TCP port mismatch.")
PY

if ! getent group mita >/dev/null; then
  groupadd --system mita
fi
if ! id -u mita >/dev/null 2>&1; then
  useradd --system --gid mita --home-dir /nonexistent --no-create-home \
    --shell /usr/sbin/nologin mita
fi
if [[ "$(id -gn mita)" != "mita" ]]; then
  echo "Existing mita user has unexpected primary group. Refusing to change it."
  exit 3
fi

# Existing credentials are kept bit-for-bit. Only Mita can read its config.
chown root:mita /etc/dual-ha
chmod 0750 /etc/dual-ha
chown root:mita "$CONF"
chmod 0640 "$CONF"
chmod 0600 "$BUNDLE"
install -d -m 0750 -o mita -g mita /var/lib/mita
install -d -m 0750 -o mita -g mita /run/dual-ha-mita

# Avoid rewriting vendor/staging unit. Drop-in restricts the service to mita.
install -d -m 0755 /etc/systemd/system/dual-ha-mita.service.d
cat >/etc/systemd/system/dual-ha-mita.service.d/10-run-as-mita.conf <<'EOF'
[Service]
User=mita
Group=mita
RuntimeDirectory=dual-ha-mita
RuntimeDirectoryMode=0750
StateDirectory=mita
StateDirectoryMode=0750
UMask=0077
NoNewPrivileges=true
EOF
systemctl daemon-reload
systemctl reset-failed dual-ha-mita.service || true
systemctl restart dual-ha-mita.service
sleep 2
if ! systemctl is-active --quiet dual-ha-mita.service; then
  echo "FAIL: dual-ha-mita service did not remain active"
  journalctl -u dual-ha-mita.service -n 35 --no-pager
  exit 4
fi

# Service being active is not enough: the TCP proxy listener must exist.
if ! ss -H -lnt '( sport = :28443 )' | grep -q ':28443'; then
  echo "FAIL: Mita active but TCP/28443 does not listen."
  journalctl -u dual-ha-mita.service -n 35 --no-pager
  exit 5
fi
echo "SUCCESS: Mita TCP server listening on :28443, credentials preserved."
echo "UP NEXT: install the Iran Mieru client and run SOCKS5 HTTPS end-to-end check."
echo "No live X-UI / Reality settings changed."
