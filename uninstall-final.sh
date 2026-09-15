#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
STATE_DIR="/var/lib/${PROJECT}"
ROLE_FILE="${CONFIG_DIR}/role"
XUI_DB="/etc/x-ui/x-ui.db"
PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
ROLE="unknown"
[[ -f "$ROLE_FILE" ]] && ROLE=$(tr -d '[:space:]' < "$ROLE_FILE")
log "Uninstalling AnyTLS final stack; detected role=$ROLE purge=$PURGE"

if [[ "$ROLE" == "iran" && -f "$XUI_DB" ]]; then
  BACKUP="/root/anytls-uninstall-xui-$(date -u +%Y%m%dT%H%M%SZ).db"
  cp -a "$XUI_DB" "$BACKUP"
  chmod 600 "$BACKUP"
  log "x-ui safety backup: $BACKUP"

  restore_xui(){
    log "Restoring x-ui DB after uninstall patch failure"
    systemctl stop x-ui >/dev/null 2>&1 || true
    cp -a "$BACKUP" "$XUI_DB"
    systemctl start x-ui >/dev/null 2>&1 || true
  }
  trap 'rc=$?; if (( rc != 0 )); then restore_xui; fi' EXIT

  systemctl stop x-ui >/dev/null 2>&1 || true
  XUI_DB="$XUI_DB" python3 <<'PY'
import json,os,sqlite3
p=os.environ['XUI_DB']
con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row:
        raise RuntimeError('xrayTemplateConfig not found')
    cfg=json.loads(row[0])
    obs=cfg.get('outbounds') or []
    before=len(obs)
    cfg['outbounds']=[o for o in obs if o.get('tag')!='anytls-tunnel']
    routing=cfg.get('routing') or {}
    rules=routing.get('rules') or []
    routing['rules']=[r for r in rules if r.get('outboundTag')!='anytls-tunnel']
    cfg['routing']=routing
    if not cfg['outbounds']:
        raise RuntimeError('refusing to remove the last x-ui outbound')
    con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",
                (json.dumps(cfg,separators=(',',':')),))
    con.commit()
    print(f'x-ui cleanup: removed {before-len(cfg["outbounds"])} anytls-tunnel outbound(s) and matching route rules')
finally:
    con.close()
PY

  systemctl start x-ui
  sleep 4
  systemctl is-active --quiet x-ui || die "x-ui failed after removing AnyTLS route; DB will be restored"
  ss -H -ltn 'sport = :443' | grep -q . || die "x-ui public :443 missing after cleanup; DB will be restored"
  trap - EXIT
  log "x-ui preserved; AnyTLS outbound/routing removed"
  log "Public inbound sniffing was intentionally left unchanged because it is an x-ui inbound setting, not a service dependency."
fi

for s in anytls-xudp-bridge anytls-tunnel; do
  systemctl disable --now "$s" >/dev/null 2>&1 || true
done

rm -f /etc/systemd/system/anytls-xudp-bridge.service
rm -f /etc/systemd/system/anytls-tunnel.service
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

rm -f /usr/local/bin/mihomo-anytls-tunnel
rm -f /usr/local/sbin/anytls-tunnel-status
rm -f /usr/local/sbin/anytls-tunnel-health
rm -f /usr/local/sbin/anytls-tunnel-probe-test
rm -f /usr/local/sbin/anytls-xudp-health
rm -f /usr/local/sbin/anytls-replace
rm -f /usr/local/sbin/anytls-repair-xui
rm -f /usr/local/sbin/anytls-sync-xui
rm -f /usr/local/sbin/anytls-sync-sniffing
rm -f /usr/local/sbin/anytls-sync-remote-dns
rm -f /usr/local/sbin/anytls-final-health
rm -f /usr/local/sbin/anytls-uninstall

rm -rf /usr/local/lib/anytls-tunnel
rm -rf /etc/anytls-tunnel

if [[ -f /etc/sysctl.d/99-anytls-tunnel.conf ]]; then
  rm -f /etc/sysctl.d/99-anytls-tunnel.conf
  sysctl --system >/dev/null 2>&1 || true
fi

if id anytls-tunnel >/dev/null 2>&1; then
  userdel anytls-tunnel >/dev/null 2>&1 || true
fi

if $PURGE; then
  rm -rf "$STATE_DIR"
  rm -f /root/anytls-iran.env /root/anytls-foreign-a.env /root/anytls-foreign-b.env
  log "Purged AnyTLS backups/state and role env files"
else
  if [[ -d "$STATE_DIR" ]]; then
    log "Preserved backups/state at $STATE_DIR"
  fi
  log "Preserved /root/anytls-*.env files for possible reinstall. Use --purge to delete them."
fi

# Do not automatically remove provider/UFW TCP/443 rules: that port may later be reused.
if [[ "$ROLE" == foreign-* ]]; then
  log "NOTE: firewall/provider TCP/443 allow rules were left untouched intentionally."
fi

if [[ -d /opt/anytls-tunnel ]]; then
  rm -rf /opt/anytls-tunnel
fi

log "SUCCESS: AnyTLS/XUDP project services and files removed"
if [[ "$ROLE" == "iran" ]]; then
  log "x-ui and its users were NOT removed. Safety DB backup remains at: ${BACKUP:-n/a}"
fi
