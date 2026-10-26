# Tunnel Project History — Trust/Mieru → Triple Naive → Maya4 Naive Lite

> Canonical cross-branch project history for continuing work in a new ChatGPT session.
>
> Repository: `aliiitavazoeiii-afk/frp-tunnel`
>
> Default branch: `main`
>
> Last consolidated: 2026-10-26
>
> This file intentionally documents the evolution across multiple branches. For any live production change, **current branch code + live runtime output are more authoritative than this history**.

---

## 1. Project goals and operating rules

The project evolved from a dual-carrier Iran→Foreign tunnel into multiple independent transport profiles while preserving the existing public x-ui/VLESS/REALITY user configuration.

Core goals:

- keep the user-facing x-ui inbound stable;
- allow server-side foreign replacement without changing user configs;
- isolate carrier failures so one broken/filtered path does not require rebuilding the whole stack;
- prefer TCP-based transports;
- keep operational changes reversible;
- use candidate tests before cutover;
- preserve existing UUID/user state;
- avoid broad service restarts.

Non-negotiable safety rules:

1. Never use broad `pkill xray`.
2. Do not restart x-ui during ordinary foreign-carrier replacement.
3. Do not regenerate public user UUIDs during carrier changes.
4. Do not paste bundle contents, passwords, XUDP UUIDs, private keys or other secrets into chat or GitHub.
5. Keep the old foreign VPS available until the new one passes health checks and real-user verification.
6. Treat live runtime output as authoritative when documentation and runtime disagree.
7. Prefer role-specific restart/cutover over restarting shared infrastructure.

---

## 2. Phase 1 — Trust + Mieru dual-carrier production

Canonical production branch:

```
trust-mieru-dual
```

Current verified branch HEAD at this consolidation:

```
133be735d21a112fc0af842227fd4b07ade08818
```

Current verified version:

```
dual-trust-mieru/VERSION = 1.1.7
```

### Architecture

Public users remain on the existing x-ui VLESS/REALITY inbound:

```text
Users
  ↓
x-ui / VLESS REALITY / public :443
  ↓
SOCKS dispatcher 127.0.0.1:7990
  ↓
┌────────────────────────────┐
│                            │
Trust full path :7991        Mieru full path :7992
│                            │
TCP → :7993                  TCP → :7994
UDP → XUDP                   UDP → XUDP
│                            │
Trust foreign                Mieru foreign
```

Iran port map:

| Port | Purpose |
|---|---|
| 7990 | main dual dispatcher entry |
| 7991 | forced Trust full path |
| 7992 | forced Mieru full path |
| 7993 | Trust direct carrier SOCKS |
| 7994 | Mieru direct carrier SOCKS |
| 19090 | dispatcher controller |

Key services:

```
dual-trust-client.service
dual-mieru-carrier.service
dual-xudp-bridge.service
dual-dispatcher.service
dual-tunnel-autoheal.timer
x-ui.service
```

### Desired split routing

```text
trust-in TCP  -> carrier-trust
trust-in UDP  -> xudp-trust

mieru-in TCP  -> carrier-mieru
mieru-in UDP  -> xudp-mieru
```

### Mieru production settings

The final production Mieru settings intentionally use:

```text
multiplexing: MULTIPLEXING_OFF
handshake-mode: HANDSHAKE_STANDARD
traffic-pattern: ""
```

Do not re-enable Mieru multiplexing casually.

---

## 3. Dual-carrier bugs and fixes

### 3.1 Mieru multiplexing instability

Earlier builds used a multiplexing mode that correlated with freezes/unstable application behavior.

Final decision:

```
MULTIPLEXING_OFF
HANDSHAKE_STANDARD
```

This became a production invariant.

### 3.2 Trust XUDP target / loopback handling

Earlier Trust/XUDP routing had target-resolution problems around loopback usage.

The stable design uses a dedicated internal hostname for the Trust XUDP backend, resolved locally, rather than depending on an unsafe/ambiguous raw loopback path.

### 3.3 Dispatcher round-robin caused session instability

An earlier dispatcher configuration used round-robin selection.

That could split related application sessions across different egress IPs and contributed to instability for services such as Instagram.

The production dispatcher moved to sticky sessions:

```yaml
strategy: sticky-sessions
interval: 120
lazy: true
max-failed-times: 2
```

