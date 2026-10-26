#!/usr/bin/env bash
# Approved one-time round-robin maintenance; intentionally restarts ONLY dispatcher.
set -Eeuo pipefail
umask 077
CFG=/etc/dual-trust-mieru/iran/dispatcher.yaml
BIN=/usr/local/lib/dual-trust-mieru/mihomo
DATA=/etc/dual-trust-mieru/iran/dispatcher-data
STATE=/var/lib/dual-trust-mieru/naive-mieru
PROTECTED=(x-ui dual-mieru-carrier dual-xudp-bridge nm-naive-client)
SWAPPED=0
FINISHED=0
WORK=''

log() { printf '[RR] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

restore() {
  log 'RESTORE: original Dispatcher YAML; restarting ONLY Dispatcher.' >&2
  if [[ -s "$WORK/original.yaml" ]]; then
    install -m 0600 "$WORK/original.yaml" "$WORK/restore.yaml" || true
    mv -f "$WORK/restore.yaml" "$CFG" || { log 'CRITICAL: could not restore YAML!' >&2; return 1; }
    systemctl restart dual-dispatcher.service || { log 'CRITICAL: rollback restart failed!' >&2; return 1; }
    systemctl is-active --quiet dual-dispatcher.service || { log 'CRITICAL: Dispatcher inactive after rollback!' >&2; return 1; }
    log 'RESTORE COMPLETE: original sticky-sessions configuration recovered.' >&2
  else
    log 'CRITICAL: original backup not available!' >&2
    return 1
  fi
}

finish() {
  local code=$?
  trap - EXIT
  if (( code != 0 && SWAPPED == 1 && FINISHED == 0 )); then
    restore || log 'MANUAL INTERVENTION REQUIRED: rollback unsuccessful' >&2
  fi
  [[ -z "$WORK" ]] || rm -rf -- "$WORK"
  exit "$code"
}
trap finish EXIT

[[ $EUID -eq 0 ]] || die 'run as root'
exec 9>/run/naive-mieru-rr-maintenance.lock
flock -n 9 || die 'another round-robin maintenance is in progress'
[[ -s "$CFG" && -x "$BIN" ]] || die 'Dispatcher config/binary missing'
[[ ! -L "$CFG" ]] || die 'unexpected dispatcher YAML symlink'
[[ -s "$STATE/live-cutover.timestamp" ]] || die 'Naive production cutover unconfirmed'
systemctl is-active --quiet dual-dispatcher.service || die 'Dispatcher currently inactive'
systemctl show -p ExecStart --value dual-dispatcher.service | grep -Fq -- "$CFG" || die 'Dispatcher uses a different config file'
for svc in "${PROTECTED[@]}"; do
  systemctl is-active --quiet "$svc.service" || die "protected service inactive: $svc"
done

for port in 7991 7992; do
  result=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)
  [[ $result == 204 ]] || die "unhealthy carrier :$port before maintenance"
done

mkdir -p "$STATE"
chmod 0700 "$STATE"
WORK=$(mktemp -d "$STATE/.rr-maint-XXXXXXXX")
cp -p -- "$CFG" "$WORK/original.yaml"
chmod 0600 "$WORK/original.yaml"

python3 - "$WORK/original.yaml" "$WORK/candidate.yaml" <<'PY'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text()
assert old.count('    strategy: sticky-sessions\n')==1, 'expected one sticky group'
for marker in ('  - name: DUAL\n', '    type: load-balance\n',
               '  - name: XUDP-TRUST\n', '  - name: XUDP-MIERU\n',
               '      - XUDP-TRUST\n', '      - XUDP-MIERU\n'):
    assert old.count(marker)==1, 'unrecognized dispatcher YAML: '+marker.strip()
new=old.replace('    strategy: sticky-sessions\n','    strategy: round-robin\n',1)
path=pathlib.Path(sys.argv[2]);path.write_text(new);path.chmod(0o600)
print('[RR] ONLY CHANGE: sticky-sessions -> round-robin; Naive/Mieru aliases retained')
PY

log 'Validate complete new YAML before interrupting users'
"$BIN" -t -d "$DATA" -f "$WORK/candidate.yaml" >/dev/null || die 'candidate validation failed'
BACKUP="$STATE/dispatcher-before-rr-$(date -u +%Y%m%dT%H%M%SZ)-$$.yaml"
install -m 0600 "$WORK/original.yaml" "$BACKUP"
log "Permanent root-only backup: $BACKUP"
for svc in "${PROTECTED[@]}"; do
  systemctl show -p MainPID --value "$svc.service"
done > "$WORK/protected-pids.before"

log 'INTENTIONAL INTERRUPTION: restart only dual-dispatcher'
install -m 0600 "$WORK/candidate.yaml" "$WORK/next.yaml"
cmp -s "$CFG" "$WORK/original.yaml" || die 'YAML was concurrently changed; aborting'
mv -f "$WORK/next.yaml" "$CFG"
SWAPPED=1
systemctl restart dual-dispatcher.service || die 'Dispatcher restart failed'

ready=0
for i in $(seq 1 30); do
  if systemctl is-active --quiet dual-dispatcher.service &&
     ss -H -ltn 'sport = :7990' 2>/dev/null | grep -q .; then
    ready=1; break
  fi
  sleep 1
done
(( ready == 1 )) || die 'Dispatcher/listener did not recover within readiness window'

log 'Confirming live Controller group and members'
python3 <<'PY'
import json
from pathlib import Path
from urllib.request import Request,urlopen
secret=Path('/etc/dual-trust-mieru/iran/controller.secret').read_text().strip()
req=Request('http://127.0.0.1:19090/proxies/DUAL',headers={'Authorization':'Bearer '+secret})
with urlopen(req,timeout=8) as resp:
    group=json.load(resp)
assert set(group.get('all',[]))=={'XUDP-TRUST','XUDP-MIERU'}, 'unexpected DUAL membership'
assert group.get('alive') is True, 'DUAL does not report alive'
print('[RR] DUAL=ALIVE, members=NAIVE(legacy alias)+MIERU')
PY

probe() {
  local port=$1 url=$2 allowed=$3 i code rc
  for i in 1 2 3; do
    rc=0
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" \
      --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || rc=$?
    if (( rc == 0 )) && [[ "$code" =~ $allowed ]]; then return 0; fi
    sleep 1
  done
  return 1
}
for port in 7991 7992 7990; do
  probe "$port" 'https://www.gstatic.com/generate_204' '^204$' || die "HTTP probe failed :$port"
  probe "$port" 'https://api.telegram.org/' '^(200|301|302)$' || die "Telegram probe failed :$port"
  log "HEALTHY SOCKS :$port (HTTP + Telegram)"
done

for svc in "${PROTECTED[@]}"; do
  systemctl is-active --quiet "$svc.service" || die "protected service inactive: $svc"
done
for svc in "${PROTECTED[@]}"; do
  systemctl show -p MainPID --value "$svc.service"
done > "$WORK/protected-pids.after"
cmp -s "$WORK/protected-pids.before" "$WORK/protected-pids.after" || die 'protected PID changed'
[[ $(grep -c '^    strategy: round-robin$' "$CFG") -eq 1 ]] || die 'strategy not persisted'
FINISHED=1
log 'SUCCESS: round-robin loaded immediately; both carriers and DUAL tested'
log 'Protected Mieru, Naive, XUDP bridge and x-ui PIDs unchanged'
log 'Legacy internal XUDP-TRUST label still refers to Naive'
log "RESTORE COPY: $BACKUP"
