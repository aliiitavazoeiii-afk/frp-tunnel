# Trust + Mieru Dual Tunnel — Project Context / Handoff

> **Read this file before changing production.**
>
> Repository: `aliiitavazoeiii-afk/frp-tunnel`
>
> Continuation branch: `trust-mieru-dual`
>
> Branch base at handoff: `62d51e12dc50867bbede9146634e2ac500b6be28` (`fix: correct carrier probe labels`)
>
> Date of this handoff: 2026-09-30

---

## 1. Purpose

This project provides a production dual-carrier tunnel from Iran to separate foreign servers using **TrustTunnel** and **Mieru**, while keeping the public user-facing x-ui/Xray VLESS/REALITY service unchanged.

The design deliberately keeps two independent carrier paths and a local dispatcher so a failure or filtering event affecting one foreign path does not require rebuilding x-ui or disconnecting every user.

The project is live production. Changes must be conservative, reversible and role-specific.

---

## 2. Non-negotiable production rules

1. **Do not restart or modify x-ui during a carrier migration.**
2. **Never use broad `pkill xray`**. x-ui also runs Xray; broad killing can disconnect production users.
3. During a Trust migration, restart only the Trust carrier unless a diagnosed XUDP endpoint problem requires a role-specific foreign XUDP restart.
4. During a Mieru migration, restart only the Mieru carrier unless a diagnosed XUDP endpoint problem requires a role-specific foreign XUDP restart.
5. Do not restart `dual-xudp-bridge` just because a carrier is bad. The bridge is shared by Trust and Mieru.
6. Keep the old foreign VPS available until the new path has passed repeated/full probes. Do not immediately delete the old VPS.
7. The live XUDP UUID on Iran is authoritative during **carrier-only replacement**. A newly installed foreign server generates a random XUDP UUID; that UUID must be replaced with the currently live Iran UUID before cutover.
8. Never paste bundle contents, usernames, passwords, UUID values, TLS private keys, REALITY keys or other secrets into chat/GitHub.
9. Avoid `cat /root/dual-*-client.json` in shared output. Inspect only safe fields with `jq '{kind,public_ip,...}'`.
10. Stop the autoheal timer while performing the final carrier cutover, then re-enable it afterward.
11. Trust and Mieru foreign roles should normally live on **separate VPSes** because both role-specific XUDP endpoints bind loopback `127.0.0.1:2443`.
12. Do not claim the tunnel is impossible to detect/filter. It is an operational dual-carrier design, not a guarantee against filtering.

---

## 3. Production architecture

```text
Public users
   |
   v
x-ui public VLESS/REALITY :443
   |
   v
SOCKS 127.0.0.1:7990  (Mihomo dispatcher)
   |
   +-------------------------+
   |                         |
   v                         v
Trust forced path :7991      Mieru forced path :7992
   |                         |
   | TCP                     | TCP
   v                         v
Trust carrier :7993          Mieru carrier :7994
(TrustTunnel local SOCKS)    (Mihomo/Mieru local SOCKS)
   |                         |
   |                         |
   | UDP -> XUDP             | UDP -> XUDP
   v                         v
xudp-trust outbound          xudp-mieru outbound
in dual-xudp-bridge          in dual-xudp-bridge
   |                         |
   | via carrier :7993       | via carrier :7994
   v                         v
Trust foreign                Mieru foreign
Trust endpoint :443          Mieru TCP range 20000-20020
XUDP 127.0.0.1:2443          XUDP 127.0.0.1:2443
```

### Port map on Iran

| Port | Purpose |
|---|---|
| `7990` | dual dispatcher entry |
| `7991` | forced Trust split path |
| `7992` | forced Mieru split path |
| `7993` | Trust direct carrier SOCKS |
| `7994` | Mieru direct carrier SOCKS |
| `19090` | dispatcher controller loopback |

### Key Iran services

- `dual-trust-client.service`
- `dual-mieru-carrier.service`
- `dual-xudp-bridge.service`
- `dual-dispatcher.service`
- x-ui/Xray service — **do not restart as part of carrier replacement**
- `dual-tunnel-autoheal.timer`