### 3.4 Aggressive health checks were reduced

The earlier health/autoheal cadence was too aggressive.

The later low-noise profile uses:

- dispatcher health interval around 120 seconds;
- lazy health behavior;
- autoheal approximately every 5 minutes with randomized jitter;
- real UDP/XUDP probing when diagnosing XUDP;
- no shared-bridge restart merely because one carrier is bad.

### 3.5 XUDP UUID mismatch during foreign replacement

A replacement foreign could be healthy at the carrier level while still having an XUDP UUID different from the currently live Iran configuration.

The replacement workflow was hardened so the live Iran role UUID is authoritative:

1. read the live role XUDP UUID on Iran;
2. transfer it to the new foreign without printing it;
3. patch and validate the new foreign Xray config;
4. verify foreign bundle UUID and foreign Xray UUID match the live Iran UUID;
5. only then perform the carrier cutover.

### 3.6 Xray temporary-file validation bug

Xray version behavior required the temporary candidate config to retain a `.json` suffix.

The installer/replacement path was corrected to validate JSON candidates using a JSON-suffixed temporary file.

### 3.7 Role replacement incorrectly depended on the sibling carrier

A major production bug occurred during Mieru replacement:

```text
ERROR: dual-trust-client inactive
```

The replacement helper used to require both Trust and Mieru to be active before replacing either role. This made it impossible to replace a working candidate Mieru foreign when Trust itself was filtered/down.

This was fixed so role replacement is independent.

The replacement precondition now requires the shared components, not the sibling carrier:

```
dual-xudp-bridge
dual-dispatcher
```

Important fixes in the v1.1.7 line included:

```
3e77babf961f68aa01a55ad90d850caf1d776f15
  replace-foreign-final precheck fix

bd05ef091966db921fe123b4f5d105c6fe330ee6
  runtime replace-carrier-only helper fix

3d4aa2ce252981cf9b939f0212373d2a17421b42
  source audit

133be735d21a112fc0af842227fd4b07ade08818
  VERSION 1.1.7
```

The installed runtime replacement helper is:

```
/usr/local/sbin/dual-replace-carrier
```

and is sourced from:

```
dual-trust-mieru/replace-carrier-only-final.sh
```

---

## 4. Dual operational interface

Normal operator entrypoint:

```bash
dual status
```

Health:

```bash
dual health --full all
dual health --full trust
dual health --full mieru
```

The manager supports role-specific replacement and should not restart x-ui or the unrelated carrier during an ordinary foreign swap.

Foreign installer:

```bash
sudo apt-get update && \
sudo apt-get install -y git && \
sudo rm -rf /opt/frp-tunnel && \
sudo git clone --depth 1 \
  --branch trust-mieru-dual \
  --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git \
  /opt/frp-tunnel && \
cd /opt/frp-tunnel/dual-trust-mieru && \
sudo bash dual-install-foreign.sh
```

Roles:

```
1 = Trust foreign
2 = Mieru foreign
```

Never paste generated private bundles into chat/repo.

---

## 5. Important Maya3 production diagnosis — RAM was not a Mieru leak

During a high-RAM incident on Maya3, the tunnel processes were inspected in detail.

Observed characteristics included:

- many established user and internal tunnel sockets;
- Trust carrying most traffic;
- Mieru lane effectively unused at that time;
- no single abusive user IP explaining the connection volume;
- Mieru process memory was small;
- Xray/Mihomo/Trust consumed memory, but process RSS did not explain the apparent missing ~1+ GiB.

The decisive finding was VMware ballooning:

```bash
vmware-toolbox-cmd stat balloon
```

reported approximately:

```
1278 MB
```

on a VM with roughly 2 GiB configured RAM.

At the same time Linux had very little `MemAvailable`, active swap and measurable memory PSI.

Conclusion:

- the main immediate pressure was the hypervisor reclaiming a large portion of guest RAM;
- it was not proven to be a Trust/Mieru/Mieru memory leak;
- do not “fix” this by unloading the VMware balloon driver or randomly restarting x-ui/tunnel services;
- check provider-side host contention, VM memory limits/reservations and migrate to a healthier node if needed.

This incident is operational history, not a permanent claim about all future RAM events.

---

## 6. Phase 2 — Naive experiments

