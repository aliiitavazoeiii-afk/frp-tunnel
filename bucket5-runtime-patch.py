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

# Before any production change, prove that the new XUDP listener range is free
# and that the complete Xray candidate can actually START and bind sockets.
# The existing production bridge owns 7891, so the isolated preflight rewrites
# only that legacy inbound to a temporary free loopback port.
validation_marker='''"$X" run -test -c "$T/rendered/xudp-bridge.json" >/dev/null || die "candidate XUDP config invalid"\n'''
preflight='''"$X" run -test -c "$T/rendered/xudp-bridge.json" >/dev/null || die "candidate XUDP config invalid"

log "Preflight: verifying dedicated XUDP bucket ports 18101..18110 are free"
for p in $(seq 18101 18110); do
  if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
    ss -ltnp "sport = :$p" >&2 || true
    die "XUDP bucket port $p is already in use; production untouched"
  fi
done

log "Preflight: actually starting XUDP candidate on isolated legacy port"
PRELEG=$(python3 - <<'PYPORT'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PYPORT
)
python3 - "$T/rendered/xudp-bridge.json" "$T/rendered/xudp-preflight.json" "$PRELEG" <<'PYCFG'
import json,sys
src,dst,port=sys.argv[1],sys.argv[2],int(sys.argv[3])
cfg=json.load(open(src))
found=False
for inbound in cfg.get('inbounds',[]):
    if int(inbound.get('port',0))==7891:
        inbound['port']=port; found=True
if not found: raise SystemExit('legacy 7891 inbound not found')
json.dump(cfg,open(dst,'w'),separators=(',',':'))
PYCFG
"$X" run -test -c "$T/rendered/xudp-preflight.json" >/dev/null || die "isolated XUDP preflight config invalid"
"$X" run -c "$T/rendered/xudp-preflight.json" >"$T/xudp-preflight.log" 2>&1 &
XPREF=$!
sleep 2
if ! kill -0 "$XPREF" 2>/dev/null; then
  cat "$T/xudp-preflight.log" >&2 || true
  wait "$XPREF" 2>/dev/null || true
  die "XUDP candidate cannot start; production untouched"
fi
for p in "$PRELEG" $(seq 18101 18110); do
  if ! ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
    cat "$T/xudp-preflight.log" >&2 || true
    kill "$XPREF" 2>/dev/null || true; wait "$XPREF" 2>/dev/null || true
    die "XUDP candidate failed to bind preflight port $p; production untouched"
  fi
done
kill "$XPREF" 2>/dev/null || true
wait "$XPREF" 2>/dev/null || true
log "Preflight XUDP candidate START = OK"
'''
if validation_marker not in s:
    raise SystemExit("ERROR: XUDP validation marker not found")
s=s.replace(validation_marker,preflight,1)

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

old_xudp='''log "Installing multi-bucket XUDP bridge (one controlled bridge restart)"
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
'''
new_xudp='''log "Installing multi-bucket XUDP bridge (one controlled bridge restart)"
cp "$T/rendered/xudp-bridge.json" "$XCFG"; chmod 0600 "$XCFG"
if ! systemctl restart anytls-xudp-bridge; then
  journalctl -u anytls-xudp-bridge -n 120 --no-pager >&2 || true
  die "XUDP bridge restart command failed"
fi
sleep 2
if ! systemctl is-active --quiet anytls-xudp-bridge; then
  journalctl -u anytls-xudp-bridge -n 120 --no-pager >&2 || true
  die "XUDP bridge failed after restart"
fi
for p in 7891 $(seq 18101 18110); do
  if ! ss -H -ltn "sport = :$p" | grep -q .; then
    journalctl -u anytls-xudp-bridge -n 120 --no-pager >&2 || true
    ss -ltnp >&2 || true
    die "XUDP listener $p missing after restart"
  fi
done

log "Smoke-testing all 10 bucket paths before routing users"
for p in $(seq 18101 18110); do
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$p" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  [[ "$code" == 204 ]] || die "bucket path port $p failed HTTP=$code"
done
'''
if old_xudp not in s:
    raise SystemExit("ERROR: old XUDP activation block not found; refusing unsafe patch")
s=s.replace(old_xudp,new_xudp,1)

p.write_text(s)