### Foreign role services

Trust foreign:
- `dual-trust-endpoint.service`
- `dual-xudp-trust.service`

Mieru foreign:
- Mieru server managed by `mita`
- `dual-xudp-mieru.service`

---

## 4. Routing invariant

The desired split router behavior is:

- `trust-in` TCP -> `carrier-trust`
- `trust-in` UDP -> `xudp-trust`
- `mieru-in` TCP -> `carrier-mieru`
- `mieru-in` UDP -> `xudp-mieru`

Mieru carrier final settings:

```text
multiplexing: MULTIPLEXING_OFF
handshake-mode: HANDSHAKE_STANDARD
```

Do not silently change these back to older experimental settings without a reason and a controlled benchmark.

---

## 5. Known stable code baseline

Main working branch before this handoff:

```text
dual-trust-mieru-v1-final
```

Continuation branch created for future work:

```text
trust-mieru-dual
```

Important commits in history:

```text
2d7e1cf...  host optimizer initial work
d0c5df...   host optimizer hardening
d6c540...   source audit work
dee52f...   VERSION 1.0.5 baseline
899369f...   add replace-carrier-only-final.sh
975ac3c...   add preserve-live-xudp-uuid-on-foreign.sh
30f5a79...   retry/warmup attempt; contained typo
62d51e1...   fixed carrier probe labels; current handoff base
```

`VERSION` around this finalized stage is 1.0.5.

---

## 6. Critical scripts

### `replace-carrier-only-final.sh`

Canonical production cutover helper:

```bash
sudo bash replace-carrier-only-final.sh trust /root/new-trust-client.json
sudo bash replace-carrier-only-final.sh mieru /root/new-mieru-client.json
```

Behavior at commit `62d51e1`:

- validates the supplied role bundle
- requires Trust, Mieru, bridge and dispatcher to already be active
- reads the live role XUDP UUID from `/etc/dual-trust-mieru/iran/xudp.json`
- refuses the cutover if the new bundle XUDP UUID differs
- backs up live carrier config + bundle under:
  `/var/lib/dual-trust-mieru/backups/carrier-only-ROLE-TIMESTAMP`
- rewrites only the selected role carrier config and bundle
- restarts only that carrier service
- Trust direct carrier port = `7993`; Trust forced path = `7991`
- Mieru direct carrier port = `7994`; Mieru forced path = `7992`
- direct stability probe: max 10 attempts, needs 3 consecutive HTTP 204 results
- split/path stability probe: max 8 attempts, needs 2 consecutive HTTP 204 results
- transient failure resets streak instead of immediate abort
- on persistent failure restores previous role carrier config/bundle and restarts only that role carrier
- does **not** restart shared XUDP bridge, dispatcher, x-ui or the other carrier

Expected success line:

```text
SUCCESS: trust carrier replaced with matching live XUDP UUID
```

or

```text
SUCCESS: mieru carrier replaced with matching live XUDP UUID
```

### `preserve-live-xudp-uuid-on-foreign.sh`

This helper was intended to copy the old live XUDP UUID into the newly installed foreign endpoint and client bundle.

**Important:** during a real Trust migration it appeared to complete without actually changing the UUID. Because of that incident, do not trust this helper without independently verifying both:

- new foreign bundle UUID == old live Iran UUID
- new foreign Xray inbound UUID == old live Iran UUID

Manual UUID preservation is currently preferred for critical migrations.

### `dual-tunnel-probe --full`

Used after migrations to test:

- Trust gstatic
- Mieru gstatic
- dual dispatcher gstatic
- YouTube / ytimg / Instagram
- transfer test
- UDP/XUDP for Trust
- UDP/XUDP for Mieru
- UDP/XUDP for dual path
- dispatcher egress behavior

Do not consider a migration fully validated only because direct TCP HTTP 204 passes. `--full` must also be checked for XUDP/UDP if that functionality is required.

---

## 7. Autoheal behavior

`dual-autoheal.sh` is intentionally selective.