Two separate ideas existed before the final triple and Maya4 designs.

### 6.1 `naive-mieru-dual`

Purpose:

```text
replace Trust role with Naive
keep Mieru
```

This was an experiment/release candidate and was not the canonical Trust/Mieru production path.

Do not assume it was deployed merely because the branch exists.

### 6.2 `maya3-multilane-naive`

Purpose:

- keep the existing Trust/Mieru legacy path;
- add a third Naive lane;
- selectively route new or explicitly assigned users to the new lane.

Current verified branch HEAD at consolidation:

```
7d3c11220c7767983fd43fee3934772b1a4cda25
```

This was an important design stage, but the later `triple-carrier-naive` branch became the more unified three-carrier model.

---

## 7. Phase 3 — Unified Triple: Trust + Mieru + Naive

Canonical branch:

```
triple-carrier-naive
```

Current verified branch HEAD at this consolidation:

```
9cc755bab9cac5399c940a5751069ac415b37611
```

Verified base versions:

```
dual-trust-mieru/VERSION = 1.1.7
dual-trust-mieru/LANE3_VERSION = 1.1.1
```

Note: older runbook text may still mention a prior Lane3 version. Current version files and current code win.

### Triple architecture

```text
Users
  ↓
Maya3 x-ui VLESS/REALITY :443
  ↓
Unified dispatcher :7990
  ├─ Trust full path :7991
  ├─ Mieru full path :7992
  └─ Naive full path :7996

Direct carriers:
  Trust :7993
  Mieru :7994
  Naive :7995
```

Naive full path:

- TCP → Naive direct SOCKS `:7995`
- UDP → dedicated XUDP path over the Naive carrier

### Triple design properties

- existing x-ui public inbound remains unchanged;
- Trust/Mieru remain intact;
- Naive can be added/removed from the unified pool;
- Naive has its own carrier and XUDP router;
- Naive failure does not require restarting the shared Trust/Mieru bridge;
- old foreign is not automatically deleted;
- sticky-session behavior remains important for user stability.

### Triple management

Main manager:

```bash
dual status
```

Naive management can be reached from the main manager or directly through the Lane3 helper on branches/installations that expose it.

Health:

```bash
dual health --full all
dual health --full naive
```

The unified pool concept is:

```text
all healthy:
7990 -> Trust / Mieru / Naive

Trust failed:
7990 -> Mieru / Naive

Mieru failed:
7990 -> Trust / Naive

Naive failed:
7990 -> Trust / Mieru
```

New/reconnected flows use healthy paths; existing TCP sessions cannot migrate mid-connection.

---

## 8. Phase 4 — Maya4 Naive Lite

Maya4 needed a simpler profile than Maya3.

Canonical branch:

```
maya4-naive-lite
```

Current verified branch HEAD at this consolidation:

```
ba9b941e9f3d8e82a0cd7bd504b8281ee32dc31e
```

Current verified version:

```
maya4-naive-lite/VERSION = 1.1.0
```

Maya4 is intentionally a **single-carrier Naive design**. It is not the Maya3 triple pool.

### Maya4 architecture

```text
Maya4 users
  ↓
3X-UI / Xray public inbound :443
  ↓
SOCKS 127.0.0.1:7996
  ├─ TCP -> Naive client 127.0.0.1:7995 -> foreign HTTPS :443
  └─ UDP -> XUDP over the same Naive carrier -> foreign loopback :2443
```

Iran services:

```
maya4-naive-client.service
maya4-xudp-router.service
x-ui.service
```

Foreign services:

```
maya4-naive-endpoint.service
maya4-xudp.service
```

Ports on Iran:

```
7995 = Naive direct SOCKS
7996 = full TCP + UDP/XUDP entry
443  = public 3X-UI user inbound
```

Ports on foreign:

```
443  = Naive HTTPS endpoint
2443 = XUDP backend, loopback only
```

### x-ui version invariant

Maya4 is pinned to:

```
3X-UI v2.9.4
```

Do not silently install/upgrade to “latest”.

### Resource profile

Maya4 was designed for a smaller VPS and includes systemd memory guardrails for its Naive/XUDP components plus swap creation logic when the host effectively has no swap.

---

## 9. Maya4 installation and attach behavior

Fresh foreign installation creates a private bundle:

