# Dual HA Helper — Iran console and foreign VPS installer

This helper is built for the **existing** production architecture: Iran 94.184.4.38, Xray/REALITY TCP/443; local HAProxy SOCKS 127.0.0.1:18080; Backhaul 127.0.0.1:21001 -> Foreign-1 152.237.230.159; Mieru 127.0.0.1:21002 -> Foreign-2 152.237.230.248.

## 1. Install the helper ON IRAN

~~~bash
cd /root/frp-tunnel/frp-tunnel
git pull --ff-only
sudo bash dual-backhaul-mieru-ha/v2/install-dual-helper.sh
sudo dual
~~~

This copies the helper to /opt/dual-ha/helper, installs /usr/local/bin/dual and **does not restart or modify** x-ui, Xray, REALITY, Mieru, Backhaul or HAProxy.

Main menu:
- 1: Dashboard — foreign IPs, cached HTTPS health, HAProxy sessions, bytes in/out.
- 2: Detailed health — real HTTPS through Backhaul, Mieru and HAProxy + Iran-to-Mieru TCP port checks.
- 3: Replace Backhaul foreign IP via guarded SSH staging.
- 4: Replace Mieru foreign IP via guarded SSH staging.
- 5: Recent filtered service logs.

Shortcuts:

~~~bash
sudo dual status
sudo dual health
sudo dual logs
sudo dual replace backhaul NEW_FOREIGN_PUBLIC_IP
sudo dual replace mieru NEW_FOREIGN_PUBLIC_IP
~~~

**Filtering diagnostics disclaimer:** A single failed outbound HTTPS or TCP port probe cannot prove that an IP is filtered. Failure is classified as unavailable/degraded, potentially caused by filtering, firewall, routing, DNS, server process or foreign ISP issues. Actual filtering requires multiple independent probes from Iranian networks.

## 2. ONE standardized installer ON ANY NEW FOREIGN Ubuntu 24.04 amd64 VPS

Download the bootstrap script once on the **new foreign host**. Review the downloaded source before running as root if desired.

~~~bash
curl -fsSLo /root/dual-foreign-install.sh \
  https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/dual-backhaul-mieru-ha/dual-backhaul-mieru-ha/v2/foreign-install.sh
~~~

**Mieru role** (new Mita TCP/28443 host, bundle generated automatically):

~~~bash
sudo bash /root/dual-foreign-install.sh \
  --role mieru --iran-ip 94.184.4.38 --foreign-ip NEW_FOREIGN_PUBLIC_IP
~~~

**Backhaul role** (requires existing private reverse bundle copied securely from Iran first; use Iran menu option 3 to automate all steps):

~~~bash
sudo bash /root/dual-foreign-install.sh \
  --role backhaul --iran-ip 94.184.4.38 --foreign-ip NEW_FOREIGN_PUBLIC_IP \
  --bundle /root/dual-ha-backhaul-bundle.env --prepare
~~~

The **prepare** mode installs the pinned prebuilt Backhaul + local Dante SOCKS, verifies direct Dante HTTPS egress, and configures the remote service but does NOT connect it to Iran, preventing two active reverse clients fighting for Iran local port 21001. If deploying an entirely NEW system without an old reverse node, omit --prepare. Never use standalone non-prepare mode to replace a live production Backhaul.

The Mieru installer creates a fresh random secret and exports a private bundle to /etc/dual-ha/mieru-bundle.env (root-only). Transfer secret bundles via SCP/SSH, never paste tokens into chat or logs.

Firewall requirements: Iran accepts only new Backhaul host TCP/18443; Mieru foreign accepts Iran 94.184.4.38 to TCP/28443. UFW may be auto-updated, but provider firewalls are controlled separately. Iran Xray TCP/443 is never modified.

## 3. Auto replacement ON IRAN

**Requires passwordless root SSH keys to BOTH the old and candidate foreign hosts.** First independently verify each new SSH host fingerprint via provider console and trust it in root known_hosts. The helper uses StrictHostKeyChecking=yes and BatchMode=yes. Unknown or untrusted host keys cause an early abort.

For a root key already installed on Iran, use it; only create one if none exists. Example for onboarding a candidate:

~~~bash
# If /root/.ssh/id_ed25519 does not exist:
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519
# After independently verifying host fingerprint:
sudo ssh-copy-id root@NEW_FOREIGN_PUBLIC_IP

# Check BOTH hosts can be reached without passwords from Iran:
sudo ssh -o BatchMode=yes -o StrictHostKeyChecking=yes root@OLD_FOREIGN_PUBLIC_IP true
sudo ssh -o BatchMode=yes -o StrictHostKeyChecking=yes root@NEW_FOREIGN_PUBLIC_IP true
~~~

Then:

~~~bash
sudo dual
# choose 3 for Backhaul, 4 for Mieru, type new IP
# type the exact REPLACE confirmation string when prompted
~~~

Or directly:

~~~bash
sudo dual replace backhaul NEW_FOREIGN_PUBLIC_IP
sudo dual replace mieru NEW_FOREIGN_PUBLIC_IP
~~~

### Backhaul sequence

1. Verify other tunnel healthy/fresh, check no IP overlap, check both SSH root logins and active Iran services.
2. Securely back up old Backhaul secret bundle and stage a new-host bundle with the **same secret** and new foreign IP.
3. Securely SCP bundle to new host; install Backhaul + Dante in **prepare** mode. No effect on live old reverse client.
4. Authorize new host to Iran TCP/18443 in UFW when active. Provider firewall requires independent update.
5. Stop only old foreign reverse client, start new one, verify two successive HTTPS egress probes over Iran SOCKS 21001 with **the new IP**.
6. After validation enable new foreign reverse client on boot, disable old, update stored Iran foreign IP.
7. If anything fails, stop/disable candidate, restore old bundle, enable/start old reverse client, verify old egress. Keep old foreign machine online.

### Mieru sequence

1. Ensure Backhaul is healthy; install new Mita and get new unique credentials via SCP.
2. Check Iran can reach candidate TCP/28443, back up Iran Mieru JSON.
3. Atomically switch only Mieru remote IP and username/password, restart Iran Mieru client (not Xray).
4. Verify two successive HTTPS egress probes over SOCKS 21002 with new IP.
5. If this fails, restore old Mieru JSON and service. Original foreign Mita remains running.

### Known constraints

- Live customer streams on the replaced tunnel **may disconnect** during cutover and reconnect through the healthy other tunnel. Zero interruption is NOT guaranteed.
- Backend currently uses HAProxy leastconn, not strict 50/50 nor sticky-per-user routing.
- New foreign **egress IPv4** must match candidate IP: providers with NAT/mismatched egress will be rejected automatically; inspect NAT before swapping.
- Rollback depends on SSH availability and old machine remaining intact. Do not delete old host or its backups.
- No Xray or 3x-ui routing/client UUID/billing modification. Continue to monitor traffic accounting.
- The helpers are tested via CI syntax and local unit tests. **Real foreign rotation on production VPSs has not yet been integration-tested**. Choose a low-traffic window, keep a root recovery terminal and ensure provider firewalls.
- Only client-controlled NEW TCP connections can switch to surviving path; existing TCP streams cannot be transparently migrated.

## 4. Verify after each replacement

~~~bash
sudo dual health
sudo systemctl is-active x-ui dual-ha-v2-gateway dual-ha-v2-health
sudo ss -lntp '( sport = :443 )'
~~~

The previous Backhaul UFW allow-rule is **not automatically removed** for auditability. Remove stale IP-specific rules after confirming everything is stable and provider firewall reflects the new IP.