- Trust direct unhealthy -> may restart only `dual-trust-client.service`
- Mieru direct unhealthy -> may restart only `dual-mieru-carrier.service`
- shared bridge is considered only when **both direct carriers are healthy** but one/both split paths remain unhealthy
- repeated path-only failures can restart `dual-xudp-bridge.service`

Logs:

```bash
journalctl -t dual-autoheal -n 100 --no-pager
```

Status:

```bash
systemctl status dual-tunnel-autoheal.timer --no-pager
```

During manual carrier migration:

```bash
systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
# perform cutover
systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
```

---

## 8. Host optimizer

`host-optimizer.sh` is deliberately independent of tunnel configuration. It applies conservative host/network tuning without changing Trust/Mieru routing or restarting live tunnel/x-ui services.

A production user reported a previously slow Maya became significantly better after this optimizer.

When a production repository checkout had local changes, the safe pattern used was to clone the optimizer/project separately instead of doing a destructive `git reset` or overwriting the production checkout.

---

## 9. Gold migration that fully passed

A known-good completed migration was:

```text
Trust foreign: 82.152.132.219
Mieru foreign: 82.152.132.81
```

After cutover, observed tests included:

```text
MIERU-DIRECT 7994 HTTP=204
MIERU-PATH   7992 HTTP=204
TRUST-PATH   7991 HTTP=204
DUAL         7990 HTTP=204
```

Full probe then passed Trust/Mieru/Dual including XUDP, and dispatcher egress rotated between both foreign endpoints.

This migration is the best reference for expected healthy behavior.

---

## 10. Failed / problematic Mieru migration history

An Austria Mieru VPS `82.152.132.130` showed random instability even though:

- Mieru server reported RUNNING
- all expected ports listened
- loopback XUDP endpoint was active
- time/NTP was synchronized
- firewall was not the obvious problem

Observed behavior included intermittent direct and split failures, including TLS-established sessions that later stalled.

Selected remote-port tests showed inconsistent success; even apparently better ports were not perfectly stable. Example longer results included approximately:

```text
20000: 17/20
20004: 18/20
20008: 17/20
20016: 19/20
```

Conclusion at the time: instability was not explained solely by random port choice; server/path quality itself was suspect. The VPS was abandoned and replaced with `82.152.132.81`, which passed the full probe.

Operational lesson: if the direct Mieru carrier (`7994`) itself randomly fails across multiple destinations/ports, do not immediately blame the shared XUDP bridge. Test direct carrier separately before changing shared components.

---

## 11. Trust/XUDP incident discovered on 2026-09-30

After replacing Trust, direct TCP and normal split HTTP tests could pass while full UDP/XUDP failed with timeouts.

Observed healthy pieces included:

```text
TRUST-DIRECT HTTP=204
TRUST-PATH HTTP=204
TRUST YouTube OK
TRUST Instagram OK
TRUST transfer OK
```

but full probe reported repeated:

```text
TRUST UDP/XUDP attempt failed: TimeoutError
```

Iran bridge logs showed correct routing:

```text
trust-in -> xudp-trust
xudp-trust attempts tcp:xudp-trust.internal:2443
redirected through carrier-trust / 127.0.0.1:7993
```

A direct diagnostic through Trust SOCKS:

```bash
curl -v --socks5-hostname 127.0.0.1:7993 \
  --connect-timeout 5 --max-time 5 \
  telnet://xudp-trust.internal:2443 </dev/null
```

returned:

```text
Can't complete SOCKS5 connection to xudp-trust.internal. (5)
```

On one foreign server the role services were active and `127.0.0.1:2443` was locally open, while:

```bash
getent ahostsv4 xudp-trust.internal
```

returned nothing.

The Trust installer is designed to create:

```text
127.0.0.1 xudp-trust.internal # dual-trust-mieru trust-xudp-backend
```

in `/etc/hosts`, and `vpn.toml` uses:

```text
allow_private_network_connections = true
```

Nevertheless, the real migration encountered the hostname/CONNECT failure. Merely adding the `/etc/hosts` record did not immediately solve the user's failing server, so do **not** assume this incident is fully understood or fixed.

