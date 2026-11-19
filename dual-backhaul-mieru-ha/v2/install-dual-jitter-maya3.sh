#!/usr/bin/env bash
# Install ONLY the read-only jitter diagnostic and its menu entry.
# NO systemd restarts, NO modifications to tunnel configs, anti-DPI or HAProxy.
set -Eeuo pipefail
umask 077
[[ "$EUID" == 0 ]] || { echo "Root required" >&2; exit 2; }
[[ $# == 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || {
 echo "Usage: sudo bash install-dual-jitter-maya3.sh PINNED_COMMIT_SHA" >&2; exit 2;
}
REF="$1"
H=/opt/dual-ha/helper
B="/root/dual-backhaul-backups/jitter-menu-$(date -u +%Y%m%dT%H%M%SZ)"
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
[[ "$(readlink -f /usr/local/bin/dual)" == "$H/dual_backhaul_menu.py" ]] || {
 echo "STOP: current sudo dual helper is not the verified dual-backhaul helper" >&2; exit 3;
}
[[ -r /etc/dual-ha/bh2-experiment/state.json ]] || { echo "STOP: Maya3 expected" >&2; exit 3; }
python3 - <<'PY'
import json
m=json.load(open("/etc/dual-ha/bh2-experiment/state.json"))
assert m.get("mode")=="active" and m.get("foreign_ip")=="82.152.132.112"
b=open("/etc/dual-ha/backhaul-bundle.env").read()
assert "BH_IRAN_IP='185.215.230.221'" in b
PY
for p in 21001 21002; do
  [[ -n "$(ss -Hlnpt "( sport = :$p )")" ]] || {
    echo "STOP: missing existing SOCKS $p" >&2; exit 3;
  }
done
T="$(mktemp -d /root/.dual-jitter.XXXXXXXX)"
trap 'rm -rf "$T"' EXIT
curl -fsSLo "$T/dual_backhaul_menu.py" "$BASE/dual_backhaul_menu.py"
curl -fsSLo "$T/dual-backhaul-jitter-audit.py" "$BASE/dual-backhaul-jitter-audit.py"
python3 -m py_compile "$T/dual_backhaul_menu.py" "$T/dual-backhaul-jitter-audit.py"
python3 "$T/dual-backhaul-jitter-audit.py" --verify | grep -Fxq READ_ONLY_AUDIT_READY
[[ "$(grep -c '^def jitter(' "$T/dual_backhaul_menu.py")" == 1 ]] || {
 echo "STOP: new menu has no unique jitter entry" >&2; exit 3;
}
mkdir -p -m 0700 "$B"
cp -a "$H/dual_backhaul_menu.py" "$B/dual_backhaul_menu.py"
if [[ -f "$H/dual-backhaul-jitter-audit.py" ]]; then
  cp -a "$H/dual-backhaul-jitter-audit.py" "$B/dual-backhaul-jitter-audit.py"
fi
cat > "$B/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || exit 2
install -m 0700 "$B/dual_backhaul_menu.py" "$H/dual_backhaul_menu.py"
if [[ -f "$B/dual-backhaul-jitter-audit.py" ]]; then
  install -m 0700 "$B/dual-backhaul-jitter-audit.py" "$H/dual-backhaul-jitter-audit.py"
else
  rm -f "$H/dual-backhaul-jitter-audit.py"
fi
echo "Previous sudo dual menu restored; no services restarted."
EOF
chmod 0700 "$B/rollback.sh"
install -m 0700 "$T/dual-backhaul-jitter-audit.py" "$H/dual-backhaul-jitter-audit.py"
install -m 0700 "$T/dual_backhaul_menu.py" "$H/dual_backhaul_menu.py"
if ! /usr/local/bin/dual status >/dev/null; then
  bash "$B/rollback.sh"
  echo "STOP: new menu self-check failed; old menu restored" >&2
  exit 4
fi
echo "JITTER AUDIT ADDED to sudo dual (option 7)."
echo "No HAProxy, Backhaul, Xray, TLS or health controller restarted."
echo "Rollback: sudo bash $B/rollback.sh"
echo "Run: sudo dual jitter 24"