```
/root/maya4-naive-client.json
```

Fresh Iran installation fetches that bundle over SSH and builds:

```
/etc/maya4-naive/naive.json
/etc/maya4-naive/xudp-router.json
/etc/maya4-naive/bundle.json
```

The public x-ui inbound is then attached to the local full path `:7996`.

Important:

- `maya4 attach` is for initial attachment;
- ordinary foreign replacement must **not** rerun attach;
- ordinary foreign replacement must **not** rerun `install-iran.sh`.

---

## 10. Maya4 bug: removed Xray release caused 404

A fresh foreign install later failed before asking for IP/domain:

```
curl: (22) The requested URL returned error: 404
```

Root cause:

```
XRAY_VERSION=v26.9.8
```

was pinned in `maya4-naive-lite/common.sh`, but that release was no longer available from the expected GitHub release URL.

The branch was updated to the then-current verified release:

```
XRAY_VERSION=v26.10.21
```

with official asset SHA256 values for amd64 and arm64.

Relevant commits:

```
414aa995915b01aacd37f1f20259dbfef2a8999f
  update Xray pin

339920d191f53b8d2f5b163cc5d105d899800cca
  audit the release pin
```

After this change, Maya4 foreign installation succeeded again.

---

## 11. Maya4 safe foreign replacement evolution

### First replacement helper

The branch gained a dedicated `replace-foreign.sh` instead of rerunning the Iran installer.

The replacement engine:

1. validates the candidate private bundle;
2. creates isolated candidate configs;
3. tests Naive direct on localhost `:17995`;
4. tests full TCP/XUDP path on localhost `:17996`;
5. requires TCP and UDP/XUDP success before cutover;
6. backs up current live config;
7. restarts only:
   - `maya4-naive-client.service`
   - `maya4-xudp-router.service`
8. does not restart x-ui;
9. runs live post-cutover tests;
10. rolls back to the previous Maya4 config if cutover validation fails.

### One-input automatic replacement

Manual steps were then simplified further.

A new Iran-side helper was added:

```
maya4-naive-lite/replace-foreign-auto.sh
```

and a dashboard:

```
maya4-naive-lite/manager.sh
```

The fixed replacement hostname is:

```
naive4.biya2film.top
```

The operator only provides the new foreign IPv4.

The helper:

1. checks that `naive4.biya2film.top` resolves to the new IPv4;
2. connects to the fresh foreign VPS over SSH;
3. installs prerequisites there;
4. clones branch `maya4-naive-lite`;
5. installs the foreign Naive HTTPS endpoint + XUDP backend non-interactively;
6. generates the private bundle on the foreign;
7. securely fetches the bundle to Iran;
8. runs the isolated `:17995` / `:17996` candidate tests;
9. cuts over only after candidate TCP and UDP/XUDP pass;
10. runs final Maya4 health;
11. leaves x-ui untouched;
12. leaves the old foreign VPS untouched.

The current Naive client uses an explicit host-resolver mapping for the live foreign IP. Therefore, changing public DNS to the new IP does not itself move the currently running Iran tunnel before the controlled cutover.

Important commits in this evolution:

```
10dce98177387b9dd8290b0b492476aaf2847e05
  non-interactive foreign installer support

bae8b52f31af7c04ef5c4b6d4ae917daf8233210
  one-input automatic replacement helper

3b0cbe40c3e2a6a7ae0f16b6947b31d9d8a46537
  Maya4 dashboard

a9c32d42b3f30433a72d2bfce609cb282bf0369e
  dashboard CLI integration

308f17c9aa6f815d37e0638561225d638c1bdb42
  install dashboard on Iran deployments

7f7132e59a6e51e386c958a4827f58fd4f453456
  dashboard/replacement safety audit

b0894058d3ceea43d51846d1c1fba0adde121b20
  Maya4 version 1.1.0

206bb10364b2ed4e8ba36689693a0db00a1225cc
  expose Maya4 dashboard through dual status

ba9b941e9f3d8e82a0cd7bd504b8281ee32dc31e
  audit dual status entrypoint
```

The final source audit for that HEAD completed successfully.

---

## 12. Current Maya4 operator interface

The preferred operator command is now:

```bash
dual status
```

This opens the Maya4 Naive dashboard.

Expected actions:

