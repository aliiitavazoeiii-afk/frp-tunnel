#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root

D="$CONFIG_DIR/iran"
BUNDLE="$D/mieru-bundle.json"
SERVICE=/etc/systemd/system/dual-mieru-carrier.service
CAND_PORT=17994
RPC_PORT=17995
CAND="$D/mieru-official-candidate.json"
FINAL="$D/mieru-official.json"
CAND_LOG="$D/mieru-official-candidate.log"
BK="$STATE_DIR/backups/mieru-carrier-$(date -u +%Y%m%dT%H%M%SZ)"
CAND_PID=""
SWAPPED=0

[[ -s "$BUNDLE" && -s "$SERVICE" ]] || die "existing Iran dual Mieru carrier state not found"
systemctl is-active --quiet dual-xudp-bridge.service || die "dual-xudp-bridge inactive"
systemctl is-active --quiet dual-mieru-carrier.service || die "dual-mieru-carrier inactive"
free_port "$CAND_PORT"
free_port "$RPC_PORT"

mkdir -p "$BK" "$D/mieru-official-cache" "$D/mieru-official-candidate-cache"
chmod 0700 "$BK" "$D/mieru-official-cache" "$D/mieru-official-candidate-cache"
cp -a "$SERVICE" "$BK/dual-mieru-carrier.service"
[[ -f "$D/mieru-carrier.yaml" ]] && cp -a "$D/mieru-carrier.yaml" "$BK/mieru-carrier.yaml"

