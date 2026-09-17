#!/usr/bin/env bash
set -Eeuo pipefail

P=anytls-tunnel
C=/etc/$P
M=/usr/local/bin/mihomo-$P
CFG=$C/config.yaml
ENV_PRIMARY=/root/anytls-foreign-b.env
ENV_FALLBACK=$C/deploy.env
ADDR=${1:-}
ACK=${2:-}
RESTLS_ALT_PORT=${RESTLS_ALT_PORT:-8442}
SHADOW_PORT=${SHADOW_PORT:-8443}
REALITY_PORT=${REALITY_PORT:-8444}

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$ACK" == "--retired-canary" ]] || die "usage: sudo bash $0 OLD_F4_PUBLIC_IP --retired-canary"
[[ "$ADDR" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid public address"
[[ -x "$M" ]] || die "missing $M"
[[ -f "$CFG" ]] || die "missing $CFG"
systemctl is-active --quiet "$P" || die "$P is not active"
systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge is not active"

ROLE_ENV=""
if [[ -f "$ENV_PRIMARY" ]]; then ROLE_ENV=$ENV_PRIMARY
elif [[ -f "$ENV_FALLBACK" ]]; then ROLE_ENV=$ENV_FALLBACK
else die "cannot find foreign-b env"
fi
# shellcheck disable=SC1090
source "$ROLE_ENV"
: "${COVER_HOST_B:?missing COVER_HOST_B}"
: "${ANYTLS_PASS_B:?missing ANYTLS_PASS_B}"
: "${RESTLS_PASS_B:?missing RESTLS_PASS_B}"

SHADOW_COVER=${SHADOW_COVER:-$COVER_HOST_B}
REALITY_COVER=${REALITY_COVER:-$COVER_HOST_B}
[[ "$SHADOW_COVER" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid SHADOW_COVER"
[[ "$REALITY_COVER" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid REALITY_COVER"
for p in "$RESTLS_ALT_PORT" "$SHADOW_PORT" "$REALITY_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1 && p<=65535)) || die "invalid port $p"
  if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
    ss -ltnp "sport = :$p" >&2 || true
    die "TCP/$p is already in use; production untouched"
  fi
done

TMP=$(mktemp -d /tmp/bucket5-transport-foreign.XXXXXX)
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT
umask 077

SHADOW_ANYTLS=$(openssl rand -hex 24)
SHADOW_LAYER=$(openssl rand -hex 24)
REALITY_UUID=$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)
REALITY_SHORT_ID=$(openssl rand -hex 8)
KEYS=$("$M" generate reality-keypair 2>/dev/null || true)
REALITY_PRIVATE=$(printf '%s\n' "$KEYS" | awk -F': *' '/PrivateKey/{print $2; exit}')
REALITY_PUBLIC=$(printf '%s\n' "$KEYS" | awk -F': *' '/PublicKey/{print $2; exit}')
[[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "mihomo could not generate Reality keypair"

CAND=$TMP/config.yaml
cat >"$CAND" <<YAML
mode: rule
log-level: info
ipv6: false

listeners:
  - name: anytls-restls-primary
    type: anytls
    listen: 0.0.0.0
    port: 443
    users:
      tunnel: "${ANYTLS_PASS_B}"
    res-tls:
      enable: true
      dest: "${COVER_HOST_B}:443"
      password: "${RESTLS_PASS_B}"

  - name: anytls-restls-port-control
    type: anytls
    listen: 0.0.0.0
    port: ${RESTLS_ALT_PORT}
    users:
      tunnel: "${ANYTLS_PASS_B}"
    res-tls:
      enable: true
      dest: "${COVER_HOST_B}:443"
      password: "${RESTLS_PASS_B}"

  - name: anytls-shadowtls-v3-canary
    type: anytls
    listen: 0.0.0.0
    port: ${SHADOW_PORT}
    users:
      canary: "${SHADOW_ANYTLS}"
    shadow-tls:
      enable: true
      version: 3
      users:
        - name: canary
          password: "${SHADOW_LAYER}"
      handshake:
        dest: "${SHADOW_COVER}:443"

  - name: vless-reality-canary
    type: vless
    listen: 0.0.0.0
    port: ${REALITY_PORT}
    users:
      - username: canary
        uuid: "${REALITY_UUID}"
        flow: xtls-rprx-vision
    reality-config:
      dest: "${REALITY_COVER}:443"
      private-key: "${REALITY_PRIVATE}"
      short-id:
        - "${REALITY_SHORT_ID}"
      server-names:
        - "${REALITY_COVER}"

rules:
  - MATCH,DIRECT
YAML

chown anytls-tunnel:anytls-tunnel "$CAND"
chmod 0600 "$CAND"
log "Validating three-listener Mihomo candidate"
runuser -u anytls-tunnel -- "$M" -t -d "$C" -f "$CAND" >/dev/null || die "candidate config invalid; production untouched"

BK=/var/lib/$P/backups/transport-canary-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$BK"
chmod 0700 "$BK"
cp -a "$CFG" "$BK/config.yaml"
[[ -f "$ROLE_ENV" ]] && cp -a "$ROLE_ENV" "$BK/role.env"

rollback(){
  set +e
  log "ROLLBACK: restoring previous foreign config"
  cp -a "$BK/config.yaml" "$CFG"
  chown anytls-tunnel:anytls-tunnel "$CFG"
  chmod 0600 "$CFG"
  systemctl restart "$P"
}
trap 'rc=$?; if ((rc!=0)); then rollback; fi; cleanup' EXIT

install -o anytls-tunnel -g anytls-tunnel -m 0600 "$CAND" "$CFG"
log "Activating canary listeners with one controlled Mihomo restart"
systemctl restart "$P"
sleep 2
systemctl is-active --quiet "$P" || { journalctl -u "$P" -n 100 --no-pager >&2 || true; die "Mihomo failed after activation"; }
for p in 443 "$RESTLS_ALT_PORT" "$SHADOW_PORT" "$REALITY_PORT"; do
  ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . || { journalctl -u "$P" -n 100 --no-pager >&2 || true; die "listener TCP/$p missing"; }
done
ss -H -ltn "sport = :2443" 2>/dev/null | grep -q '127.0.0.1:2443' || die "XUDP loopback :2443 missing"

CLIENT=/root/bucket5-f4-canary-client.json
export ADDR COVER_HOST_B ANYTLS_PASS_B RESTLS_PASS_B RESTLS_ALT_PORT SHADOW_PORT SHADOW_COVER SHADOW_ANYTLS SHADOW_LAYER
export REALITY_PORT REALITY_COVER REALITY_UUID REALITY_PUBLIC REALITY_SHORT_ID
python3 - "$CLIENT" <<'PYCLIENT'
import json,os,sys
path=sys.argv[1]
e=os.environ
obj={
  "version":1,
  "nodes":{
    "F4":{
      "carriers":{
        "restls":{
          "kind":"anytls-restls","addr":e["ADDR"],"port":443,
          "cover":e["COVER_HOST_B"],"password":e["ANYTLS_PASS_B"],"layer":e["RESTLS_PASS_B"],
          "tls_version":"tls13"
        },
        "restls_alt":{
          "kind":"anytls-restls","addr":e["ADDR"],"port":int(e["RESTLS_ALT_PORT"]),
          "cover":e["COVER_HOST_B"],"password":e["ANYTLS_PASS_B"],"layer":e["RESTLS_PASS_B"],
          "tls_version":"tls13"
        },
        "shadow":{
          "kind":"anytls-shadow","addr":e["ADDR"],"port":int(e["SHADOW_PORT"]),
          "cover":e["SHADOW_COVER"],"password":e["SHADOW_ANYTLS"],"layer":e["SHADOW_LAYER"],
          "shadow_version":3
        },
        "reality":{
          "kind":"vless-reality","addr":e["ADDR"],"port":int(e["REALITY_PORT"]),
          "server_name":e["REALITY_COVER"],"uuid":e["REALITY_UUID"],
          "public_key":e["REALITY_PUBLIC"],"short_id":e["REALITY_SHORT_ID"],
          "flow":"xtls-rprx-vision"
        }
      }
    }
  }
}
with open(path,"w") as f: json.dump(obj,f,indent=2,sort_keys=True)
os.chmod(path,0o600)
PYCLIENT
unset ANYTLS_PASS_B RESTLS_PASS_B SHADOW_ANYTLS SHADOW_LAYER REALITY_UUID REALITY_PUBLIC REALITY_SHORT_ID

ROLLBACK=/root/rollback-bucket5-transport-canary.sh
cat >"$ROLLBACK" <<ROLL
#!/usr/bin/env bash
set -Eeuo pipefail
cp -a '$BK/config.yaml' '$CFG'
chown anytls-tunnel:anytls-tunnel '$CFG'
chmod 0600 '$CFG'
systemctl restart '$P'
systemctl is-active --quiet '$P'
echo 'Rollback complete.'
ROLL
chmod 0700 "$ROLLBACK"

trap - EXIT
cleanup
log "SUCCESS: retired F4 canary exposes ResTLS:443 + control:${RESTLS_ALT_PORT}, ShadowTLS:${SHADOW_PORT}, Reality:${REALITY_PORT}"
log "Client credential bundle created at $CLIENT (mode 0600; do not paste its contents into chat/repo)"
log "SHA256 bundle: $(sha256sum "$CLIENT" | awk '{print $1}')"
log "Rollback command: sudo $ROLLBACK"
