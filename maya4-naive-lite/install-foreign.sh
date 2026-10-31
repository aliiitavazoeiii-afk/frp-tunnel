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
NONINTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

if [[ -z "$PUBLIC_IP" && $NONINTERACTIVE -eq 0 ]]; then
  read -r -p 'Maya4 foreign public IPv4: ' PUBLIC_IP
fi
valid_ipv4 "$PUBLIC_IP" || die 'valid public IPv4 required'

if [[ -z "$DOMAIN" && $NONINTERACTIVE -eq 0 ]]; then
  read -r -p 'Maya4 Naive domain: ' DOMAIN
fi
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'valid domain required'

if [[ -z "$EMAIL" && $NONINTERACTIVE -eq 0 ]]; then
  read -r -p "Let's Encrypt email: " EMAIL
fi
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'valid email required'

D=/etc/maya4-naive-foreign
BUNDLE=/root/maya4-naive-client.json
RESUME_EXISTING=0
BUNDLE_ALREADY_COMPLETE=0

# The one-input replacement helper can retry after a completed foreign install
# if the later Iran candidate tests or SSH copy failed. Do not treat an
# already-completed, verified foreign deployment as a conflicting partial state.
# Never overwrite an unknown/foreign endpoint on the new VPS.
verify_existing_foreign(){
  FOREIGN_DIR="$D" FOREIGN_BUNDLE="$BUNDLE" EXPECTED_IP="$PUBLIC_IP" \
  EXPECTED_DOMAIN="$DOMAIN" EXPECTED_EMAIL="$EMAIL" python3 <<'PY'
import json,os,pathlib,re,sys
p=pathlib.Path(os.environ["FOREIGN_DIR"])
domain=os.environ["EXPECTED_DOMAIN"];email=os.environ["EXPECTED_EMAIL"]
c=(p/"Caddyfile").read_text()
if f":443, {domain} {{" not in c or f"  tls {email}" not in c:
    sys.exit("ERROR: existing foreign domain / cert email differs; manual inspect required")
matches=re.findall(r'^\\s*basic_auth\\s+(\\S+)\\s+(\\S+)\\s*

if (( RESUME_EXISTING == 0 )); then
  ! ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || die 'TCP/443 already in use'
  ! ss -H -ltn 'sport = :2443' 2>/dev/null | grep -q . || die 'TCP/2443 already in use'
fi

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
if (( RESUME_EXISTING == 0 )); then
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
else
  USER_NAME=$(awk '$1=="basic_auth"{print $2; exit}' "$D/Caddyfile")
  USER_PASS=$(awk '$1=="basic_auth"{print $3; exit}' "$D/Caddyfile")
  XUDP_UUID=$(jq -r '.inbounds[] | select(.tag=="maya4-xudp-in") | .settings.users[0].id // empty' "$D/xray.json")
  [[ -n "$USER_NAME" && -n "$USER_PASS" ]] || die 'could not recover existing Naive credentials'
  [[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'could not recover existing XUDP UUID'
fi

log 'Waiting for TLS readiness'
ready=0
for _ in $(seq 1 90); do
  # Any HTTP status is acceptable here (for example 407 from an authenticated
  # forward proxy). We only require a successful TLS handshake and HTTP exchange.
  if curl -sS --connect-timeout 5 --max-time 10 \
      --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null "https://$DOMAIN/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  systemctl is-active --quiet maya4-naive-endpoint.service || break
  sleep 1
done
(( ready == 1 )) || {
  journalctl -u maya4-naive-endpoint.service -n 100 --no-pager >&2 || true
  die 'TLS handshake did not become ready'
}

if (( BUNDLE_ALREADY_COMPLETE ));then
  log 'Existing private client bundle verified; leaving file unchanged.'
else
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
fi
unset USER_PASS XUDP_UUID

log 'SUCCESS: Maya4 Naive foreign is ready'
log "Bundle: $BUNDLE (0600; keep private)"
,c,re.M)
if len(matches)!=1:
    sys.exit("ERROR: unexpected existing Caddy authentication layout")
xr=json.loads((p/"xray.json").read_text())
users=[u.get("id") for entry in xr.get("inbounds",[])
       if entry.get("tag")=="maya4-xudp-in" for u in entry.get("settings",{}).get("users",[])]
if len(users)!=1 or not re.fullmatch(r'[0-9a-fA-F-]{36}',users[0]):
    sys.exit("ERROR: unexpected existing foreign XUDP config")
bundle=pathlib.Path(os.environ["FOREIGN_BUNDLE"])
if bundle.is_file():
    data=json.loads(bundle.read_text())
    expected={"version":1,"kind":"maya4-naive","public_ip":os.environ["EXPECTED_IP"],
              "domain":domain,"port":443,"cert_email":email,"username":matches[0][0],
              "password":matches[0][1],"xudp_uuid":users[0]}
    if data!=expected:
        sys.exit("ERROR: existing bundle does not match current domain/IP/Caddy/XUDP; abort")
print("Verified existing Maya4 endpoint identity and XUDP credentials (secrets hidden).")
PY
}

state_summary(){
  log 'Read-only FOREIGN state summary (no passwords or UUIDs):'
  for f in "$D/Caddyfile" "$D/xray.json" "$BUNDLE";do
    if [[ -s "$f" ]];then log "present: $f";else log "missing/empty: $f";fi
  done
  for unit in maya4-naive-endpoint maya4-xudp;do
    log "$unit: $(systemctl is-active "$unit.service" 2>/dev/null || true)"
  done
  log 'No old config or systemd service was removed or restarted.'
}

if [[ -d "$D" && -s "$D/Caddyfile" && -s "$D/xray.json" ]] \
   && systemctl is-active --quiet maya4-naive-endpoint.service \
   && systemctl is-active --quiet maya4-xudp.service;then
  # Safely reuse only an endpoint matching the exact requested identity.
  verify_existing_foreign
  if [[ -s "$BUNDLE" ]];then
    BUNDLE_ALREADY_COMPLETE=1
    RESUME_EXISTING=1
    log 'Previously completed Maya4 foreign install verified; reusing it.'
  elif [[ ! -e "$BUNDLE" ]];then
    RESUME_EXISTING=1
    log 'Healthy partial Maya4 foreign install; regenerating missing bundle only.'
  else
    state_summary
    die 'existing bundle is empty or not a regular file; refusing to overwrite'
  fi
elif [[ -e "$D" || -e "$BUNDLE" ]];then
  state_summary
  die 'existing Maya4 foreign state is incomplete or conflicting; inspect before reinstalling'
fi

if (( RESUME_EXISTING == 0 )); then
  ! ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || die 'TCP/443 already in use'
  ! ss -H -ltn 'sport = :2443' 2>/dev/null | grep -q . || die 'TCP/2443 already in use'
fi

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
if (( RESUME_EXISTING == 0 )); then
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
else
  USER_NAME=$(awk '$1=="basic_auth"{print $2; exit}' "$D/Caddyfile")
  USER_PASS=$(awk '$1=="basic_auth"{print $3; exit}' "$D/Caddyfile")
  XUDP_UUID=$(jq -r '.inbounds[] | select(.tag=="maya4-xudp-in") | .settings.users[0].id // empty' "$D/xray.json")
  [[ -n "$USER_NAME" && -n "$USER_PASS" ]] || die 'could not recover existing Naive credentials'
  [[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'could not recover existing XUDP UUID'
fi

log 'Waiting for TLS readiness'
ready=0
for _ in $(seq 1 90); do
  # Any HTTP status is acceptable here (for example 407 from an authenticated
  # forward proxy). We only require a successful TLS handshake and HTTP exchange.
  if curl -sS --connect-timeout 5 --max-time 10 \
      --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null "https://$DOMAIN/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  systemctl is-active --quiet maya4-naive-endpoint.service || break
  sleep 1
done
(( ready == 1 )) || {
  journalctl -u maya4-naive-endpoint.service -n 100 --no-pager >&2 || true
  die 'TLS handshake did not become ready'
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