cleanup(){
  rc=$?
  trap - EXIT
  if [[ -n "$CAND_PID" ]]; then
    kill "$CAND_PID" >/dev/null 2>&1 || true
    wait "$CAND_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$CAND" "$CAND_LOG"
  if (( rc != 0 && SWAPPED == 1 )); then
    log "ROLLBACK: restoring previous Mihomo Mieru carrier service"
    systemctl stop dual-mieru-carrier.service >/dev/null 2>&1 || true
    cp -a "$BK/dual-mieru-carrier.service" "$SERVICE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl start dual-mieru-carrier.service >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

log "Installing pinned official Mieru client ${MIERU_VERSION} alongside current carrier"
install_base_packages
install_mieru_deb client
MIERU_BIN=$(command -v mieru)
[[ -x "$MIERU_BIN" ]] || die "official mieru binary missing"
# The package should not own the project's carrier lifecycle.
systemctl disable --now mieru.service >/dev/null 2>&1 || true

MIERU_IP=$(jq -r '.public_ip' "$BUNDLE")
MIERU_RANGE=$(jq -r '.port_range' "$BUNDLE")
MIERU_USER=$(jq -r '.username' "$BUNDLE")
MIERU_PASS=$(jq -r '.password' "$BUNDLE")

write_cfg(){
  local out=$1 socks=$2 rpc=$3
  export MIERU_IP MIERU_RANGE MIERU_USER MIERU_PASS socks rpc out
  python3 <<'PY'
import json, os
obj={
  "profiles":[{
    "profileName":"dual",
    "user":{"name":os.environ["MIERU_USER"],"password":os.environ["MIERU_PASS"]},
    "servers":[{"ipAddress":os.environ["MIERU_IP"],"domainName":"","portBindings":[{"portRange":os.environ["MIERU_RANGE"],"protocol":"TCP"}]}],
    "mtu":1400,
    "multiplexing":{"level":"MULTIPLEXING_LOW"},
    "handshakeMode":"HANDSHAKE_STANDARD"
  }],
  "activeProfile":"dual",
  "rpcPort":int(os.environ["rpc"]),
  "socks5Port":int(os.environ["socks"]),
  "loggingLevel":"INFO",
  "socks5ListenLAN":False
}
with open(os.environ["out"],"w") as f:
    json.dump(obj,f,indent=2,sort_keys=True)
os.chmod(os.environ["out"],0o600)
PY
}

log "Candidate: official Mieru on isolated SOCKS/$CAND_PORT; existing carrier remains live"
write_cfg "$CAND" "$CAND_PORT" "$RPC_PORT"
MIERU_CONFIG_JSON_FILE="$CAND" XDG_CACHE_HOME="$D/mieru-official-candidate-cache" \
  "$MIERU_BIN" run >"$CAND_LOG" 2>&1 & CAND_PID=$!
for _ in $(seq 1 80); do
  ss -H -ltn "sport = :$CAND_PORT" 2>/dev/null | grep -q . && break
  kill -0 "$CAND_PID" 2>/dev/null || { tail -n 120 "$CAND_LOG" >&2 || true; die "official Mieru candidate exited"; }
  sleep 0.25
done
ss -H -ltn "sport = :$CAND_PORT" 2>/dev/null | grep -q . || { tail -n 120 "$CAND_LOG" >&2 || true; die "official Mieru candidate SOCKS did not start"; }

for attempt in 1 2 3; do
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$CAND_PORT" --connect-timeout 8 --max-time 20 \
    -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  [[ "$code" == 204 ]] || { tail -n 120 "$CAND_LOG" >&2 || true; die "official Mieru candidate failed attempt $attempt/3 HTTP=${code:-000}; refusing migration because problem is not proven to be Mihomo carrier"; }
  log "Candidate direct carrier attempt $attempt/3 = OK"
done

kill "$CAND_PID" >/dev/null 2>&1 || true
wait "$CAND_PID" >/dev/null 2>&1 || true
CAND_PID=""
rm -f "$CAND_LOG"

log "Candidate passed. Swapping only dual-mieru-carrier to official Mieru; XUDP/dispatcher stay unchanged"
write_cfg "$FINAL" 7994 "$RPC_PORT"
cat > "$SERVICE.new" <<EOF2
[Unit]
Description=Dual tunnel official Mieru TCP carrier
After=network-online.target
Wants=network-online.target
[Service]
Type=exec
Environment="MIERU_CONFIG_JSON_FILE=$FINAL"
Environment="XDG_CACHE_HOME=$D/mieru-official-cache"
ExecStart=$MIERU_BIN run
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$D/mieru-official-cache
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

systemd-analyze verify "$SERVICE.new"
systemctl stop dual-mieru-carrier.service
install -m 0644 "$SERVICE.new" "$SERVICE"
rm -f "$SERVICE.new"
systemctl daemon-reload
SWAPPED=1
systemctl start dual-mieru-carrier.service

for _ in $(seq 1 80); do
  ss -H -ltn 'sport = :7994' 2>/dev/null | grep -q . && break
  systemctl is-active --quiet dual-mieru-carrier.service || { journalctl -u dual-mieru-carrier -n 120 --no-pager >&2 || true; die "official carrier service exited"; }
  sleep 0.25
done
ss -H -ltn 'sport = :7994' 2>/dev/null | grep -q . || die "official carrier SOCKS/7994 missing"

code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7994 --connect-timeout 8 --max-time 20 \
  -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || die "official direct carrier post-swap failed HTTP=${code:-000}"
log "Official direct carrier 7994 = OK"

# Xray bridge is unchanged and should transparently consume the new SOCKS carrier.
for attempt in 1 2 3; do
  code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7992 --connect-timeout 8 --max-time 20 \
    -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  [[ "$code" == 204 ]] && break
  sleep "$attempt"
done
[[ "$code" == 204 ]] || die "Mieru XUDP path 7992 failed after official carrier swap HTTP=${code:-000}"
log "Mieru XUDP path 7992 = OK"

SWAPPED=0
trap - EXIT
rm -f "$CAND"
log "SUCCESS: Iran Mieru carrier migrated from Mihomo native to official Mieru ${MIERU_VERSION}"
log "Rollback backup retained at $BK"
log "The dual XUDP bridge and dispatcher were not reconfigured."
