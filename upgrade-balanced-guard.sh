#!/usr/bin/env bash
set -Eeuo pipefail
P=anytls-tunnel
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
C=/etc/$P
S=/var/lib/$P
D=$C/deploy.env
E=$C/shared-node.env
CFG=$C/config.yaml
M=/usr/local/bin/mihomo-$P
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f $C/role && "$(tr -d '[:space:]' < $C/role)" == iran ]] || die "Iran role required"
for f in "$D" "$E" "$CFG" "$B/shared-node-render.py" "$B/shared-node-scheduler.sh" "$B/node-full-probe.sh"; do [[ -f "$f" ]] || die "missing $f"; done
for svc in anytls-tunnel anytls-xudp-bridge x-ui; do systemctl is-active --quiet "$svc" || die "$svc inactive; production untouched"; done
# shellcheck disable=SC1090
source "$D"
code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || die "current XUDP path unhealthy; production untouched"

T=$(mktemp -d /tmp/anytls-balanced-upgrade.XXXXXX); chmod 0711 "$T"
cleanup(){ rm -rf "$T"; }; trap cleanup EXIT
python3 "$B/shared-node-render.py" "$D" "$E" "$T/config.yaml"
chown anytls-tunnel:anytls-tunnel "$T/config.yaml"; chmod 0600 "$T/config.yaml"
runuser -u anytls-tunnel -- "$M" -t -d "$C" -f "$T/config.yaml" >/dev/null || die "candidate config invalid; production untouched"

mkdir -p "$S/backups"
BK=$S/backups/balanced-guard-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$BK"
cp -a "$CFG" "$BK/config.yaml"
cp -a "$E" "$BK/shared-node.env"
API=http://127.0.0.1:${LOCAL_CONTROLLER_PORT}; AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
reload(){ [[ "$(curl -sS -o "$T/reload" -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -X PUT "$API/configs?force=true" -d '{"path":"/etc/anytls-tunnel/config.yaml","payload":""}' || true)" == 204 ]]; }
rollback(){ log "ROLLBACK: restoring previous Mihomo config"; cp -a "$BK/config.yaml" "$CFG"; chown anytls-tunnel:anytls-tunnel "$CFG"; chmod 0600 "$CFG"; reload || log "WARNING: rollback API reload failed; no automatic service restart was attempted"; }
trap 'rc=$?; if ((rc!=0)); then rollback; fi; cleanup' EXIT

install -m 0755 "$B/node-full-probe.sh" /usr/local/sbin/anytls-node-full-probe
install -m 0755 "$B/shared-node-scheduler.sh" /usr/local/sbin/anytls-shared-scheduler
cat >/etc/systemd/system/anytls-shared-scheduler.service <<'UNIT'
[Unit]
Description=AnyTLS all-node health gate and shared F5 scheduler
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
Description=AnyTLS all-node health gate timer
[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true
Unit=anytls-shared-scheduler.service
[Install]
WantedBy=timers.target
UNIT
systemd-analyze verify /etc/systemd/system/anytls-shared-scheduler.{service,timer} >/dev/null

log "Activating candidate via Mihomo API only; x-ui and XUDP are not restarted"
cp "$T/config.yaml" "$CFG"; chown anytls-tunnel:anytls-tunnel "$CFG"; chmod 0600 "$CFG"
reload || die "Mihomo API reload failed"
systemctl daemon-reload
systemctl enable --now anytls-shared-scheduler.timer >/dev/null
systemctl start anytls-shared-scheduler.service
sel=$(curl -fsS "${AUTH[@]}" "$API/proxies/TUNNEL" | jq -r '.now // empty')
[[ -n "$sel" ]] || die "TUNNEL selector unavailable after upgrade"
trap - EXIT; cleanup
log "SUCCESS: all-node health gate enabled; current selector=$sel"
log "Healthy multi-node subsets use round-robin. Failed nodes are excluded and their existing Mihomo connections are drained."
