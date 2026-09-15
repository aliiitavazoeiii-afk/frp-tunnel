#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
SHARED_ENV="${CONFIG_DIR}/shared-node.env"
DEPLOY_ENV="${CONFIG_DIR}/deploy.env"
STATE_DIR="/var/lib/${PROJECT}"
STATE_FILE="${STATE_DIR}/shared-node.state"
FULL_PROBE="/usr/local/sbin/anytls-node-full-probe"
TZ_NAME="Asia/Tehran"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$SHARED_ENV" ]] || die "missing $SHARED_ENV"
[[ -f "$DEPLOY_ENV" ]] || die "missing $DEPLOY_ENV"
[[ -x "$FULL_PROBE" ]] || die "missing $FULL_PROBE"
command -v jq >/dev/null 2>&1 || die "jq missing"
# shellcheck disable=SC1090
source "$SHARED_ENV"
# shellcheck disable=SC1090
source "$DEPLOY_ENV"
[[ "${SHARED_PROFILE:-}" == "maya1" || "${SHARED_PROFILE:-}" == "maya3" ]] || die "invalid SHARED_PROFILE"
[[ -n "${CONTROLLER_SECRET:-}" && -n "${LOCAL_CONTROLLER_PORT:-}" ]] || die "controller config missing"

mkdir -p "$STATE_DIR"
API="http://127.0.0.1:${LOCAL_CONTROLLER_PORT}"
AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
A="foreign-a-shadowtls"
B="foreign-b-restls"
F="foreign-shared-shadowtls"

api_get(){ curl -fsS "${AUTH[@]}" "$1"; }
api_put_json(){
  local url=$1 payload=$2 code tmp
  tmp=$(mktemp /tmp/anytls-guard-api.XXXXXX)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -X PUT -d "$payload" "$url" || true)
  rm -f "$tmp"
  [[ "$code" == 204 ]]
}
selection(){ api_get "$API/proxies/TUNNEL" | jq -r '.now // empty'; }
set_group(){
  local g=$1
  case "$g" in TUNNEL-BASE|BASE-A|BASE-B|TUNNEL-SHARED|SHARED-AF5|SHARED-BF5|SHARED-F5|REJECT) ;; *) return 2;; esac
  api_put_json "$API/proxies/TUNNEL" "$(jq -cn --arg n "$g" '{name:$n}')" || return 1
  [[ "$(selection)" == "$g" ]]
}

group_has(){
  local g=$1 node=$2
  case "$g:$node" in
    TUNNEL-BASE:$A|TUNNEL-BASE:$B|TUNNEL-SHARED:$A|TUNNEL-SHARED:$B|TUNNEL-SHARED:$F|BASE-A:$A|BASE-B:$B|SHARED-AF5:$A|SHARED-AF5:$F|SHARED-BF5:$B|SHARED-BF5:$F|SHARED-F5:$F) return 0 ;;
    *) return 1 ;;
  esac
}

probe_once(){
  local node=$1 label=$2 url=$3 expected=$4 out
  out=$(curl -fsS -G "${AUTH[@]}" \
    --data-urlencode "url=$url" \
    --data-urlencode "timeout=8000" \
    --data-urlencode "expected=$expected" \
    "$API/proxies/$node/delay" 2>/dev/null || true)
  jq -e '.delay|numbers' >/dev/null 2>&1 <<<"$out"
}

quick_probe_node(){
  local node=$1 label url expected spec
  for spec in \
    'gstatic|https://www.gstatic.com/generate_204|204' \
    'youtube|https://www.youtube.com/|200-499' \
    'ytimg|https://i.ytimg.com/|200-499' \
    'instagram|https://www.instagram.com/|200-499'
  do
    IFS='|' read -r label url expected <<<"$spec"
    if probe_once "$node" "$label" "$url" "$expected"; then continue; fi
    sleep 1
    if ! probe_once "$node" "$label" "$url" "$expected"; then
      log "UNHEALTHY $node: $label failed twice"
      return 1
    fi
  done
  return 0
}

drain_node(){
  local node=$1 ids id n=0
  ids=$(api_get "$API/connections" | jq -r --arg n "$node" '.connections[]? | select((.chains // []) | index($n)) | .id' || true)
  [[ -n "$ids" ]] || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    curl -sS -o /dev/null "${AUTH[@]}" -X DELETE "$API/connections/$id" || true
    n=$((n+1))
  done <<<"$ids"
  log "drained $n existing connection(s) from unhealthy $node"
}

ensure_candidate(){
  local short=$1 node=$2 current=$3
  if ! quick_probe_node "$node"; then
    group_has "$current" "$node" && drain_node "$node"
    return 1
  fi
  if ! group_has "$current" "$node"; then
    log "$node quick health passed; running isolated full XUDP pre-activation probe"
    if ! "$FULL_PROBE" "$short"; then
      log "UNHEALTHY $node: full XUDP pre-activation probe failed"
      return 1
    fi
  fi
  return 0
}

tehran_hm=$(TZ="$TZ_NAME" date +%H%M)
active=false
if [[ "$SHARED_PROFILE" == maya3 ]]; then
  ((10#$tehran_hm >= 1500 && 10#$tehran_hm < 2100)) && active=true
else
  ((10#$tehran_hm >= 2100 || 10#$tehran_hm < 300)) && active=true
fi

current=$(selection || true)
[[ -n "$current" ]] || die "could not read TUNNEL selector"
ha=0; hb=0; hf=0
ensure_candidate a "$A" "$current" && ha=1 || true
ensure_candidate b "$B" "$current" && hb=1 || true
if [[ "$active" == true ]]; then ensure_candidate shared "$F" "$current" && hf=1 || true; fi

if [[ "$active" == true ]]; then
  case "$ha$hb$hf" in
    111) target=TUNNEL-SHARED ;;
    110) target=TUNNEL-BASE ;;
    101) target=SHARED-AF5 ;;
    011) target=SHARED-BF5 ;;
    100) target=BASE-A ;;
    010) target=BASE-B ;;
    001) target=SHARED-F5 ;;
    000) target=REJECT ;;
  esac
else
  case "$ha$hb" in
    11) target=TUNNEL-BASE ;;
    10) target=BASE-A ;;
    01) target=BASE-B ;;
    00) target=REJECT ;;
  esac
fi

if [[ "$current" != "$target" ]]; then
  log "health gate A=$ha B=$hb F5=$hf window=$active: $current -> $target"
  set_group "$target" || die "failed to select healthy group $target"
else
  log "health gate A=$ha B=$hb F5=$hf window=$active: keeping $target"
fi

umask 077
cat >"${STATE_FILE}.new" <<EOF
CURRENT_GROUP=$(printf %q "$target")
HEALTH_A=$ha
HEALTH_B=$hb
HEALTH_F5=$hf
SHARED_WINDOW=$active
LAST_CHECK=$(date +%s)
EOF
mv -f "${STATE_FILE}.new" "$STATE_FILE"
chmod 0600 "$STATE_FILE"