### Diagnostics for this class of failure

On Trust foreign:

```bash
systemctl is-active dual-trust-endpoint.service
systemctl is-active dual-xudp-trust.service
ss -ltnp | grep ':2443'
getent ahostsv4 xudp-trust.internal

timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2443' \
  && echo '2443 LOCAL = OPEN' \
  || echo '2443 LOCAL = FAILED'

grep 'allow_private_network_connections' \
  /etc/dual-trust-mieru/trust/vpn.toml
```

From Iran:

```bash
curl -v --socks5-hostname 127.0.0.1:7993 \
  --connect-timeout 5 --max-time 5 \
  telnet://xudp-trust.internal:2443 </dev/null
```

If direct Trust HTTP works but the SOCKS CONNECT to the internal XUDP backend returns code 5, investigate Trust endpoint destination handling / internal hostname resolution before restarting shared Iran bridge or x-ui.

---

## 12. UUID migration incident / why UUID handling matters

A newly installed foreign role creates a new random XUDP UUID. But the live Iran bridge still contains the old UUID in its `xudp-trust` or `xudp-mieru` outbound.

Replacing only the carrier while the foreign XUDP endpoint uses a different UUID breaks XUDP.

Therefore the safe carrier-only migration invariant is:

```text
new foreign XUDP inbound UUID
    == new client bundle xudp_uuid
    == current live Iran xudp outbound UUID
```

The cutover helper intentionally refuses a mismatch.

A real operator error also occurred when `OLD` was empty because an `scp foreign -> Iran` operation was interrupted. `jq --arg uuid "$OLD"` then produced a temporary Xray config with an empty UUID and Xray validation correctly failed with:

```text
common/uuid: invalid UUID:
```

Because validation happened before installing the temporary config, the production foreign Xray file was not damaged.

Lesson: validate the UUID file/value **before** building or installing role config.

---

## 13. Connectivity asymmetry encountered

Some foreign VPSes could not initiate SSH/SCP connections to the Iran server. Therefore this command from foreign could hang/fail:

```bash
scp root@IRAN_IP:/etc/dual-trust-mieru/iran/trust-bundle.json /root/old-iran-trust-bundle.json
```

The reliable workaround is to move only the live UUID in the direction that works:

### On Iran

Trust:

```bash
jq -r '.xudp_uuid' /etc/dual-trust-mieru/iran/trust-bundle.json \
  > /root/live-trust-uuid.txt
chmod 600 /root/live-trust-uuid.txt
scp /root/live-trust-uuid.txt root@NEW_FOREIGN_IP:/root/live-trust-uuid.txt
```

Mieru:

```bash
jq -r '.xudp_uuid' /etc/dual-trust-mieru/iran/mieru-bundle.json \
  > /root/live-mieru-uuid.txt
chmod 600 /root/live-mieru-uuid.txt
scp /root/live-mieru-uuid.txt root@NEW_FOREIGN_IP:/root/live-mieru-uuid.txt
```

Then patch the newly installed foreign role locally.

After the foreign bundle is correct, Iran can normally pull the new client bundle from the foreign VPS:

```bash
scp root@NEW_FOREIGN_IP:/root/dual-trust-client.json /root/new-trust-client.json
```

or

```bash
scp root@NEW_FOREIGN_IP:/root/dual-mieru-client.json /root/new-mieru-client.json
```

This avoids requiring foreign -> Iran SSH.

---

## 14. Canonical Trust foreign replacement runbook

Use placeholders; do not copy secrets into chat.

### A. DNS first

Point the Trust domain A record to the new foreign IP and wait until:

```bash
getent ahostsv4 TRUST_DOMAIN | awk '{print $1}' | sort -u
```

shows the new IP.

The Trust installer checks DNS before obtaining the certificate.

### B. Install on clean Trust foreign

