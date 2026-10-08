#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$B/common.sh"
source "$B/lane3-common.sh"
require_root

PUBLIC_IP=''; DOMAIN=''; EMAIL=''; UUID_FILE=''; NONINTERACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --xudp-uuid-file) UUID_FILE=${2:-}; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n "$PUBLIC_IP" || $NONINTERACTIVE -eq 1 ]] || read -r -p 'Public IPv4: ' PUBLIC_IP
[[ -n "$DOMAIN" || $NONINTERACTIVE -eq 1 ]] || read -r -p 'Lane 3 Naive domain: ' DOMAIN
[[ -n "$EMAIL" || $NONINTERACTIVE -eq 1 ]] || read -r -p "Let's Encrypt email: " EMAIL
l3_valid_ipv4 "$PUBLIC_IP" || die 'valid public IPv4 required'
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'valid domain required'
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'valid email required'

D=/etc/dual-trust-mieru/lane3-foreign
BUNDLE=/root/lane3-naive-client.json
for x in "$D" "$BUNDLE" /etc/systemd/system/lane3-naive-endpoint.service /etc/systemd/system/lane3-xudp.service; do
  [[ ! -e "$x" ]] || die "existing Lane 3 Naive state found at $x; uninstall it first"
done

cleanup_failed(){
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    log 'Lane 3 foreign install failed; removing only partial Lane 3 state'
    systemctl disable --now lane3-naive-endpoint.service lane3-xudp.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/lane3-naive-endpoint.service /etc/systemd/system/lane3-xudp.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$D" "$BUNDLE" /var/www/lane3-naive
    sed -i '/# lane3-naive-xudp$/d' /etc/hosts 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup_failed EXIT

install_base_packages
apt-get install -y --no-install-recommends xz-utils >/dev/null
mkdirs
free_port 443
free_port 2443
mapfile -t dnsips < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$PUBLIC_IP" || die "DNS A record for $DOMAIN must point to $PUBLIC_IP before install"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 443/tcp comment 'lane3-naive' >/dev/null || true
fi

install_xray

install_caddy_naive(){
  local meta tag url digest tmp arc found bin
  meta=$(mktemp)
  curl -fsSL --retry 4 --connect-timeout 10 --max-time 60 \
    https://api.github.com/repos/klzgrad/forwardproxy/releases/latest -o "$meta"
  tag=$(jq -r '.tag_name // empty' "$meta")
  url=$(jq -r '.assets[] | select(.name=="caddy-forwardproxy-naive.tar.xz") | .browser_download_url' "$meta" | head -n1)
  digest=$(jq -r '.assets[] | select(.name=="caddy-forwardproxy-naive.tar.xz") | (.digest // empty)' "$meta" | head -n1)
  rm -f "$meta"
  [[ -n "$tag" && -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die 'could not resolve verified Caddy Naive release'
  bin="$BIN_DIR/caddy-naive-$tag"
  if [[ ! -x "$bin" ]]; then
    tmp=$(mktemp -d); arc="$tmp/caddy.tar.xz"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 -o "$arc" "$url"
    echo "${digest#sha256:}  $arc" | sha256sum -c - >/dev/null || die 'Caddy Naive SHA256 mismatch'
    mkdir -p "$tmp/x"; tar -xJf "$arc" -C "$tmp/x"
    found=$(find "$tmp/x" -type f -name caddy -perm -u+x | head -n1 || true)
    [[ -n "$found" ]] || die 'Caddy Naive archive missing caddy executable'
    install -m 0755 "$found" "$bin"
    rm -rf "$tmp"
  fi
  ln -sfn "$bin" "$BIN_DIR/caddy-naive"
}
install_caddy_naive

mkdir -p "$D" /var/www/lane3-naive/assets /var/lib/lane3-caddy/data /var/lib/lane3-caddy/config
chmod 0700 "$D"
USER_NAME="l3-$(openssl rand -hex 4)"
USER_PASS=$(openssl rand -hex 32)
if [[ -n "$UUID_FILE" ]]; then
  [[ -s "$UUID_FILE" ]] || die 'xudp uuid file missing'
  XUDP_UUID=$(tr -d '\r\n ' < "$UUID_FILE")
  [[ "$XUDP_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'invalid supplied XUDP UUID'
else
  XUDP_UUID=$(json_uuid)
fi

cat > /var/www/lane3-naive/index.html <<EOF2
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$DOMAIN</title><link rel="stylesheet" href="/assets/site.css"><link rel="icon" href="/assets/mark.svg"></head>
<body><main><img src="/assets/mark.svg" width="40" height="40" alt=""><h1>Welcome</h1><p>Service is online.</p></main>
<script src="/assets/app.js" defer></script></body></html>
EOF2
cat > /var/www/lane3-naive/assets/site.css <<'EOF2'
:root{font-family:system-ui,-apple-system,sans-serif;color-scheme:light dark}body{margin:0}main{max-width:720px;margin:12vh auto;padding:24px}img{opacity:.85}
EOF2
cat > /var/www/lane3-naive/assets/app.js <<'EOF2'
document.documentElement.dataset.ready='1';
EOF2
cat > /var/www/lane3-naive/assets/mark.svg <<'EOF2'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#777"/><path d="M18 32h28" stroke="#fff" stroke-width="5" stroke-linecap="round"/></svg>
EOF2

grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+xudp-lane3\.internal([[:space:]]|$)' /etc/hosts || \
  echo '127.0.0.1 xudp-lane3.internal # lane3-naive-xudp' >> /etc/hosts

cat > "$D/Caddyfile" <<EOF2
{
  order forward_proxy before file_server
  log {
    exclude http.log.error
  }
}
:443, $DOMAIN {
  tls $EMAIL
  encode
  forward_proxy {
    basic_auth $USER_NAME $USER_PASS
    hide_ip
    hide_via
    probe_resistance
  }
  root * /var/www/lane3-naive
  file_server
}
EOF2
chmod 0600 "$D/Caddyfile"

cat > "$D/xray.json" <<EOF2
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "tag":"lane3-xudp-in","listen":"127.0.0.1","port":2443,"protocol":"vless",
    "settings":{"users":[{"id":"$XUDP_UUID","email":"lane3-xudp"}],"decryption":"none"},
    "streamSettings":{"network":"raw"}
  }],
  "outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["lane3-xudp-in"],"outboundTag":"direct"}]}
}
EOF2
chmod 0600 "$D/xray.json"

"$BIN_DIR/caddy-naive" validate --config "$D/Caddyfile" --adapter caddyfile >/dev/null
"$BIN_DIR/xray" run -test -c "$D/xray.json" >/dev/null

cat > /etc/systemd/system/lane3-xudp.service <<EOF2
[Unit]
Description=Lane 3 XUDP backend
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -c $D/xray.json
Restart=always
RestartSec=2s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

cat > /etc/systemd/system/lane3-naive-endpoint.service <<EOF2
[Unit]
Description=Lane 3 Naive HTTPS endpoint
After=network-online.target lane3-xudp.service
Wants=network-online.target
Requires=lane3-xudp.service
[Service]
Type=simple
ExecStart=$BIN_DIR/caddy-naive run --config $D/Caddyfile --adapter caddyfile
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
Environment=HOME=/var/lib/lane3-caddy
Environment=XDG_DATA_HOME=/var/lib/lane3-caddy/data
Environment=XDG_CONFIG_HOME=/var/lib/lane3-caddy/config
ReadWritePaths=/var/lib/lane3-caddy /var/www/lane3-naive
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

systemd-analyze verify /etc/systemd/system/lane3-xudp.service /etc/systemd/system/lane3-naive-endpoint.service >/dev/null
systemctl daemon-reload
systemctl enable --now lane3-xudp.service lane3-naive-endpoint.service >/dev/null

for _ in $(seq 1 90); do
  systemctl is-active --quiet lane3-naive-endpoint.service && ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . && break
  sleep 1
done
systemctl is-active --quiet lane3-xudp.service || die 'lane3-xudp inactive'
systemctl is-active --quiet lane3-naive-endpoint.service || { journalctl -u lane3-naive-endpoint -n 100 --no-pager >&2 || true; die 'lane3 Naive endpoint inactive'; }
ss -H -ltn 'sport = :2443' | grep -q '127.0.0.1:2443' || die 'Lane 3 XUDP loopback missing'

# Caddy becomes active/listens before ACME certificate issuance necessarily
# finishes. Do not fail the whole install on the first TLS handshake.
log 'Waiting for public TLS/fronting page readiness'
ready=0
for _ in $(seq 1 90); do
  if curl -fsS --connect-timeout 5 --max-time 10 \
      --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  systemctl is-active --quiet lane3-naive-endpoint.service || break
  sleep 1
done
if (( ready != 1 )); then
  journalctl -u lane3-naive-endpoint.service -n 120 --no-pager >&2 || true
  die 'public HTTPS fronting page did not become TLS-ready within 90s'
fi

export PUBLIC_IP DOMAIN EMAIL USER_NAME USER_PASS XUDP_UUID
python3 - "$BUNDLE" <<'PY'
import json,os,sys
e=os.environ
o={"version":1,"kind":"lane3-naive","public_ip":e["PUBLIC_IP"],"domain":e["DOMAIN"],"port":443,
   "cert_email":e["EMAIL"],"username":e["USER_NAME"],"password":e["USER_PASS"],
   "xudp_uuid":e["XUDP_UUID"],"transport":"https"}
with open(sys.argv[1],"w") as f: json.dump(o,f,indent=2,sort_keys=True)
os.chmod(sys.argv[1],0o600)
PY
unset USER_PASS XUDP_UUID

log 'SUCCESS: Lane 3 Naive foreign is healthy on HTTPS/443'
log "Client bundle: $BUNDLE (0600; do not paste into chat/repo)"
log "Bundle SHA256: $(sha256sum "$BUNDLE" | awk '{print $1}')"
trap - EXIT
