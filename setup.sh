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
AnyTLS Tunnel interactive setup v1.1.0

Roles:
  1) foreign-a  = AnyTLS + ShadowTLS v3
  2) foreign-b  = AnyTLS + ResTLS
  3) iran       = local load-balancer / failover gateway
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
      CONTROLLER_SECRET "$CONTROLLER_SECRET" \
      LOCAL_MIXED_PORT "$LOCAL_MIXED_PORT" \
      LOCAL_CONTROLLER_PORT "$LOCAL_CONTROLLER_PORT"
    bash "$INSTALLER" iran "$ENV_FILE"
    cat <<EOF2

Iran role installed.
Local proxy:      127.0.0.1:$LOCAL_MIXED_PORT
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
