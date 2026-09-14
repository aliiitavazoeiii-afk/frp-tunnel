#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$BASE_DIR/install.sh"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root: sudo bash setup.sh"
[[ -x "$INSTALLER" || -f "$INSTALLER" ]] || die "install.sh not found beside setup.sh"
command -v openssl >/dev/null 2>&1 || {
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y openssl;
  elif command -v dnf >/dev/null 2>&1; then dnf install -y openssl;
  elif command -v yum >/dev/null 2>&1; then yum install -y openssl;
  else die "openssl is required"; fi
}

rand_secret(){ openssl rand -hex 32; }
valid_host(){ [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" != *:* && "$1" == *.* ]]; }
valid_addr(){ [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_uuid(){ [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-8][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; }
valid_short_id(){ [[ "$1" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]]; }
valid_reality_key(){ [[ "$1" =~ ^[A-Za-z0-9_-]{40,64}$ ]]; }

prompt_nonempty(){
  local var=$1 label=$2 val
  while :; do
    read -r -p "$label: " val
    [[ -n "$val" ]] && break
    echo "Value cannot be empty."
  done
  printf -v "$var" '%s' "$val"
}

prompt_host(){
  local var=$1 label=$2 val
  while :; do
    read -r -p "$label: " val
    if valid_host "$val"; then break; fi
    echo "Invalid hostname. Example: www.cloudflare.com"
  done
  printf -v "$var" '%s' "$val"
}

prompt_addr(){
  local var=$1 label=$2 val
  while :; do
    read -r -p "$label: " val
    if valid_addr "$val"; then break; fi
    echo "Invalid address. Use a fixed IPv4/IPv6 or hostname."
  done
  printf -v "$var" '%s' "$val"
}

prompt_port(){
  local var=$1 label=$2 default=$3 val
  while :; do
    read -r -p "$label [$default]: " val
    val=${val:-$default}
    if valid_port "$val"; then break; fi
    echo "Invalid TCP port."
  done
  printf -v "$var" '%s' "$val"
}

prompt_secret_or_generate(){
  local var=$1 label=$2 val
  read -r -s -p "$label (Enter = generate automatically): " val
  echo
  if [[ -z "$val" ]]; then val=$(rand_secret); fi
  [[ ${#val} -ge 24 ]] || die "$label must be at least 24 characters"
  printf -v "$var" '%s' "$val"
}

prompt_required_secret(){
  local var=$1 label=$2 val
  while :; do
    read -r -s -p "$label: " val
    echo
    [[ ${#val} -ge 24 ]] && break
    echo "Secret must be at least 24 characters."
  done
  printf -v "$var" '%s' "$val"
}

prompt_uuid(){
  local var=$1 label=$2 val
  while :; do
    read -r -p "$label: " val
    valid_uuid "$val" && break
    echo "Invalid UUID."
  done
  printf -v "$var" '%s' "$val"
}

prompt_short_id(){
  local var=$1 label=$2 val
  while :; do
    read -r -p "$label: " val
    valid_short_id "$val" && break
    echo "Short ID must be 2-16 hex characters with even length (example: ab)."
  done
  printf -v "$var" '%s' "$val"
}

prompt_reality_key(){
  local var=$1 label=$2 val
  while :; do
    read -r -s -p "$label: " val
    echo
    valid_reality_key "$val" && break
    echo "Reality private key format looks invalid."
  done
  printf -v "$var" '%s' "$val"
}

prompt_bool(){
  local var=$1 label=$2 default=$3 val
  read -r -p "$label [$default]: " val
  val=${val:-$default}
  case "${val,,}" in
    y|yes|true|1) printf -v "$var" '%s' true ;;
    n|no|false|0) printf -v "$var" '%s' false ;;
    *) die "answer yes or no" ;;
  esac
}

write_env(){
  local path=$1
  shift
  umask 077
  : > "$path"
  while (( $# )); do
    local key=$1 value=$2
    shift 2
    printf '%s=%q\n' "$key" "$value" >> "$path"
  done
  chmod 600 "$path"
}

cat <<'BANNER'
AnyTLS Tunnel interactive setup v1.2.0

Roles:
  1) foreign-a  = AnyTLS + ShadowTLS v3
  2) foreign-b  = AnyTLS + ResTLS
  3) iran       = VLESS/REALITY ingress + load-balancer / failover gateway
BANNER

ROLE=${1:-}
if [[ -z "$ROLE" ]]; then
  read -r -p "Select role [1/2/3]: " choice
  case "$choice" in
    1) ROLE=foreign-a ;;
    2) ROLE=foreign-b ;;
    3) ROLE=iran ;;
    *) die "invalid role selection" ;;
  esac
fi

case "$ROLE" in
  foreign-a)
    prompt_host COVER_HOST_A "TLS 1.3 cover hostname for Foreign A"
    prompt_secret_or_generate ANYTLS_PASS_A "AnyTLS password A"
    prompt_secret_or_generate SHADOWTLS_PASS_A "ShadowTLS password A"
    ENV_FILE=/root/anytls-foreign-a.env
    write_env "$ENV_FILE" \
      COVER_HOST_A "$COVER_HOST_A" \
      ANYTLS_PASS_A "$ANYTLS_PASS_A" \
      SHADOWTLS_PASS_A "$SHADOWTLS_PASS_A"
    bash "$INSTALLER" foreign-a "$ENV_FILE"
    cat <<EOF2

=== SAVE THESE VALUES FOR THE IRAN SERVER ===
COVER_HOST_A=$COVER_HOST_A
ANYTLS_PASS_A=$ANYTLS_PASS_A
SHADOWTLS_PASS_A=$SHADOWTLS_PASS_A
=============================================
Secrets are also stored locally at: $ENV_FILE (mode 600)
EOF2
    ;;

  foreign-b)
    prompt_host COVER_HOST_B "TLS 1.3 cover hostname for Foreign B"
    prompt_secret_or_generate ANYTLS_PASS_B "AnyTLS password B"
    prompt_secret_or_generate RESTLS_PASS_B "ResTLS password B"
    ENV_FILE=/root/anytls-foreign-b.env
    write_env "$ENV_FILE" \
      COVER_HOST_B "$COVER_HOST_B" \
      ANYTLS_PASS_B "$ANYTLS_PASS_B" \
      RESTLS_PASS_B "$RESTLS_PASS_B"
    bash "$INSTALLER" foreign-b "$ENV_FILE"
    cat <<EOF2

=== SAVE THESE VALUES FOR THE IRAN SERVER ===
COVER_HOST_B=$COVER_HOST_B
ANYTLS_PASS_B=$ANYTLS_PASS_B
RESTLS_PASS_B=$RESTLS_PASS_B
=============================================
Secrets are also stored locally at: $ENV_FILE (mode 600)
EOF2
    ;;

  iran)
    prompt_addr NODE_A_ADDR "Foreign A public IP/hostname"
    prompt_addr NODE_B_ADDR "Foreign B public IP/hostname"
    prompt_host COVER_HOST_A "Foreign A cover hostname"
    prompt_host COVER_HOST_B "Foreign B cover hostname"
    prompt_required_secret ANYTLS_PASS_A "Paste ANYTLS_PASS_A"
    prompt_required_secret SHADOWTLS_PASS_A "Paste SHADOWTLS_PASS_A"
    prompt_required_secret ANYTLS_PASS_B "Paste ANYTLS_PASS_B"
    prompt_required_secret RESTLS_PASS_B "Paste RESTLS_PASS_B"
    echo
    echo "=== USER VLESS/REALITY INGRESS ==="
    prompt_uuid VLESS_UUID "Existing VLESS UUID"
    prompt_reality_key REALITY_PRIVATE_KEY "Existing REALITY private key (must match users' pbk)"
    prompt_host VLESS_REALITY_SNI "Existing REALITY SNI/server name (example: swscan.apple.com)"
    prompt_short_id REALITY_SHORT_ID "Existing REALITY short-id (example: ab)"
    prompt_port USER_LISTEN_PORT "Public VLESS/REALITY listen port" 443
    prompt_bool QUIC_SAFE_MODE "Enable QUIC-safe mode (reject proxied UDP/443 so browsers/YouTube fall back to TCP)" yes
    prompt_port LOCAL_MIXED_PORT "Local mixed proxy port" 7890
    prompt_port LOCAL_CONTROLLER_PORT "Local controller port" 9090
    CONTROLLER_SECRET=$(rand_secret)
    ENV_FILE=/root/anytls-iran.env
    write_env "$ENV_FILE" \
      NODE_A_ADDR "$NODE_A_ADDR" \
      NODE_B_ADDR "$NODE_B_ADDR" \
      COVER_HOST_A "$COVER_HOST_A" \
      COVER_HOST_B "$COVER_HOST_B" \
      ANYTLS_PASS_A "$ANYTLS_PASS_A" \
      SHADOWTLS_PASS_A "$SHADOWTLS_PASS_A" \
      ANYTLS_PASS_B "$ANYTLS_PASS_B" \
      RESTLS_PASS_B "$RESTLS_PASS_B" \
      VLESS_UUID "$VLESS_UUID" \
      REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY" \
      VLESS_REALITY_SNI "$VLESS_REALITY_SNI" \
      REALITY_SHORT_ID "$REALITY_SHORT_ID" \
      USER_LISTEN_PORT "$USER_LISTEN_PORT" \
      QUIC_SAFE_MODE "$QUIC_SAFE_MODE" \
      CONTROLLER_SECRET "$CONTROLLER_SECRET" \
      LOCAL_MIXED_PORT "$LOCAL_MIXED_PORT" \
      LOCAL_CONTROLLER_PORT "$LOCAL_CONTROLLER_PORT"
    bash "$INSTALLER" iran "$ENV_FILE"
    cat <<EOF2

Iran role installed.
User ingress:     0.0.0.0:$USER_LISTEN_PORT (VLESS/REALITY TCP)
Local proxy:      127.0.0.1:$LOCAL_MIXED_PORT
QUIC safe mode:   $QUIC_SAFE_MODE
Local controller: 127.0.0.1:$LOCAL_CONTROLLER_PORT
Config/secrets:   $ENV_FILE (mode 600)

Run now:
  sudo anytls-tunnel-status
  sudo anytls-tunnel-health
  sudo anytls-tunnel-probe-test
EOF2
    ;;
  *) die "invalid role: $ROLE (use foreign-a, foreign-b, or iran)" ;;
esac
