#!/usr/bin/env bash
set -Eeuo pipefail

P=anytls-tunnel
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
C=/etc/$P
S=/var/lib/$P
D=$C/deploy.env
OLD_SHARED=$C/shared-node.env
E=$C/bucket5.env
CFG=$C/config.yaml
XCFG=$C/xudp-bridge.json
XDB=/etc/x-ui/x-ui.db
M=/usr/local/bin/mihomo-$P
X=/usr/local/lib/$P/xray-v26.3.27
PROFILE=${1:-}

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$PROFILE" == maya1 || "$PROFILE" == maya3 ]] || die "usage: sudo bash install-bucket5.sh maya1|maya3"
for f in "$D" "$CFG" "$XCFG" "$XDB" "$B/bucket5-render.py" "$B/bucket5-probe.sh" "$B/bucket5-scheduler.py" "$B/bucket5-xui.py" "$B/bucket5-reconcile.sh" "$B/bucket5-status.sh"; do
  [[ -f "$f" ]] || die "missing $f"
done
for svc in anytls-tunnel anytls-xudp-bridge x-ui; do
  systemctl is-active --quiet "$svc" || die "$svc inactive; production untouched"
done
source "$D"
command -v jq >/dev/null || die "jq missing"
command -v sqlite3 >/dev/null || die "sqlite3 missing"

log "Auditing current x-ui users; routing requires unique non-empty client emails"
python3 "$B/bucket5-xui.py" audit

