#!/usr/bin/env bash
set -Eeuo pipefail
P=anytls-tunnel
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
C=/etc/$P
S=/var/lib/$P
D=$C/deploy.env
E=$C/shared-node.env
M=/usr/local/bin/mihomo-$P
CFG=$C/config.yaml
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f $C/role && "$(tr -d '[:space:]' < $C/role)" == iran ]] || die "Iran role required"
for f in "$D" "$CFG" "$B/shared-node-probe.sh" "$B/shared-node-scheduler.sh" "$B/shared-node-render.py" "$B/uninstall-shared-node.sh"; do [[ -f "$f" ]] || die "missing $f"; done
for s in anytls-tunnel anytls-xudp-bridge x-ui; do systemctl is-active --quiet "$s" || die "$s inactive"; done
source "$D"
python3 <<'PY'
import json
c=json.load(open('/usr/local/x-ui/bin/config.json'))
o=[x for x in c.get('outbounds',[]) if x.get('tag')=='anytls-tunnel']
assert len(o)==1 and o[0].get('targetStrategy')=='AsIs'
s=(o[0].get('settings',{}).get('servers') or [{}])[0]
assert s.get('address')=='127.0.0.1' and int(s.get('port') or 0)==7891
i=[x for x in c.get('inbounds',[]) if int(x.get('port',0) or 0)==443 and str(x.get('listen','')) not in ('127.0.0.1','::1','localhost')]
assert len(i)==1 and (i[0].get('sniffing') or {}).get('enabled') is True
print('PRECHECK OK: x-ui remains AsIs + sniffing + 7891')
PY
code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || die "current XUDP path unhealthy; production untouched"

echo "Schedule: maya3=15:00-21:00, maya1=21:00-03:00, timezone=Asia/Tehran"
read -r -p "This server [maya1/maya3]: " profile
[[ "$profile" == maya1 || "$profile" == maya3 ]] || die "invalid profile"
read -r -p "F5 public IP/hostname: " addr
[[ "$addr" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid address"
read -r -p "F5 cover [www.cloudflare.com]: " cover
cover=${cover:-www.cloudflare.com}
[[ "$cover" =~ ^[A-Za-z0-9.-]+$ && "$cover" == *.* ]] || die "invalid cover"
while :; do read -r -s -p "F5 ANYTLS_PASS_A: " ap; echo; ((${#ap}>=24)) && break; echo "too short"; done
while :; do read -r -s -p "F5 SHADOWTLS_PASS_A: " sp; echo; ((${#sp}>=24)) && break; echo "too short"; done

T=$(mktemp -d /tmp/anytls-shared-install.XXXXXX); chmod 0711 "$T"
cleanup(){ rm -rf "$T"; }; trap cleanup EXIT
TE=$T/shared.env
umask 077
printf 'SHARED_PROFILE=%q\nSHARED_ADDR=%q\nSHARED_COVER=%q\nSHARED_ANYTLS_PASS=%q\nSHARED_SHADOWTLS_PASS=%q\n' "$profile" "$addr" "$cover" "$ap" "$sp" >"$TE"
log "F5 not active. Running isolated full probe first."
SHARED_ENV="$TE" bash "$B/shared-node-probe.sh"

python3 "$B/shared-node-render.py" "$D" "$TE" "$T/config.yaml"
chown anytls-tunnel:anytls-tunnel "$T/config.yaml"; chmod 0600 "$T/config.yaml"
runuser -u anytls-tunnel -- "$M" -t -d "$C" -f "$T/config.yaml" >/dev/null || die "candidate invalid"

mkdir -p "$S/backups"
BK=$S/backups/shared-node-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$BK"; cp -a "$CFG" "$BK/config.yaml"; cp -a "$D" "$BK/deploy.env"
API=http://127.0.0.1:${LOCAL_CONTROLLER_PORT}; AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
reload(){ [[ "$(curl -sS -o "$T/a" -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -X PUT "$API/configs?force=true" -d '{"path":"/etc/anytls-tunnel/config.yaml","payload":""}' || true)" == 204 ]]; }
rollback(){ log "ROLLBACK to pre-shared config"; cp -a "$BK/config.yaml" "$CFG"; chown anytls-tunnel:anytls-tunnel "$CFG"; chmod 0600 "$CFG"; reload || log "WARNING: rollback API reload failed; service was NOT restarted automatically"; }
trap 'rc=$?; if ((rc!=0)); then rollback; fi; cleanup' EXIT

install -m 0755 "$B/shared-node-probe.sh" /usr/local/sbin/anytls-shared-probe
install -m 0755 "$B/shared-node-scheduler.sh" /usr/local/sbin/anytls-shared-scheduler
install -m 0755 "$B/uninstall-shared-node.sh" /usr/local/sbin/anytls-shared-uninstall
install -m 0600 "$TE" "$E"

cat >/etc/systemd/system/anytls-shared-scheduler.service <<'UNIT'
[Unit]
Description=AnyTLS shared F5 scheduler
After=network-online.target anytls-tunnel.service anytls-xudp-bridge.service
Requires=anytls-tunnel.service anytls-xudp-bridge.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/anytls-shared-scheduler
Nice=10
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/anytls-tunnel
UNIT
cat >/etc/systemd/system/anytls-shared-scheduler.timer <<'UNIT'
[Unit]
Description=AnyTLS shared F5 scheduler timer
[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true
Unit=anytls-shared-scheduler.service
[Install]
WantedBy=timers.target
UNIT
systemd-analyze verify /etc/systemd/system/anytls-shared-scheduler.{service,timer} >/dev/null

log "Reloading Mihomo by controller API; x-ui/XUDP are not restarted"
cp "$T/config.yaml" "$CFG"; chown anytls-tunnel:anytls-tunnel "$CFG"; chmod 0600 "$CFG"
reload || die "Mihomo API reload failed"
hc=$(curl -sS -o "$T/b" -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -X PUT "$API/proxies/TUNNEL" -d '{"name":"TUNNEL-BASE"}' || true)
[[ "$hc" == 204 ]] || die "could not pin BASE after reload"
[[ "$(curl -fsS "${AUTH[@]}" "$API/proxies/TUNNEL" | jq -r '.now')" == TUNNEL-BASE ]] || die "selector not BASE"
code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || die "production path failed after reload"

systemctl daemon-reload
systemctl enable --now anytls-shared-scheduler.timer >/dev/null
trap - EXIT; cleanup
log "SUCCESS: F5 installed but current traffic remains on BASE. Scheduler will activate it only inside $profile window after health probe."