```bash
apt-get update
apt-get install -y git curl jq ca-certificates
rm -rf /opt/frp-tunnel

git clone --branch trust-mieru-dual --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git \
  /opt/frp-tunnel

cd /opt/frp-tunnel
cd dual-trust-mieru

sudo bash install-foreign-trust.sh \
  --public-ip NEW_TRUST_IP \
  --domain TRUST_DOMAIN \
  --email CERT_EMAIL
```

The server should have:

```text
0.0.0.0:443              Trust endpoint
127.0.0.1:2443           XUDP Xray endpoint
```

### C. Push the live Trust UUID from Iran

On Iran:

```bash
jq -r '.xudp_uuid' /etc/dual-trust-mieru/iran/trust-bundle.json \
  > /root/live-trust-uuid.txt
chmod 600 /root/live-trust-uuid.txt
scp /root/live-trust-uuid.txt root@NEW_TRUST_IP:/root/live-trust-uuid.txt
```

### D. Patch new foreign UUID safely

On new Trust foreign:

```bash
OLD=$(tr -d '\r\n' < /root/live-trust-uuid.txt)

[[ "$OLD" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  && echo 'UUID FILE = VALID' \
  || { echo 'STOP: UUID FILE INVALID'; exit 1; }

cp -a /etc/dual-trust-mieru/trust/xray.json /root/trust-xray.before-uuid.json
cp -a /root/dual-trust-client.json /root/dual-trust-client.before-uuid.json

jq --arg uuid "$OLD" \
  '(.inbounds[] | select(.tag=="xudp-in").settings.users[0].id) = $uuid' \
  /etc/dual-trust-mieru/trust/xray.json \
  > /tmp/trust-xray-new.json

/usr/local/lib/dual-trust-mieru/xray run -test -c /tmp/trust-xray-new.json

install -m 600 /tmp/trust-xray-new.json \
  /etc/dual-trust-mieru/trust/xray.json

jq --arg uuid "$OLD" '.xudp_uuid = $uuid' \
  /root/dual-trust-client.json \
  > /tmp/dual-trust-client-new.json

install -m 600 /tmp/dual-trust-client-new.json \
  /root/dual-trust-client.json
```

Verify internal hostname:

```bash
getent ahostsv4 xudp-trust.internal
```

Expected:

```text
127.0.0.1
```

If missing:

```bash
sed -i '/xudp-trust\.internal/d' /etc/hosts
printf '%s\n' \
  '127.0.0.1 xudp-trust.internal # dual-trust-mieru trust-xudp-backend' \
  >> /etc/hosts
```

Restart only role-specific foreign services:

```bash
systemctl restart dual-xudp-trust.service
systemctl restart dual-trust-endpoint.service
sleep 3
```

Verify UUID equality without printing secrets:

```bash
NEW=$(jq -r '.xudp_uuid' /root/dual-trust-client.json)
SRV=$(jq -r '.inbounds[] | select(.tag=="xudp-in").settings.users[0].id' \
  /etc/dual-trust-mieru/trust/xray.json)

[[ "$OLD" == "$NEW" ]] && echo 'BUNDLE UUID = MATCH' || echo 'BUNDLE UUID = DIFFERENT'
[[ "$OLD" == "$SRV" ]] && echo 'SERVER UUID = MATCH' || echo 'SERVER UUID = DIFFERENT'
```

### E. Pull new bundle and cut over Iran

On Iran:

```bash
rm -f /root/new-trust-client.json
scp root@NEW_TRUST_IP:/root/dual-trust-client.json /root/new-trust-client.json
chmod 600 /root/new-trust-client.json

jq '{kind,public_ip,domain,port}' /root/new-trust-client.json

LIVE=$(jq -r '.outbounds[] | select(.tag=="xudp-trust").settings.id' \
  /etc/dual-trust-mieru/iran/xudp.json)
NEW=$(jq -r '.xudp_uuid' /root/new-trust-client.json)

[[ "$LIVE" == "$NEW" ]] \
  && echo 'READY: UUID MATCH' \
  || { echo 'STOP: UUID DIFFERENT'; exit 1; }
```

Then:

```bash
systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
cd /opt/frp-migration-tools/dual-trust-mieru
sudo bash replace-carrier-only-final.sh trust /root/new-trust-client.json
systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
```