XUDP_UUID=$(jq -r '.outbounds[]? | select((.tag // "") | startswith("xudp-inner")) | .settings.id // empty' "$XCFG" | head -n1)
[[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "could not read current XUDP UUID"

T=$(mktemp -d /tmp/anytls-bucket5-install.XXXXXX)
chmod 0700 "$T"
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT
TE=$T/bucket5.env
umask 077

declare -A ADDR TYPE COVER ANYTLS LAYER
TYPE[F1]=shadow; TYPE[F2]=restls; TYPE[F3]=shadow; TYPE[F4]=restls; TYPE[F5]=shadow
if [[ "$PROFILE" == maya1 ]]; then
  ADDR[F1]="${NODE_A_ADDR:-}"; COVER[F1]="${COVER_HOST_A:-}"; ANYTLS[F1]="${ANYTLS_PASS_A:-}"; LAYER[F1]="${SHADOWTLS_PASS_A:-}"
  ADDR[F2]="${NODE_B_ADDR:-}"; COVER[F2]="${COVER_HOST_B:-}"; ANYTLS[F2]="${ANYTLS_PASS_B:-}"; LAYER[F2]="${RESTLS_PASS_B:-}"
else
  ADDR[F3]="${NODE_A_ADDR:-}"; COVER[F3]="${COVER_HOST_A:-}"; ANYTLS[F3]="${ANYTLS_PASS_A:-}"; LAYER[F3]="${SHADOWTLS_PASS_A:-}"
  ADDR[F4]="${NODE_B_ADDR:-}"; COVER[F4]="${COVER_HOST_B:-}"; ANYTLS[F4]="${ANYTLS_PASS_B:-}"; LAYER[F4]="${RESTLS_PASS_B:-}"
fi
if [[ -f "$OLD_SHARED" ]]; then
  source "$OLD_SHARED"
  ADDR[F5]="${SHARED_ADDR:-}"; COVER[F5]="${SHARED_COVER:-}"; ANYTLS[F5]="${SHARED_ANYTLS_PASS:-}"; LAYER[F5]="${SHARED_SHADOWTLS_PASS:-}"
fi

prompt_node(){
  local n=$1 default_cover val
  [[ "${TYPE[$n]}" == shadow ]] && default_cover=www.cloudflare.com || default_cover=www.microsoft.com
  if [[ -n "${ADDR[$n]:-}" && -n "${ANYTLS[$n]:-}" && -n "${LAYER[$n]:-}" ]]; then
    COVER[$n]="${COVER[$n]:-$default_cover}"
    log "$n credentials reused from existing local configuration"
    return
  fi
  echo
  echo "=== $n (${TYPE[$n]}) ==="
  read -r -p "$n public IP/hostname: " val
  [[ "$val" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid $n address"
  ADDR[$n]=$val
  read -r -p "$n cover [$default_cover]: " val
  COVER[$n]=${val:-$default_cover}
  while :; do read -r -s -p "$n AnyTLS password: " val; echo; ((${#val}>=24)) && { ANYTLS[$n]=$val; break; }; echo "too short"; done
  while :; do
    if [[ "${TYPE[$n]}" == shadow ]]; then read -r -s -p "$n ShadowTLS password: " val; else read -r -s -p "$n ResTLS password: " val; fi
    echo; ((${#val}>=24)) && { LAYER[$n]=$val; break; }; echo "too short"
  done
}
for n in F1 F2 F3 F4 F5; do prompt_node "$n"; done

{
  printf 'PROFILE=%q\n' "$PROFILE"
  for n in F1 F2 F3 F4 F5; do
    printf '%s_ADDR=%q\n' "$n" "${ADDR[$n]}"
    printf '%s_TYPE=%q\n' "$n" "${TYPE[$n]}"
    printf '%s_COVER=%q\n' "$n" "${COVER[$n]}"
    printf '%s_ANYTLS=%q\n' "$n" "${ANYTLS[$n]}"
    printf '%s_LAYER=%q\n' "$n" "${LAYER[$n]}"
  done
} >"$TE"
chmod 0600 "$TE"

log "Pre-activation full isolated probe of ALL five Foreign nodes"
for n in F1 F2 F3 F4 F5; do BUCKET5_ENV="$TE" bash "$B/bucket5-probe.sh" "$n"; done
log "ALL FIVE FOREIGN NODES PASSED"

python3 "$B/bucket5-render.py" "$D" "$TE" "$XUDP_UUID" "$T/rendered"
chown anytls-tunnel:anytls-tunnel "$T/rendered/mihomo.yaml"
chmod 0600 "$T/rendered/mihomo.yaml"
runuser -u anytls-tunnel -- "$M" -t -d "$C" -f "$T/rendered/mihomo.yaml" >/dev/null || die "candidate Mihomo config invalid"
"$X" run -test -c "$T/rendered/xudp-bridge.json" >/dev/null || die "candidate XUDP config invalid"

mkdir -p "$S/backups"
BK=$S/backups/bucket5-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$BK"
cp -a "$CFG" "$BK/config.yaml"
cp -a "$XCFG" "$BK/xudp-bridge.json"
cp -a "$XDB" "$BK/x-ui.db"
[[ -f "$E" ]] && cp -a "$E" "$BK/bucket5.env" || true
[[ -f "$S/bucket5-users.json" ]] && cp -a "$S/bucket5-users.json" "$BK/bucket5-users.json" || true
OLD_SHARED_ACTIVE=0; OLD_BUCKET_ACTIVE=0
systemctl is-active --quiet anytls-shared-scheduler.timer 2>/dev/null && OLD_SHARED_ACTIVE=1 || true
systemctl is-active --quiet anytls-bucket5-scheduler.timer 2>/dev/null && OLD_BUCKET_ACTIVE=1 || true

API="http://127.0.0.1:${LOCAL_CONTROLLER_PORT}"
AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
reload_mihomo(){
  [[ "$(curl -sS -o "$T/reload.out" -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -X PUT "$API/configs?force=true" -d '{"path":"/etc/anytls-tunnel/config.yaml","payload":""}' || true)" == 204 ]]
}
rollback(){
  log "ROLLBACK: restoring pre-bucket5 state"
  systemctl stop x-ui >/dev/null 2>&1 || true
  cp -a "$BK/x-ui.db" "$XDB" || true
  cp -a "$BK/xudp-bridge.json" "$XCFG" || true
  cp -a "$BK/config.yaml" "$CFG" || true
  if [[ -f "$BK/bucket5-users.json" ]]; then cp -a "$BK/bucket5-users.json" "$S/bucket5-users.json"; else rm -f "$S/bucket5-users.json"; fi
  chown anytls-tunnel:anytls-tunnel "$CFG" 2>/dev/null || true
  chmod 0600 "$CFG" "$XCFG" 2>/dev/null || true
  reload_mihomo || log "WARNING: Mihomo rollback API reload failed"
  systemctl restart anytls-xudp-bridge >/dev/null 2>&1 || true
  systemctl start x-ui >/dev/null 2>&1 || true
  if (( OLD_SHARED_ACTIVE )); then systemctl enable --now anytls-shared-scheduler.timer >/dev/null 2>&1 || true; fi
  if (( OLD_BUCKET_ACTIVE )); then systemctl enable --now anytls-bucket5-scheduler.timer >/dev/null 2>&1 || true; fi
}
trap 'rc=$?; if ((rc!=0)); then rollback; fi; cleanup' EXIT

log "Disabling old schedulers during controlled migration"
systemctl disable --now anytls-shared-scheduler.timer >/dev/null 2>&1 || true
systemctl disable --now anytls-bucket5-scheduler.timer >/dev/null 2>&1 || true

install -m 0600 "$TE" "$E"
install -m 0755 "$B/bucket5-probe.sh" /usr/local/sbin/anytls-bucket5-probe
install -m 0755 "$B/bucket5-scheduler.py" /usr/local/sbin/anytls-bucket5-scheduler
install -m 0755 "$B/bucket5-xui.py" /usr/local/sbin/anytls-bucket5-xui
install -m 0755 "$B/bucket5-reconcile.sh" /usr/local/sbin/anytls-bucket5-reconcile
install -m 0755 "$B/bucket5-status.sh" /usr/local/sbin/anytls-bucket5-status

log "Loading five-node Mihomo config via controller API; no Mihomo service restart"
cp "$T/rendered/mihomo.yaml" "$CFG"
chown anytls-tunnel:anytls-tunnel "$CFG"; chmod 0600 "$CFG"
reload_mihomo || die "Mihomo API reload failed"
for p in 7890 7901 7902 7903 7904 7905 7906 7907 7908 7909 7910; do ss -H -ltn "sport = :$p" | grep -q . || die "Mihomo listener $p missing"; done

log "Installing multi-bucket XUDP bridge (one controlled bridge restart)"
cp "$T/rendered/xudp-bridge.json" "$XCFG"; chmod 0600 "$XCFG"
systemctl restart anytls-xudp-bridge
sleep 2
systemctl is-active --quiet anytls-xudp-bridge || die "XUDP bridge failed"
for p in 7891 8101 8102 8103 8104 8105 8106 8107 8108 8109 8110; do ss -H -ltn "sport = :$p" | grep -q . || die "XUDP listener $p missing"; done

log "Smoke-testing all 10 bucket paths before routing users"
for p in 8101 8102 8103 8104 8105 8106 8107 8108 8109 8110; do
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$p" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  [[ "$code" == 204 ]] || die "bucket path port $p failed HTTP=$code"
done

log "Creating stable user->bucket routing (one controlled x-ui restart)"
systemctl stop x-ui
python3 /usr/local/sbin/anytls-bucket5-xui sync "$PROFILE"
systemctl start x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui failed after bucket routing patch"
python3 /usr/local/sbin/anytls-bucket5-xui verify "$PROFILE"

cat >/etc/systemd/system/anytls-bucket5-scheduler.service <<'UNIT'
[Unit]
Description=AnyTLS Bucket5 health and load scheduler
After=network-online.target anytls-tunnel.service anytls-xudp-bridge.service x-ui.service
Requires=anytls-tunnel.service anytls-xudp-bridge.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/anytls-bucket5-scheduler
Nice=10
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/anytls-tunnel
UNIT
cat >/etc/systemd/system/anytls-bucket5-scheduler.timer <<'UNIT'
[Unit]
Description=AnyTLS Bucket5 scheduler timer
[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true
Unit=anytls-bucket5-scheduler.service
[Install]
WantedBy=timers.target
UNIT
systemd-analyze verify /etc/systemd/system/anytls-bucket5-scheduler.{service,timer} >/dev/null
systemctl daemon-reload
rm -f "$S/bucket5-state.json"
systemctl enable --now anytls-bucket5-scheduler.timer >/dev/null
systemctl start anytls-bucket5-scheduler.service

trap - EXIT
cleanup
log "SUCCESS: Bucket5 mode installed on $PROFILE"
log "10 stable local buckets -> 5 Foreign nodes; initial target is ~2 buckets/node on this Iran gateway."
log "Run: sudo anytls-bucket5-status"
