#!/usr/bin/env bash
# One-command fresh FOREIGN node installer; NEVER install over an existing VPN host.
# curl -fsSLo /tmp/dual-foreign.sh https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/dual-backhaul-mieru-ha/dual-backhaul-mieru-ha/v2/foreign-install.sh
# sudo bash /tmp/dual-foreign.sh --role mieru --iran-ip 94.184.4.38 --foreign-ip A.B.C.D
# sudo bash /tmp/dual-foreign.sh --role backhaul --iran-ip 94.184.4.38 --foreign-ip A.B.C.D --bundle /root/dual-ha-backhaul-bundle.env [--prepare]
set -Eeuo pipefail
ROLE='' IRAN_IP='' FOREIGN_IP='' BUNDLE='' PREPARE=0
usage() {
 cat <<'HELP'
Usage:
  sudo bash foreign-install.sh --role mieru --iran-ip 94.184.4.38 --foreign-ip NEW.IP.V4.HERE
  sudo bash foreign-install.sh --role backhaul --iran-ip 94.184.4.38 --foreign-ip NEW.IP.V4.HERE --bundle /root/dual-ha-backhaul-bundle.env [--prepare]

Backhaul requires a private bundle copied from IRAN via SSH/SCP.
With --prepare, Backhaul starts Dante but does NOT connect reverse client
to Iran. This prevents a second foreign client hijacking an active relay.
Never paste secret bundle contents into the console or chat.
HELP
}
valid_ip() {
 python3 - "$1" <<'PY'
import ipaddress,sys
try:
 ip=ipaddress.ip_address(sys.argv[1])
 if ip.version != 4 or not ip.is_global: raise ValueError("global IPv4 required")
except ValueError: sys.exit(1)
PY
}
while (( $# )); do
 case "$1" in
  --role) ROLE="$2"; shift 2 ;;
  --iran-ip) IRAN_IP="$2"; shift 2 ;;
  --foreign-ip) FOREIGN_IP="$2"; shift 2 ;;
  --bundle) BUNDLE="$2"; shift 2 ;;
  --prepare) PREPARE=1; shift ;;
  --help|-h) usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
 esac
done
[[ "$EUID" == 0 ]] || { echo "Run as root" >&2; exit 2; }
[[ "$(uname -m)" == x86_64 ]] || { echo "Linux amd64 required" >&2; exit 2; }
[[ "$ROLE" == mieru || "$ROLE" == backhaul ]] || { usage; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
valid_ip "$IRAN_IP" || { echo "Bad Iran public IPv4"; exit 2; }
valid_ip "$FOREIGN_IP" || { echo "Bad foreign public IPv4"; exit 2; }
[[ "$FOREIGN_IP" != "$IRAN_IP" ]] || { echo "Iran and foreign IPs cannot match"; exit 2; }
if [[ "$ROLE" == backhaul ]]; then
 [[ -r "$BUNDLE" ]] || { echo "Backhaul secret bundle missing. Copy from Iran via SCP first." >&2; exit 2; }
 grep -Fxq "BH_FOREIGN_IP='$FOREIGN_IP'" "$BUNDLE" || { echo "Bundle does not match chosen foreign IP"; exit 2; }
else
 [[ -z "$BUNDLE" ]] || { echo "Mieru does not accept a Backhaul bundle"; exit 2; }
 [[ "$PREPARE" == 0 ]] || { echo "--prepare is only needed for Backhaul"; exit 2; }
fi
# Never change a live service on an existing foreign machine.
for unit in dual-ha-mita dual-ha-backhaul-client; do
 if systemctl is-active --quiet "$unit" 2>/dev/null; then
  echo "Active dual HA foreign service $unit already exists: refusing installer." >&2
  exit 3
 fi
done
for file in /etc/dual-ha/mita.json /etc/dual-ha/backhaul-foreign.toml; do
 [[ ! -e "$file" ]] || { echo "Existing dual HA config found: $file; refusing overwrite." >&2; exit 3; }
done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl ca-certificates python3
SRC=/opt/dual-ha-src/frp-tunnel
if [[ -d "$SRC" ]]; then
 echo "Existing installer source directory $SRC: refusing unverified reuse." >&2; exit 3
fi
mkdir -p /opt/dual-ha-src
git clone --depth 1 --single-branch --branch dual-backhaul-mieru-ha \
 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git "$SRC"
DIR="$SRC/dual-backhaul-mieru-ha/v2"
if [[ "$ROLE" == mieru ]]; then
 bash "$DIR/foreign-mieru.sh" "$IRAN_IP" "$FOREIGN_IP"
 systemctl is-active --quiet dual-ha-mita
 ss -Hlnpt '( sport = :28443 )' | grep -q LISTEN
 echo "[+] Fresh foreign Mita ready at $FOREIGN_IP:28443"
 echo "[+] Bundle stored in /etc/dual-ha/mieru-bundle.env; transfer via secure SCP only."
else
 bash "$DIR/install-prebuilt-backhaul.sh" dual-backhaul-v2-build-368d09411985
 if (( PREPARE )); then
  bash "$DIR/foreign-backhaul.sh" "$BUNDLE" prepare
 else
  bash "$DIR/foreign-backhaul.sh" "$BUNDLE" install
 fi
 systemctl is-active --quiet danted
 echo "[+] Foreign Backhaul installed on $FOREIGN_IP."
 if (( PREPARE )); then
   echo "[+] Backhaul reverse client PREPARED but NOT started (safe while old relay is live)."
 else
   echo "[+] Backhaul reverse client started."
 fi
fi
echo "[+] No changes to existing Iran x-ui / REALITY / Xray settings."
