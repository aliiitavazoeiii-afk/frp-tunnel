#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
SHARED_ENV="${CONFIG_DIR}/shared-node.env"
DEPLOY_ENV="${CONFIG_DIR}/deploy.env"
STATE_DIR="/var/lib/${PROJECT}"
STATE_FILE="${STATE_DIR}/shared-node.state"
PROBE="/usr/local/sbin/anytls-shared-probe"
TZ_NAME="Asia/Tehran"
QUICK_INTERVAL="${QUICK_INTERVAL:-300}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$SHARED_ENV" ]] || die "missing $SHARED_ENV"
[[ -f "$DEPLOY_ENV" ]] || die "missing $DEPLOY_ENV"
[[ -x "$PROBE" ]] || die "missing $PROBE"
command -v jq >/dev/null 2>&1 || die "jq missing"

source "$SHARED_ENV"
source "$DEPLOY_ENV"

[[ "${SHARED_PROFILE:-}" == "maya1" || "${SHARED_PROFILE:-}" == "maya3" ]] || die "invalid SHARED_PROFILE"
[[ -n "${CONTROLLER_SECRET:-}" && -n "${LOCAL_CONTROLLER_PORT:-}" ]] || die "controller config missing"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
chmod 0600 "$STATE_FILE"

CURRENT_MODE="BASE"
BLOCKED_WINDOW=""
LAST_QUICK_PROBE=0
source "$STATE_FILE" 2>/dev/null || true
[[ "$LAST_QUICK_PROBE" =~ ^[0-9]+$ ]] || LAST_QUICK_PROBE=0

API="http://127.0.0.1:${LOCAL_CONTROLLER_PORT}"
AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")

api_get(){ curl -fsS "${AUTH[@]}" "$1"; }
api_put_json(){
  local url=$1 payload=$2 code
  code=$(curl -sS -o /tmp/anytls-shared-api.$$ -w '%{http_code}' \
    "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT -d "$payload" "$url" || true)
  rm -f /tmp/anytls-shared-api.$$
  [[ "$code" == "204" ]]
}

save_state(){
  umask 077
  cat >"${STATE_FILE}.new" <<EOF
CURRENT_MODE=$(printf %q "$CURRENT_MODE")
BLOCKED_WINDOW=$(printf %q "$BLOCKED_WINDOW")
LAST_QUICK_PROBE=$(printf %q "$LAST_QUICK_PROBE")
EOF
  mv -f "${STATE_FILE}.new" "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

selection(){ api_get "$API/proxies/TUNNEL" | jq -r '.now // empty'; }
set_group(){
  local group=$1
  [[ "$group" == "TUNNEL-BASE" || "$group" == "TUNNEL-SHARED" ]] || return 2
  api_put_json "$API/proxies/TUNNEL" "$(jq -cn --arg n "$group" '{name:$n}')" || return 1
  [[ "$(selection)" == "$group" ]]
}

quick_probe(){
  local name url expected out spec
  for spec in \
    "gstatic|https://www.gstatic.com/generate_204|204" \
    "youtube|https://www.youtube.com/|200-499" \
    "instagram|https://www.instagram.com/|200-499"
  do
    IFS='|' read -r name url expected <<<"$spec"
    out=$(curl -fsS -G "${AUTH[@]}" \
      --data-urlencode "url=$url" \
      --data-urlencode "timeout=8000" \
      --data-urlencode "expected=$expected" \
      "$API/proxies/foreign-shared-shadowtls/delay" || true)
    jq -e '.delay|numbers' >/dev/null 2>&1 <<<"$out" || {
      log "quick probe failed: $name ${out:-no-response}"
      return 1
    }
  done
}

tehran_hm=$(TZ="$TZ_NAME" date +%H%M)
tehran_date=$(TZ="$TZ_NAME" date +%Y%m%d)
active=false
window_id=""

if [[ "$SHARED_PROFILE" == "maya3" ]]; then
  if (( 10#$tehran_hm >= 1500 && 10#$tehran_hm < 2100 )); then
    active=true
    window_id="maya3-${tehran_date}-1500"
  fi
else
  if (( 10#$tehran_hm >= 2100 )); then
    active=true
    window_id="maya1-${tehran_date}-2100"
  elif (( 10#$tehran_hm < 300 )); then
    active=true
    prev=$(TZ="$TZ_NAME" date -d 'yesterday' +%Y%m%d)
    window_id="maya1-${prev}-2100"
  fi
fi

now_sel=$(selection || true)
[[ -n "$now_sel" ]] || die "could not read TUNNEL selector"

if [[ "$active" != true ]]; then
  if [[ "$now_sel" != "TUNNEL-BASE" ]]; then
    log "outside shared window; switching new connections to TUNNEL-BASE"
    set_group TUNNEL-BASE || die "failed to select TUNNEL-BASE"
  fi
  CURRENT_MODE="BASE"
  BLOCKED_WINDOW=""
  LAST_QUICK_PROBE=0
  save_state
  exit 0
fi

if [[ "$BLOCKED_WINDOW" == "$window_id" ]]; then
  if [[ "$now_sel" != "TUNNEL-BASE" ]]; then
    set_group TUNNEL-BASE || die "failed to keep BASE after F5 failure"
  fi
  CURRENT_MODE="BASE"
  save_state
  log "F5 is blocked for current window $window_id; keeping BASE"
  exit 0
fi

if [[ "$now_sel" != "TUNNEL-SHARED" ]]; then
  log "shared window $window_id starting; running isolated F5 pre-activation probe"
  if SHARED_ENV="$SHARED_ENV" "$PROBE"; then
    log "F5 passed full probe; enabling TUNNEL-SHARED for NEW connections"
    set_group TUNNEL-SHARED || die "F5 healthy but selector switch failed"
    CURRENT_MODE="SHARED"
    LAST_QUICK_PROBE=$(date +%s)
    save_state
    exit 0
  else
    log "F5 full probe failed; NOT entering pool for this window"
    set_group TUNNEL-BASE || true
    CURRENT_MODE="BASE"
    BLOCKED_WINDOW="$window_id"
    LAST_QUICK_PROBE=$(date +%s)
    save_state
    exit 0
  fi
fi

CURRENT_MODE="SHARED"
now_epoch=$(date +%s)
if (( now_epoch - LAST_QUICK_PROBE >= QUICK_INTERVAL )); then
  log "running active-window F5 quick health check"
  if quick_probe; then
    LAST_QUICK_PROBE=$now_epoch
    save_state
    log "F5 quick health = OK"
  else
    log "F5 became unhealthy; switching NEW connections to BASE and blocking F5 until next window"
    set_group TUNNEL-BASE || die "F5 unhealthy and BASE failback failed"
    CURRENT_MODE="BASE"
    BLOCKED_WINDOW="$window_id"
    LAST_QUICK_PROBE=$now_epoch
    save_state
  fi
else
  save_state
fi