### F. Test Trust

```bash
curl -4 -sS --socks5-hostname 127.0.0.1:7993 \
  --connect-timeout 5 --max-time 12 \
  -o /dev/null \
  -w 'TRUST-DIRECT HTTP=%{http_code} TOTAL=%{time_total}\n' \
  https://www.gstatic.com/generate_204

curl -4 -sS --socks5-hostname 127.0.0.1:7991 \
  --connect-timeout 5 --max-time 12 \
  -o /dev/null \
  -w 'TRUST-PATH HTTP=%{http_code} TOTAL=%{time_total}\n' \
  https://www.gstatic.com/generate_204
```

Optional internal backend diagnostic:

```bash
curl -v --socks5-hostname 127.0.0.1:7993 \
  --connect-timeout 5 --max-time 5 \
  telnet://xudp-trust.internal:2443 </dev/null
```

Then:

```bash
dual-tunnel-probe --full
```

---

## 15. Canonical Mieru foreign replacement runbook

### A. Install on a clean Mieru foreign VPS

```bash
apt-get update
apt-get install -y git curl jq ca-certificates
rm -rf /opt/frp-tunnel

git clone --branch trust-mieru-dual --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git \
  /opt/frp-tunnel

cd /opt/frp-tunnel/dual-trust-mieru

sudo bash install-foreign-mieru-final.sh \
  --public-ip NEW_MIERU_IP \
  --port-range 20000-20020
```

Verify:

```bash
mita status
systemctl is-active dual-xudp-mieru.service
ss -ltnp | grep -E ':(20000|20010|20020|2443)[[:space:]]'
```

### B. Push live Mieru UUID from Iran

On Iran:

```bash
jq -r '.xudp_uuid' /etc/dual-trust-mieru/iran/mieru-bundle.json \
  > /root/live-mieru-uuid.txt
chmod 600 /root/live-mieru-uuid.txt
scp /root/live-mieru-uuid.txt root@NEW_MIERU_IP:/root/live-mieru-uuid.txt
```

### C. Patch new foreign UUID

On Mieru foreign:

```bash
OLD=$(tr -d '\r\n' < /root/live-mieru-uuid.txt)

[[ "$OLD" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  && echo 'UUID FILE = VALID' \
  || { echo 'STOP: UUID FILE INVALID'; exit 1; }

cp -a /etc/dual-trust-mieru/mieru/xray.json /root/mieru-xray.before-uuid.json
cp -a /root/dual-mieru-client.json /root/dual-mieru-client.before-uuid.json

jq --arg uuid "$OLD" \
  '(.inbounds[] | select(.tag=="xudp-in").settings.users[0].id) = $uuid' \
  /etc/dual-trust-mieru/mieru/xray.json \
  > /tmp/mieru-xray-new.json

/usr/local/lib/dual-trust-mieru/xray run -test -c /tmp/mieru-xray-new.json

install -m 600 /tmp/mieru-xray-new.json \
  /etc/dual-trust-mieru/mieru/xray.json

jq --arg uuid "$OLD" '.xudp_uuid = $uuid' \
  /root/dual-mieru-client.json \
  > /tmp/dual-mieru-client-new.json

install -m 600 /tmp/dual-mieru-client-new.json \
  /root/dual-mieru-client.json

systemctl restart dual-xudp-mieru.service
sleep 3
```

Verify UUID equality without printing it.

### D. Iran cutover

```bash
rm -f /root/new-mieru-client.json
scp root@NEW_MIERU_IP:/root/dual-mieru-client.json /root/new-mieru-client.json
chmod 600 /root/new-mieru-client.json

jq '{kind,public_ip,port_range}' /root/new-mieru-client.json

LIVE=$(jq -r '.outbounds[] | select(.tag=="xudp-mieru").settings.id' \
  /etc/dual-trust-mieru/iran/xudp.json)
NEW=$(jq -r '.xudp_uuid' /root/new-mieru-client.json)

[[ "$LIVE" == "$NEW" ]] \
  && echo 'READY: UUID MATCH' \
  || { echo 'STOP: UUID DIFFERENT'; exit 1; }

systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
cd /opt/frp-migration-tools/dual-trust-mieru
sudo bash replace-carrier-only-final.sh mieru /root/new-mieru-client.json
systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
```

