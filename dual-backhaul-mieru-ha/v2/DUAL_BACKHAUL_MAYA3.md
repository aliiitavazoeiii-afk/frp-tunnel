# Maya3 Dual Backhaul: operating and recovery plan

## Initial validated live topology (19 Nov 2026)

- Iran: 185.215.230.221 / REALITY :443.
- Backhaul1: 152.237.230.140, inbound reverse TLS :18443, local SOCKS :21001.
- Backhaul2: 82.152.132.112, bh3-new.biya2film.top, reverse TLS :18445, local SOCKS :21002.
- HAProxy :18080, existing dual_egress leastconn configuration. Backend called backhaul is Backhaul1; backend called mieru is Backhaul2. Its name is retained intentionally.
- Original Iran Mieru client is inactive. Keep its files until upgraded helper is installed.
- Both paths passed actual download/egress and were observed UP, weight=1, live sessions.

## New branch deliverables

- dual-backhaul-controller.py: replacement for existing /opt/dual-ha/controller.py on Maya3 only.
  Three HTTPS destinations (two must work), separate 256 KiB real download per path roughly every 45s, expected outgoing IP check, threshold-based failure/recovery hysteresis.
  After two short or two bulk consecutive failures, backend receives no NEW connections; recovery requires passed bulk and three healthy rounds. No TCP stream migration is possible.
  Controller JSON keeps /run/dual-ha-v2/health.json with extended diagnostic fields.
- dual_backhaul_menu.py: interactive sudo dual for Backhaul1 and Backhaul2 status, real health, rotation, recovery and logs.
- dual-backhaul2-rotate.py: independent second-role foreign staging using :18446, :21103, :19088 and :19089, unique token/WebSocket paths, V3 password-once SSH onboarding, full data-plane canary, transactional file backups, rollback, and a source-IP firewall guard for the selected live foreign host. Never contacts the old VPS.
- Original dual_swap_v3.py continues to rotate Backhaul1 with a compatible SSH/SCP fallback.
- install-dual-backhaul-maya3.sh: fail-closed deployment that stores a previous-version rollback, installs helper and replaces controller ONLY; restarts only dual-ha-v2-health.
- remove-mieru-maya3.sh: removes inactive local Mieru service config and binary after root-only archive and live Backhaul2 verification. Does NOT touch the foreign Mieru VPS and provides a restore script.

## Install on Maya3

Download install-dual-backhaul-maya3.sh from an exact Git commit URL, then:

    sudo bash /root/install-dual-backhaul-maya3.sh EXACT_40_CHAR_SHA
    sudo dual status
    sudo dual health
    sudo dual

The installer checks two working SOCKS endpoints and expected original Maya3 IPs before proceeding, and refuses unknown prior /usr/local/bin/dual owner. It backs up the helper and controller under /root/dual-backhaul-backups/install-TIMESTAMP, and writes installed-current to point to that backup. It checks for fresh controller reporting before reporting success. There is no Xray, HAProxy, or Backhaul restart.

## Rotate foreign nodes using only sudo dual

Interactive options 3 and 4 select Backhaul1 or Backhaul2 separately, prompt for the new public IP, verify foreign SSH fingerprint out-of-band and accept the new host root password once for key enrollment (or reuse a previously authorized SSH key). The other Backhaul and live HAProxy leastconn policy remain unchanged. The replacement must pass isolated end-to-end SOCKS IP verification and full 1MiB transfers before cutover; failed cutover restores prior local configs.

Noninteractive command entry with interactive password prompts:

    sudo dual replace backhaul1 NEW_PUBLIC_IP
    sudo dual replace backhaul2 NEW_PUBLIC_IP
    sudo dual recover backhaul1
    sudo dual recover backhaul2

A fresh Ubuntu amd64 foreign VPS must be able to reach Maya3 TLS port 18444 for a first-path V3 replacement, or 18446 for second-path stage. Permit port 18445 on the Iran provider firewall for second-path live cutover. The first-path live carrier remains 18443. Only the foreign node selected for replacement is installed/rekeyed.

## Remove Mieru locally only AFTER the new helper

Use the pinned remove-mieru-maya3.sh from this branch. It verifies inactive Mieru and working Backhaul2 on :21002, saves the old Mieru JSON, systemd unit and binary under /root/dual-backhaul-backups/mieru-TIMESTAMP, then removes only those original Mieru files from the Iran Maya3 server.

Recovery script is stored alongside the archive. It reconstitutes the Mieru files, then uses /root/maya3-bh2.py rollback and the saved old helper/controller installer rollback. This may interrupt user streams and will not repair a failed old Mieru foreign IP. Foreign Mieru host is deliberately left intact.

## Important limits

Both paths share the same family of Backhaul V2 WSSMux/TLS. Distinct credentials/ports/domains do not prove distinct DPI fingerprints or guarantee no filtering. HAProxy cannot migrate already-established TCP streams after a carrier dies; clients must reconnect. Bulk probes to a single public speedtest endpoint can have false positives and false negatives.

New management and failover code has passed offline CI only. Do not describe new foreign rotation or automatic bulk failover as already production-tested. Keep previous controller files for immediate recovery.