```text
1) Replace foreign server (enter new IP only)
2) Full health check
3) Restart Maya4 tunnel only (x-ui untouched)
4) Recent tunnel warnings/errors
0) Exit
```

Direct commands:

```bash
dual health
dual restart
dual replace NEW_FOREIGN_IP
```

Compatibility commands under `maya4` remain available on installations where the helper was installed, but `dual status` is the preferred interface.

### Replacement prerequisites

Before selecting replacement:

- provision a fresh foreign VPS;
- ensure root SSH works;
- ensure TCP/443 is free;
- point the DNS-only A record:
  `naive4.biya2film.top -> NEW_FOREIGN_IP`.

The helper refuses to continue if DNS is not ready and makes no Maya4 service/config change in that case.

---

## 13. Maya4 health expectations

Normal health command:

```bash
dual health
```

or the underlying helper:

```bash
maya4 health
```

Expected checks include:

```text
OK maya4-naive-client
OK maya4-xudp-router
OK x-ui
OK Naive direct :7995
OK Naive full   :7996
OK Telegram :7996=3/3
OK UDP/XUDP :7996=2/2
```

Exact timing/results depend on runtime conditions.

---

## 14. Branch map — what each branch means

### `trust-mieru-dual`

Stable dual Trust/Mieru production architecture.

Use when working on the two-carrier legacy production path.

### `triple-carrier-naive`

Unified Trust + Mieru + Naive pool for Maya3-style production.

Use when working on three-carrier unified health/balancing.

### `maya3-multilane-naive`

Earlier/selective Lane3 architecture that kept legacy users separate from explicitly assigned Naive users.

Historical/experimental relative to the later unified triple branch.

### `naive-mieru-dual`

Experiment to replace Trust with Naive while retaining Mieru.

Do not assume deployed.

### `maya4-naive-lite`

Dedicated lightweight single-Naive profile for Maya4.

This is the canonical branch for the current Maya4 dashboard and automatic foreign replacement workflow.

---

## 15. What a new chat must verify before changing production

Before making changes, fetch the relevant branch and current files from GitHub.

Never rely only on this history for live endpoints.

For Dual/Triple:

- verify branch HEAD/version;
- inspect current manager/health/replacement scripts;
- inspect runtime bundles only through safe/non-secret fields;
- verify service states and actual current port listeners.

For Maya4:

- verify `maya4-naive-lite` HEAD and `VERSION`;
- inspect:
  - `common.sh`
  - `install-foreign.sh`
  - `install-iran.sh`
  - `replace-foreign.sh`
  - `replace-foreign-auto.sh`
  - `manager.sh`
  - `enable-replace-command.sh`
  - `health.sh`
  - `source-audit.sh`;
- verify `dual status` is the installed entrypoint;
- verify x-ui remains v2.9.4;
- obtain current foreign IP from runtime/bundle instead of hard-coding old IPs.

---

## 16. Preferred troubleshooting model

When a user reports “tunnel is slow / foreign is filtered / users disconnect”:

1. identify which server/profile is involved: Maya3 Dual/Triple vs Maya4 Naive Lite;
2. inspect service state;
3. inspect direct carrier path;
4. inspect full TCP path;
5. inspect UDP/XUDP separately;
6. inspect user-facing x-ui only if evidence points there;
7. avoid changing multiple layers at once;
8. replace only the failed foreign/carrier;
9. candidate-test before cutover;
10. preserve rollback and the old VPS.

Do not infer a hard IP block merely from one timeout. Distinguish:

- DNS failure;
- TCP reachability;
- TLS/application reachability;
- carrier authentication;
- XUDP backend failure;
- selective/intermittent filtering;
- host resource pressure;
- hypervisor pressure.

---

## 17. Secret-handling rule

This repository is public.

Do not add:

- private client bundles;
- passwords;
- XUDP UUID values;
- x-ui user UUIDs;
- REALITY private keys;
- TLS private keys;
- SSH private keys;
- controller secrets.

Use filenames/paths and safe metadata instead.

---

## 18. Source of truth order

When facts conflict, use this order:

1. live production runtime output;
2. current code on the branch actually deployed;
3. current branch version/audit;
4. this cross-project history;
5. older runbooks/history files.

This prevents stale documentation from overriding a verified live state.