### E. Test Mieru and both-role health

```bash
curl -4 -sS --socks5-hostname 127.0.0.1:7994 \
  --connect-timeout 5 --max-time 12 \
  -o /dev/null \
  -w 'MIERU-DIRECT HTTP=%{http_code} TOTAL=%{time_total}\n' \
  https://www.gstatic.com/generate_204

curl -4 -sS --socks5-hostname 127.0.0.1:7992 \
  --connect-timeout 5 --max-time 12 \
  -o /dev/null \
  -w 'MIERU-PATH HTTP=%{http_code} TOTAL=%{time_total}\n' \
  https://www.gstatic.com/generate_204

curl -4 -sS --socks5-hostname 127.0.0.1:7991 \
  --connect-timeout 5 --max-time 12 \
  -o /dev/null \
  -w 'TRUST-PATH HTTP=%{http_code} TOTAL=%{time_total}\n' \
  https://www.gstatic.com/generate_204

curl -4 -sS --socks5-hostname 127.0.0.1:7990 \
  --connect-timeout 5 --max-time 12 \
  -o /dev/null \
  -w 'DUAL HTTP=%{http_code} TOTAL=%{time_total}\n' \
  https://www.gstatic.com/generate_204

dual-tunnel-probe --full
```

---

## 16. Generic diagnosis order

When a path is broken, diagnose from narrowest layer outward. Do not immediately restart everything.

### Trust failure

1. `7993` direct HTTP test
2. `7991` split HTTP test
3. Trust foreign TCP/443 reachability
4. Trust foreign endpoint service
5. Trust foreign XUDP loopback `2443`
6. internal XUDP hostname CONNECT through `7993`
7. UUID equality
8. shared bridge only after carriers are confirmed healthy

### Mieru failure

1. `7994` direct HTTP test
2. `7992` split HTTP test
3. raw reachability to representative range ports (20000/20010/20020)
4. `mita status` on foreign
5. foreign XUDP loopback `2443`
6. UUID equality
7. shared bridge only after direct carrier is stable

### Dispatcher issue

If `7991` and `7992` are individually healthy but `7990` is unstable, then inspect dispatcher state/controller and logs rather than modifying foreign endpoints first.

---

## 17. Interpreting common errors

### `HTTP=000`, connection reset, SSL timeout

Not enough by itself to prove IP filtering. First restart **only the affected carrier** and retry. If direct carrier remains unstable, test underlying foreign reachability and carrier logs.

### `proxy/socks: server rejects request: 5`

The local carrier SOCKS accepted the request but could not establish the requested remote destination. For Trust XUDP this was seen specifically when requesting `xudp-trust.internal:2443`.

### `common/mux: failed to fetch all input`, `read/write on closed pipe`

Often follows an underlying carrier/SOCKS/XUDP failure. Treat it as a downstream symptom rather than immediately blaming mux itself.

### Mieru direct path intermittent while split also intermittent

Suspect Mieru carrier/server/path first. Do not restart bridge repeatedly.

### Direct path healthy but UDP/XUDP full probe timeout

Inspect role XUDP endpoint, UUID and backend reachability. A regular HTTP 204 through `7991`/`7992` primarily proves TCP split behavior, not necessarily functional UDP/XUDP.

---

## 18. Production state near this handoff

### Iran node currently referred to in chat as Maya3

```text
Iran IP: 5.10.249.206
```

Latest selected Trust foreign in the migration sequence:

```text
193.57.9.218
```

Latest selected Mieru foreign being migrated at handoff:

```text
193.57.9.156
```

Important distinction:

