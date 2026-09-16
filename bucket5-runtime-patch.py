#!/usr/bin/env python3
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: bucket5-runtime-patch.py INSTALLER_RUNTIME")
p = Path(sys.argv[1])
s = p.read_text()

# The installer temp tree is created under umask 077. Candidate validation runs
# as the unprivileged anytls-tunnel user, so grant traverse permission only to
# that service group while keeping secret files themselves mode 0600.
old_tmp = 'T=$(mktemp -d /tmp/anytls-bucket5-install.XXXXXX)\nchmod 0700 "$T"\n'
new_tmp = 'T=$(mktemp -d /tmp/anytls-bucket5-install.XXXXXX)\nchgrp anytls-tunnel "$T"\nchmod 0750 "$T"\n'
if old_tmp in s:
    s = s.replace(old_tmp, new_tmp, 1)

needle = 'python3 "$B/bucket5-render.py" "$D" "$TE" "$XUDP_UUID" "$T/rendered"\n'
if needle not in s:
    raise SystemExit("ERROR: render marker not found")
if 'chmod 0750 "$T/rendered"' not in s:
    s = s.replace(
        needle,
        needle + 'chown anytls-tunnel:anytls-tunnel "$T/rendered"\nchmod 0750 "$T/rendered"\n',
        1,
    )

# API config reload is not reliable for adding/removing listener sockets. Use a
# controlled Mihomo service restart for activation and for rollback.
old_rollback = '  reload_mihomo || log "WARNING: Mihomo rollback API reload failed"\n'
if old_rollback in s:
    s = s.replace(
        old_rollback,
        '  systemctl restart anytls-tunnel >/dev/null 2>&1 || log "WARNING: Mihomo rollback restart failed"\n',
        1,
    )

old = '''log "Loading five-node Mihomo config via controller API; no Mihomo service restart"
cp "$T/rendered/mihomo.yaml" "$CFG"
chown anytls-tunnel:anytls-tunnel "$CFG"; chmod 0600 "$CFG"
reload_mihomo || die "Mihomo API reload failed"
for p in 7890 7901 7902 7903 7904 7905 7906 7907 7908 7909 7910; do ss -H -ltn "sport = :$p" | grep -q . || die "Mihomo listener $p missing"; done
'''
new = '''log "Activating five-node Mihomo config (one controlled Mihomo restart)"
cp "$T/rendered/mihomo.yaml" "$CFG"
chown anytls-tunnel:anytls-tunnel "$CFG"; chmod 0600 "$CFG"
systemctl restart anytls-tunnel
sleep 2
if ! systemctl is-active --quiet anytls-tunnel; then
  journalctl -u anytls-tunnel -n 80 --no-pager >&2 || true
  die "Mihomo service failed after five-node activation"
fi
for p in 7890 7901 7902 7903 7904 7905 7906 7907 7908 7909 7910; do
  ss -H -ltn "sport = :$p" | grep -q . || { journalctl -u anytls-tunnel -n 80 --no-pager >&2 || true; die "Mihomo listener $p missing after restart"; }
done

select_group(){
  local group=$1 target=$2 code
  code=$(curl -sS -o "$T/select-${group}.out" -w '%{http_code}' "${AUTH[@]}" \
    -H 'Content-Type: application/json' -X PUT "$API/proxies/$group" \
    -d "{\\\"name\\\":\\\"$target\\\"}" || true)
  [[ "$code" == 204 ]] || { cat "$T/select-${group}.out" >&2 2>/dev/null || true; die "selector $group -> $target failed HTTP=$code"; }
}
log "Initializing LEGACY and all 10 bucket selectors explicitly"
select_group LEGACY F1
for b in $(seq 1 10); do
  group=$(printf 'BUCKET-%02d' "$b")
  node=$(( (b-1)/2 + 1 ))
  select_group "$group" "F$node"
done
'''
if old not in s:
    raise SystemExit("ERROR: old Mihomo activation block not found; refusing unsafe patch")
s = s.replace(old, new, 1)

p.write_text(s)
