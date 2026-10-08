#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$B/common.sh"
root_only
packages
mkdirs
install_xray

PUBLIC_IP=''
DOMAIN=''
EMAIL=''

read -r -p 'Maya4 foreign public IPv4: ' PUBLIC_IP
valid_ipv4 "$PUBLIC_IP" || die 'valid public IPv4 required'
read -r -p 'Maya4 Naive domain: ' DOMAIN
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'valid domain required'
read -r -p "Let's Encrypt email: " EMAIL
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'valid email required'

D=/etc/maya4-naive-foreign
BUNDLE=/root/maya4-naive-client.json
[[ ! -e "$D" && ! -e "$BUNDLE" ]] || die 'existing Maya4 Naive foreign state found; inspect before reinstalling'
! ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || die 'TCP/443 already in use'
! ss -H -ltn 'sport = :2443' 2>/dev/null | grep -q . || die 'TCP/2443 already in use'

mapfile -t dnsips < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$PUBLIC_IP" || die "DNS A record for $DOMAIN must point to $PUBLIC_IP"

install_caddy(){
  local meta tag url digest tmp arc found
  meta=$(mktemp)
  curl -fsSL --retry 4 --connect-timeout 10 --max-time 60 \
    https://api.github.com/repos/klzgrad/forwardproxy/releases/latest -o "$meta"
  tag=$(jq -r '.tag_name // empty' "$meta")
  url=$(jq -r '.assets[] | select(.name=="caddy-forwardproxy-naive.tar.xz") | .browser_download_url' "$meta" | head -n1)
  digest=$(jq -r '.assets[] | select(.name=="caddy-forwardproxy-naive.tar.xz") | (.digest // empty)' "$meta" | head -n1)
  rm -f "$meta"
  [[ -n "$tag" && -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die 'could not resolve verified Caddy forwardproxy release'
  if [[ ! -x "$BIN/caddy-naive-$tag" ]]; then
    tmp=$(mktemp -d); arc="$tmp/caddy.tar.xz"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 -o "$arc" "$url"
    echo "${digest#sha256:}  $arc" | sha256sum -c - >/dev/null || die 'Caddy SHA256 mismatch'
    mkdir -p "$tmp/x"; tar -xJf "$arc" -C "$tmp/x"
    found=$(find "$tmp/x" -type f -name caddy -perm -u+x | head -n1 || true)
    [[ -n "$found" ]] || die 'Caddy archive missing executable'
    install -m 0755 "$found" "$BIN/caddy-naive-$tag"
    rm -rf "$tmp"
  fi
  ln -sfn "$BIN/caddy-naive-$tag" "$BIN/caddy-naive"
}
install_caddy

mkdir -p "$D" /var/www/maya4-naive /var/lib/maya4-caddy/data /var/lib/maya4-caddy/config
chmod 0700 "$D"

USER_NAME="m4-$(openssl rand -hex 4)"
USER_PASS=$(openssl rand -hex 32)
XUDP_UUID=$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)

cat > /var/www/maya4-naive/index.html <<'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Service</title></head><body><main><h1>Service online</h1></main></body></html>
EOF

grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+xudp-maya4\.internal([[:space:]]|$)' /etc/hosts || \
  echo '127.0.0.1 xudp-maya4.internal # maya4-naive-xudp' >> /etc/hosts

cat > "$D/Caddyfile" <<EOF
{
  order forward_proxy before file_server
}
:443, $DOMAIN {
  tls $EMAIL
  encode
  forward_proxy {
    basic_auth $USER_NAME $USER_PASS
    hide_ip
    hide_via
    acl {
      allow xudp-maya4.internal
    }
  }
  root * /var/www/maya4-naive
  file_server
}
EOF
chmod 0600 "$D/Caddyfile"

cat > "$D/xray.json" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "tag":"maya4-xudp-in",
    "listen":"127.0.0.1",
    "port":2443,
    "protocol":"vless",
    "settings":{"users":[{"id":"$XUDP_UUID","email":"maya4-xudp"}],"decryption":"none"},
    "streamSettings":{"network":"raw"}
  }],
  "outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["maya4-xudp-in"],"outboundTag":"direct"}]}
}
EOF
chmod 0600 "$D/xray.json"

"$BIN/caddy-naive" validate --config "$D/Caddyfile" --adapter caddyfile >/dev/null
"$BIN/xray" run -test -c "$D/xray.json" >/dev/null

cat > /etc/systemd/system/maya4-xudp.service <<EOF
[Unit]
Description=Maya4 XUDP backend
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN/xray run -c $D/xray.json
Restart=always
RestartSec=2s
MemoryHigh=160M
MemoryMax=320M
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/maya4-naive-endpoint.service <<EOF
[Unit]
Description=Maya4 Naive HTTPS endpoint
After=network-online.target maya4-xudp.service
Wants=network-online.target
Requires=maya4-xudp.service
[Service]
Type=simple
ExecStart=$BIN/caddy-naive run --config $D/Caddyfile --adapter caddyfile
Restart=always
RestartSec=2s
LimitNOFILE=262144
MemoryHigh=128M
MemoryMax=256M
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
Environment=HOME=/var/lib/maya4-caddy
Environment=XDG_DATA_HOME=/var/lib/maya4-caddy/data
Environment=XDG_CONFIG_HOME=/var/lib/maya4-caddy/config
ReadWritePaths=/var/lib/maya4-caddy /var/www/maya4-naive
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF

systemd-analyze verify /etc/systemd/system/maya4-xudp.service /etc/systemd/system/maya4-naive-endpoint.service >/dev/null
systemctl daemon-reload
systemctl enable --now maya4-xudp.service maya4-naive-endpoint.service >/dev/null

log 'Waiting for TLS readiness'
ready=0
for _ in $(seq 1 90); do
  if curl -fsS --connect-timeout 5 --max-time 10 \
      --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  systemctl is-active --quiet maya4-naive-endpoint.service || break
  sleep 1
done
(( ready == 1 )) || {
  journalctl -u maya4-naive-endpoint.service -n 100 --no-pager >&2 || true
  die 'TLS endpoint did not become ready'
}

export PUBLIC_IP DOMAIN EMAIL USER_NAME USER_PASS XUDP_UUID
python3 - "$BUNDLE" <<'PY'
import json,os,sys
e=os.environ
obj={
  "version":1,
  "kind":"maya4-naive",
  "public_ip":e["PUBLIC_IP"],
  "domain":e["DOMAIN"],
  "port":443,
  "cert_email":e["EMAIL"],
  "username":e["USER_NAME"],
  "password":e["USER_PASS"],
  "xudp_uuid":e["XUDP_UUID"]
}
with open(sys.argv[1],"w") as f:
    json.dump(obj,f,indent=2,sort_keys=True)
os.chmod(sys.argv[1],0o600)
PY
unset USER_PASS XUDP_UUID

log 'SUCCESS: Maya4 Naive foreign is ready'
log "Bundle: $BUNDLE (0600; keep private)"
