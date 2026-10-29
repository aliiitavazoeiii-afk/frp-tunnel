#!/usr/bin/env bash
# Isolated Mieru/Mita TCP egress on the dedicated Foreign-2 VPS.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "amd64 required"; exit 1; }
IRAN_IP="$1"
[[ "$IRAN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: sudo bash foreign-mieru.sh IRAN_PUBLIC_IP"; exit 2; }
if systemctl is-active --quiet mita 2>/dev/null; then echo "Existing mita service active: refusing shared install"; exit 3; fi
if ss -Hlnpt '( sport = :28443 )' | grep -q LISTEN; then echo "Port 28443 occupied"; exit 3; fi
VERSION=3.39.0
SHA=ea35fdef84bef1378f32b74a2d5a883d508a49dd4e64dba9a3a8363beed5798c
mkdir -p /etc/dual-ha /opt/dual-ha/bin /var/lib/mita /run/dual-ha-mita
chmod 0700 /etc/dual-ha
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 "https://github.com/enfein/mieru/releases/download/v$VERSION/mita_$VERSION_linux_amd64.tar.gz" -o "$work/mita.tar.gz"
echo "$SHA  $work/mita.tar.gz" | sha256sum -c -
mkdir "$work/unpack"
tar -xzf "$work/mita.tar.gz" -C "$work/unpack"
bin="$(find "$work/unpack" -type f -name mita | head -n 1)"
[[ -n "$bin" ]] || { echo "mita executable missing"; exit 3; }
install -m 0755 "$bin" /opt/dual-ha/bin/mita
PASSWORD="$(openssl rand -hex 32)"
USER_NAME=dualha
python3 - "$USER_NAME" "$PASSWORD" <<'PY'
import json,sys
config={"portBindings":[{"port":28443,"protocol":"TCP"}],
"users":[{"name":sys.argv[1],"password":sys.argv[2]}],
"loggingLevel":"WARN","dns":{"dualStack":"PREFER_IPv4"}}
with open("/etc/dual-ha/mita.json","w") as f: json.dump(config,f,indent=2)
PY
chmod 0600 /etc/dual-ha/mita.json
cat >/etc/dual-ha/mieru-bundle.env <<EOF
MIERU_REMOTE_IP='152.237.230.248'
MIERU_TCP_PORT='28443'
MIERU_USER='$USER_NAME'
MIERU_PASSWORD='$PASSWORD'
EOF
chmod 0600 /etc/dual-ha/mieru-bundle.env
cat >/etc/systemd/system/dual-ha-mita.service <<'EOF'
[Unit]
Description=Dual HA isolated Mita TCP Foreign-2
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=MITA_CONFIG_JSON_FILE=/etc/dual-ha/mita.json
Environment=MITA_UDS_PATH=/run/dual-ha-mita/mita.sock
RuntimeDirectory=dual-ha-mita
ExecStart=/opt/dual-ha/bin/mita run
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dual-ha-mita
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow from "$IRAN_IP" to any port 28443 proto tcp
fi
sleep 2
systemctl is-active --quiet dual-ha-mita || { journalctl -u dual-ha-mita -n 50 --no-pager; exit 1; }
echo "Mita TCP installed. Transfer secret bundle directly to Iran (never paste it publicly):"
echo "scp /etc/dual-ha/mieru-bundle.env root@$IRAN_IP:/root/dual-ha-mieru-bundle.env"
echo "Only 28443/TCP is used; configure provider firewall to allow Iran IP if necessary."
