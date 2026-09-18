#!/usr/bin/env bash
set -Eeuo pipefail

P=anytls-tunnel
C=/etc/$P
M=/usr/local/bin/mihomo-$P
NODE=${1:-}
ADDR=${2:-}
ACK=${3:-}
CONTROL_PORT=${CONTROL_PORT:-8442}
ALT_PORT=${ALT_PORT:-8443}
REALITY_PORT=${REALITY_PORT:-8444}

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$NODE" =~ ^F[1-5]$ ]] || die "usage: sudo bash $0 F1..F5 PUBLIC_IP --quarantined-canary"
[[ "$ADDR" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid public address"
[[ "$ACK" == "--quarantined-canary" ]] || die "refusing: node must already be quarantined by Bucket5"
[[ -x "$M" ]] || die "missing $M"
[[ -f "$C/config.yaml" ]] || die "missing production config"
systemctl is-active --quiet "$P" || die "$P is not active"
systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge is not active"
ss -H -ltn 'sport = :2443' 2>/dev/null | grep -q '127.0.0.1:2443' || die "XUDP loopback :2443 missing"

case "$NODE" in
  F1|F2|F3)
    PRIMARY_KIND=shadow
    ROLE_ENV=/root/anytls-foreign-a.env
    [[ -f "$ROLE_ENV" ]] || ROLE_ENV=$C/deploy.env
    [[ -f "$ROLE_ENV" ]] || die "cannot find foreign-a env"
    # shellcheck disable=SC1090
    source "$ROLE_ENV"
    : "${COVER_HOST_A:?missing COVER_HOST_A}"
    : "${ANYTLS_PASS_A:?missing ANYTLS_PASS_A}"
    : "${SHADOWTLS_PASS_A:?missing SHADOWTLS_PASS_A}"
    PRIMARY_COVER=$COVER_HOST_A
    PRIMARY_ANYTLS=$ANYTLS_PASS_A
    PRIMARY_LAYER=$SHADOWTLS_PASS_A
    ;;
  F4|F5)
    PRIMARY_KIND=restls
    ROLE_ENV=/root/anytls-foreign-b.env
    [[ -f "$ROLE_ENV" ]] || ROLE_ENV=$C/deploy.env
    [[ -f "$ROLE_ENV" ]] || die "cannot find foreign-b env"
    # shellcheck disable=SC1090
    source "$ROLE_ENV"
    : "${COVER_HOST_B:?missing COVER_HOST_B}"
    : "${ANYTLS_PASS_B:?missing ANYTLS_PASS_B}"
    : "${RESTLS_PASS_B:?missing RESTLS_PASS_B}"
    PRIMARY_COVER=$COVER_HOST_B
    PRIMARY_ANYTLS=$ANYTLS_PASS_B
    PRIMARY_LAYER=$RESTLS_PASS_B
    ;;
esac

