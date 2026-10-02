#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root

PUBLIC_IP=''; DOMAIN=''; EMAIL=''; NONINTERACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
valid_ipv4(){
  local IFS=. a b c d extra o
  read -r a b c d extra <<<"$1"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && (( 10#$o <= 255 )) || return 1; done
}
[[ -n "$PUBLIC_IP" || $NONINTERACTIVE -eq 1 ]] || read -r -p 'Public IPv4: ' PUBLIC_IP
[[ -n "$DOMAIN" || $NONINTERACTIVE -eq 1 ]] || read -r -p 'Naive domain: ' DOMAIN
[[ -n "$EMAIL" || $NONINTERACTIVE -eq 1 ]] || read -r -p "Let's Encrypt email: " EMAIL
valid_ipv4 "$PUBLIC_IP" || die 'valid public IPv4 required'
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'valid domain required'
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'valid email required'

D="$CONFIG_DIR/naive"
BUNDLE=/root/dual-naive-client.json
for x in "$D" "$BUNDLE" /etc/systemd/system/dual-naive-endpoint.service /etc/systemd/system/dual-xudp-naive.service; do
  [[ ! -e "$x" ]] || die "existing Naive state found at $x; run uninstall-foreign-naive.sh first"
done

install_base_packages
mkdirs
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 443/tcp comment 'dual-naive-https' >/dev/null || true
fi
mapfile -t resolved < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
printf '%s\n' "${resolved[@]:-}" | grep -Fxq "$PUBLIC_IP" || die "DNS A record for $DOMAIN must point to $PUBLIC_IP before install"

install_xray

install_caddy_naive(){
  local meta tag url digest tmp arc found
  meta=$(mktemp)
  curl -fsSL --retry 4 --connect-timeout 10 --max-time 60 \
    https://api.github.com/repos/klzgrad/forwardproxy/releases/latest -o "$meta"
  tag=$(jq -r '.tag_name // empty' "$meta")
  url=$(jq -r '.assets[] | select(.name=="caddy-forwardproxy-naive.tar.xz") | .browser_download_url' "$meta" | head -n1)
  digest=$(jq -r '.assets[] | select(.name=="caddy-forwardproxy-naive.tar.xz") | (.digest // empty)' "$meta" | head -n1)
  rm -f "$meta"
  [[ -n "$tag" && -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die 'could not resolve verified Caddy Naive release'
  if [[ ! -x "$BIN_DIR/caddy-naive-$tag" ]]; then
    tmp=$(mktemp -d); arc="$tmp/caddy.tar.xz"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 -o "$arc" "$url"
    echo "${digest#sha256:}  $arc" | sha256sum -c - >/dev/null || die 'Caddy Naive SHA256 mismatch'
    mkdir -p "$tmp/x"; tar -xJf "$arc" -C "$tmp/x"
    found=$(find "$tmp/x" -type f -name caddy -perm -u+x | head -n1 || true)
    [[ -n "$found" ]] || die 'Caddy Naive archive missing caddy executable'
    install -m 0755 "$found" "$BIN_DIR/caddy-naive-$tag"
    rm -rf "$tmp"
  fi
  ln -sfn "$BIN_DIR/caddy-naive-$tag" "$BIN_DIR/caddy-naive"
  "$BIN_DIR/caddy-naive" version
}
install_caddy_naive

mkdir -p "$D" /var/www/dual-naive-site
chmod 0700 "$D"
USER_NAME="dnm-$(openssl rand -hex 4)"
USER_PASS=$(openssl rand -hex 32)
XUDP_UUID=$(json_uuid)

cat > /var/www/dual-naive-site/index.html <<EOF2
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$DOMAIN</title></head><body><main style="max-width:720px;margin:12vh auto;font:16px system-ui;padding:24px">
<h1>Welcome</h1><p>This site is online.</p></main></body></html>
EOF2

for h in xudp-naive.internal xudp-trust.internal; do
  if ! getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | grep -Fxq '127.0.0.1'; then
    printf '127.0.0.1 %s # dual-naive-xudp-backend\n' "$h" >> /etc/hosts
  fi
done

cat > "$D/Caddyfile" <<EOF2
{
  order forward_proxy before file_server
  email $EMAIL
  log {
    exclude http.log.error
  }
}
:443, $DOMAIN {
  encode
  forward_proxy {
    basic_auth $USER_NAME $USER_PASS
    hide_ip
    hide_via
    probe_resistance
  }
  root * /var/www/dual-naive-site
  file_server
}
EOF2
chmod 0600 "$D/Caddyfile"

cat > "$D/xray.json" <<EOF2
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "tag":"xudp-in","listen":"127.0.0.1","port":2443,"protocol":"vless",
    "settings":{"users":[{"id":"$XUDP_UUID","email":"dual-naive-xudp"}],"decryption":"none"},
    "streamSettings":{"network":"raw"}
  }],
  "outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["xudp-in"],"outboundTag":"direct"}]}
}
EOF2
chmod 0600 "$D/xray.json"

log 'Validating Naive Caddy and Xray configs'
"$BIN_DIR/caddy-naive" validate --config "$D/Caddyfile" --adapter caddyfile >/dev/null
"$BIN_DIR/xray" run -test -c "$D/xray.json" >/dev/null

cat > /etc/systemd/system/dual-xudp-naive.service <<EOF2
[Unit]
Description=Dual Naive/Mieru XUDP endpoint (Naive foreign)
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

cat > /etc/systemd/system/dual-naive-endpoint.service <<EOF2
[Unit]
Description=Naive HTTPS endpoint for dual tunnel
After=network-online.target dual-xudp-naive.service
Wants=network-online.target
Requires=dual-xudp-naive.service
[Service]
Type=simple
ExecStart=$BIN_DIR/caddy-naive run --config $D/Caddyfile --adapter caddyfile
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
Environment=HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy/data
Environment=XDG_CONFIG_HOME=/var/lib/caddy/config
ReadWritePaths=/var/lib/caddy /var/www/dual-naive-site
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2
mkdir -p /var/lib/caddy/data /var/lib/caddy/config
systemd-analyze verify /etc/systemd/system/dual-xudp-naive.service /etc/systemd/system/dual-naive-endpoint.service >/dev/null
systemctl daemon-reload
systemctl enable --now dual-xudp-naive.service dual-naive-endpoint.service >/dev/null

for _ in $(seq 1 60); do
  systemctl is-active --quiet dual-naive-endpoint.service && ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . && break
  sleep .5
done
systemctl is-active --quiet dual-xudp-naive.service || die 'dual-xudp-naive inactive'
systemctl is-active --quiet dual-naive-endpoint.service || { journalctl -u dual-naive-endpoint -n 80 --no-pager >&2 || true; die 'dual-naive-endpoint inactive'; }
ss -H -ltn 'sport = :2443' | grep -q '127.0.0.1:2443' || die 'XUDP loopback :2443 missing'
ss -H -ltn 'sport = :443' | grep -q . || die 'Naive TCP/443 missing'

log 'Waiting for public TLS/fronting page readiness'
ready=0
for _ in $(seq 1 60); do
  if curl -fsS --connect-timeout 5 --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
(( ready == 1 )) || { journalctl -u dual-naive-endpoint -n 100 --no-pager >&2 || true; die 'Naive HTTPS frontend did not become ready'; }

export PUBLIC_IP DOMAIN USER_NAME USER_PASS XUDP_UUID
python3 - "$BUNDLE" <<'PY'
import json,os,sys
e=os.environ
obj={"version":1,"kind":"naive","public_ip":e["PUBLIC_IP"],"domain":e["DOMAIN"],"port":443,
     "username":e["USER_NAME"],"password":e["USER_PASS"],"xudp_uuid":e["XUDP_UUID"],"transport":"https"}
with open(sys.argv[1],"w") as f: json.dump(obj,f,indent=2,sort_keys=True)
os.chmod(sys.argv[1],0o600)
PY
unset USER_PASS XUDP_UUID
log 'SUCCESS: Naive foreign is healthy on HTTPS/443 with loopback XUDP backend'
log "Client bundle: $BUNDLE (0600; do not paste into chat/repo)"
log "Bundle SHA256: $(sha256sum "$BUNDLE" | awk '{print $1}')"
