# Naive + Mieru production manager

Repository branch: naive-mieru-live-safe-v1.

## Architecture and safety

Iran x-ui VLESS+REALITY TCP/443 -> dual-dispatcher SOCKS :7990 -> Naive XUDP-TRUST compatibility alias (:7991/:7993) OR Mieru (:7992/:7994). Round-robin already operates in production. NEVER use legacy Maya3 Triple scripts or old dual replace-foreign.sh on this system; those could restart the shared bridge or dispatcher.

## Install

From the pinned GitHub checkout on Iran, run sudo bash dual-trust-mieru/nm-install-manager.sh.
This installs command scripts only and does not start, stop, reload or restart any tunnel service.

Run dual for the interactive menu; dual menu also opens it. dual status remains read-only so status scripts keep working. dual health --full all is unchanged.

## Menu

1. Quick HTTPS and Telegram forced-path health.
2. Full HTTPS, Telegram, and actual SOCKS UDP/XUDP health for each role and dispatcher entry.
3. Replace Naive Foreign on a NEW VPS and a DIFFERENT DNS name.
4. Replace Mieru Foreign on a NEW VPS with the existing Mieru range.
5. Restart Naive carrier only (confirmation required).
6. Restart Mieru carrier only (confirmation required).
7. Recent errors and warnings; suppress likely credential lines.
8. Low-noise health profile and existing role-aware autoheal timer review. This action NEVER reloads dispatcher.
9. Conservative host audit, optional APT cache + journal cleanup; no networking, sysctl, firewall or service changes.
10. Live connection counts and 30s read-only observed new-connection balance.
11. Autoheal timer details.
12. Candidate status or abort.

## Foreign replacement workflow

The new wizard accepts either fresh VPS SSH provisioning (root SSH host fingerprint verification required; local existing UUID transferred securely) or an already installed new Foreign client JSON bundle.

Prepare creates an isolated test carrier and XUDP lane: Naive 17993/17991, Mieru 17994/17992. It requires unchanged live XUDP UUID, valid bundle, correct Naive DNS, successful HTTPS probes, 20/20 Telegram HTTPS, and UDP/XUDP. No public routing changes during preparation.

After explicit confirmation, cutover backs up existing credentials/config, restarts ONLY the corresponding live carrier, checks its direct, split TCP and UDP paths, verifies the OTHER role and shared process PIDs, and rolls back the specific carrier if necessary. Existing sessions on the replaced role may need to reconnect. Old Foreign VPS is deliberately NOT deleted. Root-only backups are kept under /var/lib/dual-trust-mieru/naive-mieru/replacements/backups/.

Candidate approval expires in 1 hour. Candidate PID changes invalidate approval. To abandon an isolated stage, use the menu's candidate abort function. Neither prepare nor cutover restarts x-ui, shared XUDP bridge, dispatcher, or the other carrier.

This first version has repository static checks but no real Foreign replacement integration test yet. Treat first actual replacement as controlled maintenance and separately validate the candidate before cutover.

Never change the shared XUDP UUID, remove old Trust aliases or run a pool reload as part of a simple role replacement.
