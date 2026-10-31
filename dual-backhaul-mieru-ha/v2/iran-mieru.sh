#!/usr/bin/env bash
# Isolated Mieru client with local SOCKS5 on 127.0.0.1:21002.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "amd64 required"; exit 1; }
BUNDLE="$1"
[[ -r "$BUNDLE" ]] || { echo "Usage: sudo bash iran-mieru.sh /root/dual-ha-mieru-bundle.env"; exit 2; }
if ss -Hlnpt '( sport = :21002 )' | grep -q LISTEN; then
  echo "21002 occupied; refusing to replace a live SOCKS endpoint"; exit 3
fi
grep -Eq "^MIERU_REMOTE_IP='([0-9]{1,3}[.]){3}[0-9]{1,3}'$" "$BUNDLE" || { echo "Invalid Foreign-2 address in bundle"; exit 3; }
# shellcheck source=/dev/null
source "$BUNDLE"
[[ "$MIERU_TCP_PORT" == 28443 && "$MIERU_USER" =~ ^[A-Za-z0-9_-]+$ && "$MIERU_PASSWORD" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid bundle"; exit 3; }
EXPECTED_FOREIGN_IP="${2:-$MIERU_REMOTE_IP}"
[[ "$MIERU_REMOTE_IP" == "$EXPECTED_FOREIGN_IP" ]] || { echo "Foreign Mieru IP mismatch: supplied $EXPECTED_FOREIGN_IP vs bundle $MIERU_REMOTE_IP"; exit 3; }
python3 - "$MIERU_REMOTE_IP" <<'PY'
import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1])
assert ip.version==4 and ip.is_global,"Invalid foreign public IPv4"
PY
VERSION=3.39.0
SHA=81f549ffd7be2df6958b1051aad10e58884889d92e691c1e43822c42091d1dfe
mkdir -p /etc/dual-ha /opt/dual-ha/bin
chmod 0700 /etc/dual-ha
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 "https://github.com/enfein/mieru/releases/download/v$VERSION/mieru_${VERSION}_linux_amd64.tar.gz" -o "$work/mieru.tar.gz"
echo "$SHA  $work/mieru.tar.gz" | sha256sum -c -
mkdir "$work/unpack"
tar -xzf "$work/mieru.tar.gz" -C "$work/unpack"
bin="$(find "$work/unpack" -type f -name mieru | head -n 1)"
[[ -n "$bin" ]] || { echo "mieru executable missing"; exit 3; }
install -m 0755 "$bin" /opt/dual-ha/bin/mieru
python3 - "$MIERU_REMOTE_IP" "$MIERU_TCP_PORT" "$MIERU_USER" "$MIERU_PASSWORD" <<'PY'
import json,sys
ip,port,user,password=sys.argv[1:]
config={"profiles":[{"profileName":"dualha","user":{"name":user,"password":password},
"servers":[{"ipAddress":ip,"portBindings":[{"port":int(port),"protocol":"TCP"}]}],
"multiplexing":{"level":"MULTIPLEXING_OFF"},"handshakeMode":"HANDSHAKE_STANDARD"}],
"activeProfile":"dualha","rpcPort":28964,"socks5Port":21002,
"socks5ListenLAN":False,"loggingLevel":"WARN"}
with open("/etc/dual-ha/mieru.json","w") as f: json.dump(config,f,indent=2)
PY
chmod 0600 /etc/dual-ha/mieru.json
cat >/etc/systemd/system/dual-ha-mieru.service <<'EOF'
[Unit]
Description=Dual HA isolated Mieru TCP Iran client
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=MIERU_CONFIG_JSON_FILE=/etc/dual-ha/mieru.json
ExecStart=/opt/dual-ha/bin/mieru run
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dual-ha-mieru
sleep 3
systemctl is-active --quiet dual-ha-mieru || { journalctl -u dual-ha-mieru -n 50 --no-pager; exit 1; }
echo "Checking Foreign-2 real HTTPS egress..."
curl --socks5-hostname 127.0.0.1:21002 --connect-timeout 5 --max-time 15 -fsS https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='
echo "Mieru ready on 127.0.0.1:21002; existing Xray/REALITY untouched."
