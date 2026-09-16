#!/usr/bin/env bash
set -Eeuo pipefail

P=anytls-tunnel
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
C=/etc/$P
M=/usr/local/bin/mihomo-$P
NODE=${1:-}

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
pick_port(){ python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$NODE" =~ ^F[1-5]$ ]] || die "usage: sudo bash bucket5-diagnose-node.sh F1|F2|F3|F4|F5"
[[ -x "$M" ]] || die "missing Mihomo"
[[ -f "$B/bucket5-probe.sh" ]] || die "bucket5-probe.sh missing"

case "$NODE" in
  F1|F3|F5) DEF_COVER=www.cloudflare.com ;;
  F2|F4) DEF_COVER=www.microsoft.com ;;
esac
case "$NODE" in
  F1|F2|F3) TYPE=shadow; LAYER_LABEL=ShadowTLS ;;
  F4|F5) TYPE=restls; LAYER_LABEL=ResTLS ;;
esac

echo "=== $NODE diagnostic ($TYPE) ==="
read -r -p "$NODE public IP/hostname: " ADDR
read -r -p "$NODE cover [$DEF_COVER]: " COVER
COVER=${COVER:-$DEF_COVER}
read -r -s -p "$NODE AnyTLS password: " PASS; echo
read -r -s -p "$NODE $LAYER_LABEL password: " LAYER; echo
[[ -n "$ADDR" && ${#PASS} -ge 24 && ${#LAYER} -ge 24 ]] || die "invalid/missing input"

TMP=$(mktemp -d /tmp/anytls-bucket5-diagnose.XXXXXX)
MPID=""
cleanup(){
  set +e
  [[ -n "$MPID" ]] && kill "$MPID" 2>/dev/null || true
  [[ -n "$MPID" ]] && wait "$MPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
MPORT=$(pick_port)

log "$NODE stage 1/3: raw TCP/443"
timeout 6 bash -c "exec 3<>/dev/tcp/${ADDR}/443" 2>/dev/null || die "$NODE TCP/443 unreachable"
log "$NODE raw TCP/443 = OK"

cat >"$TMP/mihomo.yaml" <<EOF
mode: rule
log-level: debug
ipv6: false
listeners:
  - name: diagnose-socks
    type: socks
    listen: 127.0.0.1
    port: $MPORT
    udp: true
    proxy: candidate
proxies:
  - name: candidate
    type: anytls
    server: "$ADDR"
    port: 443
    password: "$PASS"
    tls: true
    sni: "$COVER"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
EOF
if [[ "$TYPE" == shadow ]]; then
cat >>"$TMP/mihomo.yaml" <<EOF
    shadow-tls-opts:
      version: 3
      password: "$LAYER"
EOF
else
cat >>"$TMP/mihomo.yaml" <<EOF
    restls-opts:
      password: "$LAYER"
      version-hint: tls13
EOF
fi
cat >>"$TMP/mihomo.yaml" <<'EOF'
rules:
  - MATCH,candidate
EOF

"$M" -t -d "$TMP" -f "$TMP/mihomo.yaml" >/dev/null || die "Mihomo candidate config invalid"
"$M" -d "$TMP" -f "$TMP/mihomo.yaml" >"$TMP/mihomo.log" 2>&1 & MPID=$!
for _ in $(seq 1 40); do ss -H -ltn "sport = :$MPORT" 2>/dev/null | grep -q . && break; sleep 0.2; done
ss -H -ltn "sport = :$MPORT" | grep -q . || { cat "$TMP/mihomo.log" >&2; die "diagnostic Mihomo failed to listen"; }

log "$NODE stage 2/3: direct AnyTLS/$LAYER_LABEL carrier (NO XUDP)"
DIRECT_OK=0
for try in 1 2 3; do
  code=$(curl -4 -sS -L --socks5-hostname "127.0.0.1:$MPORT" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  if [[ "$code" == 204 ]]; then DIRECT_OK=1; break; fi
  log "$NODE direct carrier attempt $try failed HTTP=${code:-000}"
  sleep 1
done
if (( DIRECT_OK == 0 )); then
  echo "----- Mihomo diagnostic log (tail) -----" >&2
  tail -n 120 "$TMP/mihomo.log" >&2 || true
  echo "----------------------------------------" >&2
  die "$NODE DIRECT CARRIER FAILED before XUDP"
fi
log "$NODE DIRECT CARRIER = OK (HTTP=204)"

kill "$MPID" 2>/dev/null || true
wait "$MPID" 2>/dev/null || true
MPID=""

E="$TMP/node.env"
{
  printf '%s_ADDR=%q\n' "$NODE" "$ADDR"
  printf '%s_TYPE=%q\n' "$NODE" "$TYPE"
  printf '%s_COVER=%q\n' "$NODE" "$COVER"
  printf '%s_ANYTLS=%q\n' "$NODE" "$PASS"
  printf '%s_LAYER=%q\n' "$NODE" "$LAYER"
} >"$E"
chmod 0600 "$E"

log "$NODE stage 3/3: full XUDP path"
if BUCKET5_ENV="$E" bash "$B/bucket5-probe.sh" "$NODE"; then
  log "DIAGNOSIS: $NODE carrier=PASS xudp=PASS"
else
  rc=$?
  echo "DIAGNOSIS: $NODE carrier=PASS xudp=FAIL (rc=$rc)" >&2
  exit "$rc"
fi