CANARY_COVER=${CANARY_COVER:-$PRIMARY_COVER}
[[ "$CANARY_COVER" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid CANARY_COVER"
for p in "$CONTROL_PORT" "$ALT_PORT" "$REALITY_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1024 && p<=65535)) || die "invalid canary port $p"
  if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
    ss -ltnp "sport = :$p" >&2 || true
    die "TCP/$p is already in use; production untouched"
  fi
done

LOWER=${NODE,,}
DIR=/etc/anytls-transport-canary/$LOWER
UNIT=anytls-transport-canary-$LOWER.service
UNIT_PATH=/etc/systemd/system/$UNIT
CLIENT=/root/bucket5-$LOWER-canary-client.json
REMOVE=/usr/local/sbin/bucket5-transport-canary-$LOWER-remove
[[ ! -e "$UNIT_PATH" ]] || die "existing $NODE canary unit found; remove it first with $REMOVE if appropriate"
# A failed pre-activation validation from an older canary script may have left
# only an empty/stale data directory. It is safe to remove when no unit exists.
if [[ -d "$DIR" ]]; then
  log "Removing stale pre-activation canary directory $DIR"
  rm -rf "$DIR"
fi

TMP=$(mktemp -d /tmp/bucket5-transport-sidecar.XXXXXX)
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT
umask 077
# Candidate validation runs as the unprivileged service user. The mktemp parent
# defaults to 0700/root, so explicitly grant traverse only to the service group.
chgrp anytls-tunnel "$TMP"
chmod 0750 "$TMP"
VDIR=$TMP/validate-data
mkdir -p "$VDIR"
chown anytls-tunnel:anytls-tunnel "$VDIR"
chmod 0750 "$VDIR"

ALT_ANYTLS=$(openssl rand -hex 24)
ALT_LAYER=$(openssl rand -hex 24)
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
YAML

if [[ "$PRIMARY_KIND" == shadow ]]; then
cat >>"$CAND" <<YAML
  - name: primary-shadow-port-control
    type: anytls
    listen: 0.0.0.0
    port: ${CONTROL_PORT}
    users:
      tunnel: "${PRIMARY_ANYTLS}"
    shadow-tls:
      enable: true
      version: 3
      users:
        - name: tunnel
          password: "${PRIMARY_LAYER}"
      handshake:
        dest: "${PRIMARY_COVER}:443"

  - name: alternate-restls
    type: anytls
    listen: 0.0.0.0
    port: ${ALT_PORT}
    users:
      canary: "${ALT_ANYTLS}"
    res-tls:
      enable: true
      dest: "${CANARY_COVER}:443"
      password: "${ALT_LAYER}"
YAML
else
cat >>"$CAND" <<YAML
  - name: primary-restls-port-control
    type: anytls
    listen: 0.0.0.0
    port: ${CONTROL_PORT}
    users:
      tunnel: "${PRIMARY_ANYTLS}"
    res-tls:
      enable: true
      dest: "${PRIMARY_COVER}:443"
      password: "${PRIMARY_LAYER}"

  - name: alternate-shadow
    type: anytls
    listen: 0.0.0.0
    port: ${ALT_PORT}
    users:
      canary: "${ALT_ANYTLS}"
    shadow-tls:
      enable: true
      version: 3
      users:
        - name: canary
          password: "${ALT_LAYER}"
      handshake:
        dest: "${CANARY_COVER}:443"
YAML
fi

cat >>"$CAND" <<YAML

  - name: alternate-vless-reality
    type: vless
    listen: 0.0.0.0
    port: ${REALITY_PORT}
    users:
      - username: canary
        uuid: "${REALITY_UUID}"
        flow: xtls-rprx-vision
    reality-config:
      dest: "${CANARY_COVER}:443"
      private-key: "${REALITY_PRIVATE}"
      short-id:
        - "${REALITY_SHORT_ID}"
      server-names:
        - "${CANARY_COVER}"

rules:
  - MATCH,DIRECT
YAML

chown anytls-tunnel:anytls-tunnel "$CAND"
chmod 0600 "$CAND"
log "Validating $NODE sidecar candidate; production :443 is untouched"
VALIDATE_LOG=$TMP/mihomo-validate.log
if ! runuser -u anytls-tunnel -- "$M" -t -d "$VDIR" -f "$CAND" >"$VALIDATE_LOG" 2>&1; then
  echo "----- Mihomo candidate validation -----" >&2
  tail -n 120 "$VALIDATE_LOG" >&2 || true
  echo "----------------------------------------" >&2
  die "sidecar candidate config invalid; production untouched"
fi
log "Candidate validation = OK"

# Only after validation succeeds do we create persistent sidecar state.
mkdir -p "$DIR"
chown anytls-tunnel:anytls-tunnel "$DIR"
chmod 0750 "$DIR"
install -o anytls-tunnel -g anytls-tunnel -m 0600 "$CAND" "$DIR/config.yaml"

cat >"$UNIT_PATH" <<UNIT
[Unit]
Description=Bucket5 transport canary sidecar for $NODE
After=network-online.target anytls-tunnel.service anytls-xudp-bridge.service
Wants=network-online.target
[Service]
Type=simple
User=anytls-tunnel
Group=anytls-tunnel
WorkingDirectory=$DIR
ExecStart=$M -d $DIR -f $DIR/config.yaml
Restart=always
RestartSec=2s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$DIR
[Install]
WantedBy=multi-user.target
UNIT
systemd-analyze verify "$UNIT_PATH" >/dev/null
systemctl daemon-reload
systemctl enable --now "$UNIT" >/dev/null
sleep 2
systemctl is-active --quiet "$UNIT" || { journalctl -u "$UNIT" -n 100 --no-pager >&2 || true; die "canary sidecar failed"; }
for p in "$CONTROL_PORT" "$ALT_PORT" "$REALITY_PORT"; do
  ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . || { journalctl -u "$UNIT" -n 100 --no-pager >&2 || true; die "canary listener TCP/$p missing"; }
done
# Explicitly prove production primary stayed up and was not restarted/reconfigured by this script.
ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || die "production TCP/443 unexpectedly missing"
systemctl is-active --quiet "$P" || die "production $P unexpectedly inactive"

export NODE ADDR PRIMARY_KIND PRIMARY_COVER PRIMARY_ANYTLS PRIMARY_LAYER CONTROL_PORT ALT_PORT CANARY_COVER ALT_ANYTLS ALT_LAYER REALITY_PORT REALITY_UUID REALITY_PUBLIC REALITY_SHORT_ID
python3 - "$CLIENT" <<'PYCLIENT'
import json,os,sys
p=sys.argv[1]; e=os.environ
node=e['NODE']; primary=e['PRIMARY_KIND']
def anytls(kind,port,password,layer,cover):
    return {"kind":"anytls-"+kind,"addr":e['ADDR'],"port":int(port),"cover":cover,
            "password":password,"layer":layer, **({"shadow_version":3} if kind=='shadow' else {"tls_version":"tls13"})}
carriers={
  "primary": anytls(primary,443,e['PRIMARY_ANYTLS'],e['PRIMARY_LAYER'],e['PRIMARY_COVER']),
  "control": anytls(primary,e['CONTROL_PORT'],e['PRIMARY_ANYTLS'],e['PRIMARY_LAYER'],e['PRIMARY_COVER']),
}
alt='restls' if primary=='shadow' else 'shadow'
carriers["alternate"]=anytls(alt,e['ALT_PORT'],e['ALT_ANYTLS'],e['ALT_LAYER'],e['CANARY_COVER'])
carriers["reality"]={"kind":"vless-reality","addr":e['ADDR'],"port":int(e['REALITY_PORT']),
  "server_name":e['CANARY_COVER'],"uuid":e['REALITY_UUID'],"public_key":e['REALITY_PUBLIC'],
  "short_id":e['REALITY_SHORT_ID'],"flow":"xtls-rprx-vision"}
obj={"version":2,"nodes":{node:{"primary_kind":primary,"carriers":carriers}}}
with open(p,'w') as f: json.dump(obj,f,indent=2,sort_keys=True)
os.chmod(p,0o600)
PYCLIENT

cat >"$REMOVE" <<ROLL
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl disable --now '$UNIT' >/dev/null 2>&1 || true
rm -f '$UNIT_PATH'
systemctl daemon-reload
rm -rf '$DIR'
echo 'Removed $NODE transport canary sidecar. Production anytls-tunnel was not modified.'
ROLL
chmod 0700 "$REMOVE"

trap - EXIT
cleanup
log "SUCCESS: $NODE canary sidecar is active; production TCP/443 was not modified"
log "primary=${PRIMARY_KIND}:443, same-transport-control=${CONTROL_PORT}, alternate=${ALT_PORT}, reality=${REALITY_PORT}"
log "Client bundle: $CLIENT (0600; never paste contents into chat/repo)"
log "SHA256 bundle: $(sha256sum "$CLIENT" | awk '{print $1}')"
log "Remove canary: sudo $REMOVE"