- Trust `193.57.9.218` had progressed far enough that the user moved on to replacing Mieru, but a final pasted `dual-tunnel-probe --full` result for this exact final Trust endpoint is not preserved here. Re-verify rather than blindly assuming full UDP/XUDP health.
- Mieru `193.57.9.156` migration instructions had been issued, but completion/full-probe confirmation had not yet been received at the time this handoff document was written.

Earlier endpoints used/attempted during recent migrations include:

```text
82.152.132.219  Trust — known full-probe-success reference on another Maya
82.152.132.81   Mieru — known full-probe-success reference
82.152.132.130  Mieru — abandoned due random instability
82.152.132.226  Trust — used during migration sequence
82.152.132.227  Mieru — used during migration sequence
104.252.19.38   Trust — direct TCP worked; Trust XUDP/internal backend issue investigated
104.252.19.211  candidate server discussed during replacement sequence
193.57.9.218    latest Trust selection for Maya3
193.57.9.156    latest Mieru selection for Maya3
```

Do not infer that every historical IP is still active or safe. Confirm runtime state from the servers before cleanup.

---

## 19. Rollback guidance

`replace-carrier-only-final.sh` creates a role-specific backup and automatically restores the previous carrier on persistent cutover failure.

Manual rollback should normally mean restoring only the selected role's backed-up config/bundle and restarting only that role's carrier.

Do not perform a broad x-ui/Xray restart as a rollback shortcut.

Keep the previous foreign VPS alive until the replacement has been stable under normal traffic and `dual-tunnel-probe --full`.

---

## 20. Security / secret handling

Sensitive files include:

```text
/root/dual-trust-client.json
/root/dual-mieru-client.json
/etc/dual-trust-mieru/iran/trust-bundle.json
/etc/dual-trust-mieru/iran/mieru-bundle.json
/etc/dual-trust-mieru/iran/xudp.json
```

Never commit them.

When showing metadata, use limited `jq` projections, for example:

```bash
jq '{kind,public_ip,domain,port}' /root/new-trust-client.json
jq '{kind,public_ip,port_range}' /root/new-mieru-client.json
```

For UUID verification, print only `MATCH/DIFFERENT`, not the UUID value.

---

## 21. Rules for the next ChatGPT session

The next assistant should:

1. Read this file and inspect the `trust-mieru-dual` branch before suggesting production changes.
2. Treat actual server/runtime output as authoritative over old documentation.
3. Ask for or inspect only the minimum output needed to diagnose a failure.
4. Give copy-paste commands labeled clearly as **FOREIGN TRUST**, **FOREIGN MIERU**, or **IRAN**.
5. Prefer short command blocks because large multiline pastes have occasionally been mangled in the user's terminal/PuTTY workflow.
6. Never repeat questions whose answers are already present in this project context.
7. Keep old foreign endpoints for rollback until full validation.
8. Preserve live XUDP UUID during carrier-only migrations.
9. Avoid changing both carriers simultaneously. Replace/test one role first, then the other.
10. Do not change x-ui/public VLESS/REALITY while doing a carrier-only migration.

---

## 22. Recommended immediate continuation

At the point of this handoff:

1. Confirm whether Mieru `193.57.9.156` installation and UUID preservation completed.
2. If not, resume the Mieru migration runbook in section 15.
3. Run direct tests for `7994`, `7992`, `7991`, and `7990`.
4. Run `dual-tunnel-probe --full`.
5. If Trust TCP passes but Trust UDP/XUDP fails, use the Trust/XUDP diagnostic path in section 11 rather than rebuilding the Iran tunnel.
6. Only after both roles pass should old foreign VPSes be considered for retirement.

---

## 23. Core principle

**Carrier replacement is not a reinstall of the Iran tunnel.**

The stable production state on Iran — x-ui, dispatcher, shared XUDP bridge, user-facing VLESS/REALITY and the other healthy carrier — should remain in place. A replacement should normally consist of:

```text
install new foreign role
-> preserve live role XUDP UUID
-> validate new foreign role
-> pull new role bundle to Iran
-> verify UUID match
-> replace only selected carrier
-> direct probe
-> split probe
-> full probe
-> retain old foreign for rollback window
```

That procedure is the operational baseline for future work.
