#!/usr/bin/env bash
# Maya3 only. Remove ONLY inactive Iran Mieru client after dual-backhaul helper
# installation. Keeps secret archival rollback (does not contact foreign Mieru VPS).
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 2; }
D=/etc/dual-ha/bh2-experiment
METADATA="$D/state.json"
SRC=/etc/dual-ha/mieru.json
UNIT=/etc/systemd/system/dual-ha-mieru.service
BIN=/opt/dual-ha/bin/mieru
[[ -r "$METADATA" && -r /etc/dual-ha/backhaul-bundle.env ]] || {
  echo "STOP: Maya3 dual Backhaul not configured"; exit 3;
}
[[ "$(readlink -f /usr/local/bin/dual)" == /opt/dual-ha/helper/dual_backhaul_menu.py ]] || {
  echo "STOP: Install new two-Backhaul sudo dual helper FIRST"; exit 3;
}
python3 - "$METADATA" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
assert m.get("mode")=="active", "Backhaul2 is not active"
main={}
for row in open("/etc/dual-ha/backhaul-bundle.env"):
    if row.startswith("BH_FOREIGN_IP="):
        main_ip=row.strip().split("=",1)[1].strip("'")
        break
else:
    raise AssertionError("Missing active Backhaul1 identity")
assert m.get("primary_ip")==main_ip, "Maya3 BH1 metadata mismatch; inspect before removal"
PY
grep -Fxq "BH_IRAN_IP='185.215.230.221'" /etc/dual-ha/backhaul-bundle.env || {
  echo "STOP: not Maya3"; exit 3;
}
systemctl is-active --quiet dual-ha-backhaul || { echo "STOP: primary Backhaul down"; exit 3; }
systemctl is-active --quiet dual-ha-bh2-server || { echo "STOP: second Backhaul down"; exit 3; }
if systemctl is-active --quiet dual-ha-mieru; then
  echo "STOP: Original Mieru process is still active; refuse deletion"; exit 3;
fi
[[ -f "$SRC" && -f "$UNIT" && -f "$BIN" ]] || {
  echo "STOP: expected original Mieru files absent; not deleting unknown files"; exit 3;
}
EXPECTED="$(python3 -c 'import json;print(json.load(open("/etc/dual-ha/bh2-experiment/state.json"))["foreign_ip"])')"
EGRESS="$(curl -q -4 --noproxy "" --socks5-hostname 127.0.0.1:21002 \
    --connect-timeout 5 --max-time 12 -fsS \
    https://www.cloudflare.com/cdn-cgi/trace |
    awk -F= '$1=="ip"{print $2;exit}')"
[[ "$EGRESS" == "$EXPECTED" ]] || {
  echo "STOP: SOCKS 21002 is not the expected independent Backhaul"; exit 3;
}
B="/root/dual-backhaul-backups/mieru-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p -m 0700 "$B"
cp -a "$SRC" "$B/mieru.json"
cp -a "$UNIT" "$B/dual-ha-mieru.service"
cp -a "$BIN" "$B/mieru"
[[ -f "$D/mieru.original.json" ]] && cp -a "$D/mieru.original.json" "$B/mieru.original.json"
[[ -r /root/maya3-bh2.py ]] || {
  echo "STOP: rollback tool /root/maya3-bh2.py missing"; exit 3;
}
cat > "$B/restore-mieru.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || exit 2
echo "Restore Mieru ONLY if both Backhauls are unusable. This can interrupt users."
read -r -p "Type RESTORE MIERU to proceed: " WORD
[[ "\$WORD" == "RESTORE MIERU" ]] || { echo "Cancelled"; exit 1; }
install -m 0600 "$B/mieru.json" /etc/dual-ha/mieru.json
install -m 0644 "$B/dual-ha-mieru.service" /etc/systemd/system/dual-ha-mieru.service
install -m 0755 "$B/mieru" /opt/dual-ha/bin/mieru
systemctl daemon-reload
python3 /root/maya3-bh2.py rollback
if [[ -f /root/dual-backhaul-backups/installed-current ]]; then
    OLD_INSTALL="\$(cat /root/dual-backhaul-backups/installed-current)"
    if [[ -x "\$OLD_INSTALL/rollback.sh" ]]; then bash "\$OLD_INSTALL/rollback.sh"; fi
fi
echo "Original Mieru files restored; verify sudo dual status and real HTTPS."
EOF
chmod 0700 "$B/restore-mieru.sh"
systemctl disable --now dual-ha-mieru.service || true
rm -f -- "$SRC" "$UNIT" "$BIN"
systemctl daemon-reload
echo "MIERU REMOVED from Maya3 Iran (service unit, config and binary)."
echo "Original Mieru foreign VPS WAS NOT TOUCHED."
echo "Backup (root-only): $B"
echo "Restore if needed: sudo bash $B/restore-mieru.sh"
echo "Original Backhaul1, Backhaul2, HAProxy, controller and Xray untouched."
