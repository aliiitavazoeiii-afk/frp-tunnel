#!/usr/bin/env bash
set -Eeuo pipefail

D=/etc/dual-trust-mieru/iran
STATE=/var/lib/dual-trust-mieru/autoheal
LOCK=/run/dual-trust-mieru-autoheal.lock
LOG_TAG=dual-autoheal
THRESHOLD=${AUTOHEAL_THRESHOLD:-2}

mkdir -p "$STATE"
chmod 0700 "$STATE"

exec 9>"$LOCK"
flock -n 9 || exit 0

log(){ logger -t "$LOG_TAG" -- "$*"; printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

probe_http(){
  local port=$1
  local code

  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" \
    --connect-timeout 4 --max-time 7 -o /dev/null -w '%{http_code}' \
    https://www.gstatic.com/generate_204 2>/dev/null || true)
  [[ "$code" == 204 ]] && return 0

  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" \
    --connect-timeout 4 --max-time 7 -o /dev/null -w '%{http_code}' \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  [[ "$code" == 200 ]] && return 0

  return 1
}

get_count(){
  local f=$1 n=0
  [[ -s "$f" ]] && read -r n < "$f" || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

set_count(){ printf '%s\n' "$2" > "$1"; }

heal_carrier(){
  local name=$1 port=$2 svc=$3
  local f="$STATE/${name}.failcount" n

  if probe_http "$port"; then
    set_count "$f" 0
    return 0
  fi

  n=$(get_count "$f")
  n=$((n+1))
  set_count "$f" "$n"
  log "$name direct carrier unhealthy cycle=$n/$THRESHOLD"

  (( n >= THRESHOLD )) || return 1

  log "$name restarting only $svc"
  systemctl restart "$svc"
  sleep 3

  if probe_http "$port"; then
    set_count "$f" 0
    log "$name recovered after selective carrier restart"
    return 0
  fi

  set_count "$f" 1
  log "$name still unhealthy after carrier restart"
  return 1
}

TRUST_DIRECT=0
MIERU_DIRECT=0
heal_carrier trust 7993 dual-trust-client.service && TRUST_DIRECT=1 || true
heal_carrier mieru 7994 dual-mieru-carrier.service && MIERU_DIRECT=1 || true

# Only consider the shared split/XUDP router when BOTH underlying carriers are healthy.
# This avoids masking a carrier fault by bouncing the shared bridge.
if (( TRUST_DIRECT == 1 && MIERU_DIRECT == 1 )); then
  path_bad=0
  probe_http 7991 || path_bad=$((path_bad+1))
  probe_http 7992 || path_bad=$((path_bad+1))

  BF="$STATE/bridge.failcount"
  if (( path_bad == 0 )); then
    set_count "$BF" 0
  else
    n=$(get_count "$BF")
    n=$((n+1))
    set_count "$BF" "$n"
    log "split router path health degraded paths=$path_bad cycle=$n/$THRESHOLD"

    if (( n >= THRESHOLD )); then
      log "restarting shared dual-xudp-bridge after repeated path-only failures"
      systemctl restart dual-xudp-bridge.service
      sleep 2
      if probe_http 7991 && probe_http 7992; then
        set_count "$BF" 0
        log "split router recovered after bridge restart"
      else
        set_count "$BF" 1
        log "split router still degraded after bridge restart"
      fi
    fi
  fi
fi

exit 0
