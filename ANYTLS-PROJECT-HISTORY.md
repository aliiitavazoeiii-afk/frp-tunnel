# AnyTLS / Bucket5 Project — Complete Continuation History

> Continuation document for future ChatGPT sessions and operators.
>
> Repo: `aliiitavazoeiii-afk/frp-tunnel`
> Active branch at the time this document was written: `bucket5-v2`
> GitHub branch HEAD before this documentation commit: `de6cd6735a84eee04c1117dcec5dc070d362dfcf`
> `VERSION`: `2.0.7`
> History cutoff: 2026-09-17 (Asia/Tehran operational timeline)

## 0. Read this first: source-of-truth and safety

This file exists because the project evolved through several architectures and emergency fixes inside a long production debugging session. It is intended to prevent a future assistant/operator from reconstructing the state from stale assumptions.

Rules for future work:

1. **GitHub current branch code and live server state beat this document if they differ.** This file records the verified state and history at its cutoff date, but production is allowed to drift later.
2. Before changing production, fetch the exact current files and SHAs from `bucket5-v2`, then inspect live status on both Iran gateways.
3. `BUCKET5-RUNBOOK.md` contains stale details in at least topology and ports. Do not use it as the only source of truth. In particular, older text mentions F2=ResTLS/F5=ShadowTLS and XUDP ports 8101–8110; current fresh/resume runtime code uses a different topology and XUDP range 18101–18110.
4. **Do not execute base `install-bucket5.sh` directly on live production.** Current production migration behavior is implemented by `install-bucket5-fresh.sh` / `install-bucket5-resume.sh`, which copy the base installer to a runtime file and apply `bucket5-runtime-patch.py` before execution.
5. Existing x-ui users, UUIDs, public VLESS/REALITY inbound, and stable user→bucket mappings are business invariants. Never regenerate or replace them as part of tunnel maintenance.
6. Never put AnyTLS passwords, ShadowTLS/ResTLS secrets, controller secrets, or the XUDP UUID into GitHub documentation or chat. Compare hashes when identity verification is necessary.
7. Production users are active. Candidate configurations must be validated and full-probed before activation, with backup + rollback available.
8. Do not manually return an unhealthy Foreign node to service just to test it. Use isolated probes first.
9. For small runtime changes, do not rerun full fresh/resume migration unless absolutely necessary.
10. All Foreign servers are constrained to the same general provider/ASN environment; the architecture must work under that constraint.

---

## 1. Project goal and original problem

The user previously operated an XHTTP-based Iran↔Foreign tunnel. It provided good continuity once established, but Foreign IPs were being filtered too frequently. The goal became a production-grade censorship-resistant path with:

- high speed,
- very low user-visible interruption,
- automatic health failover,
- traffic/load distribution,
- stable user identity and assignment,
- no manual user migration when a Foreign node fails,
- no x-ui public inbound changes,
- safe rollback,
- strong observability to distinguish IP blocking, transport failure, XUDP failure, and application failure.

A major operational constraint is that live users already exist and should not be disconnected by experimental migrations.

---

## 2. Pre-Bucket5 AnyTLS final architecture

Before Bucket5, the proven data path on Iran was roughly:

```text
User
  |
  v
x-ui public VLESS/REALITY TCP :443     (unchanged public interface)
  |
  v
x-ui SOCKS outbound "anytls-tunnel"
  |
  v
127.0.0.1:7891  Xray XUDP bridge SOCKS
  |
  v
VLESS/XUDP inner stream -> Foreign 127.0.0.1:2443
  ^
  | dialerProxy
  |
127.0.0.1:7890  Mihomo AnyTLS carrier SOCKS
  |
  v
AnyTLS + outer TLS camouflage
  |
  v
Foreign public :443
```

Important historical settings:

- `QUIC_SAFE_MODE=false` in final mode.
- Mihomo controller is loopback-only; port is read from `/etc/anytls-tunnel/deploy.env` (commonly 9090, but live env is the source of truth).
- Foreign XUDP endpoint is loopback-only at `127.0.0.1:2443`.
- All Foreign endpoints participating in a given deployment must use the same XUDP UUID/port expected by the Iran gateways.

Two outer Foreign roles were built:

- `foreign-a`: AnyTLS + ShadowTLS v3.
- `foreign-b`: AnyTLS + ResTLS.

This period then evolved into shared-node and health-gated round-robin work before Bucket5.

---

## 3. Pre-Bucket5 health-gated / shared-node evolution

The Sep 15 lineage added increasingly strict health gating and shared-node balancing. Important commits include:

- `3270f9dbcba6c8b9cba5623422979acda05eaced` — Bump final shared scheduler installer to v1.7.1
- `a99ef76041fe46710b231bf207d4cd5081f211bf` — Make shared Iran profile explicit in install command
- `3de9523eebfdd5ae2d4cb447065eac5942e68d05` — Retry shared F5 health every 5 minutes within active window
- `d70e29ee6b625cd8f6885379fe2fa69180b8ac23` — Add isolated full XUDP health probe for every foreign node
- `f58b95e13d707f1c66ecbeee2f0117bebbfa9522` — Use health-gated round-robin group variants for true traffic distribution
- `1762c2ac76da1f26ff79e41c83dc30a2565f5806` — Gate every foreign node by multi-app health and select healthy round-robin subset
- `7150a09830cd895f85233cf69d4315fa921cd72d` — Install all-node health guard with shared-node scheduler
- `c07b539a5c402c10829bc734688f87858482693a` — Add no-restart live upgrade to health-gated round-robin
- `ea569ba53f4c38209b76525e9955f6acd6b5653a` — Bump AnyTLS health-gated balanced mode to v1.8.0
- `3a961123449fbaab12e0d6ef8c5315f7e8c3f568` — Document v1.8.0 health-gated round-robin behavior
- `6660a28dfca35c163bcdabdb136fdb6f1342fb18` — Pre-probe every foreign node before live health-gate upgrade

The key lesson from this generation was that connection-level round-robin could distribute traffic, but it did not preserve a stable per-user grouping and made controlled failover/load movement harder to reason about. That led to Bucket5.

---

## 4. Bucket5 design requirements

Production topology:

- Iran gateway 1: `maya1`
- Iran gateway 2: `maya3`
- five Foreign nodes: logical `F1..F5`
- about 300 total x-ui users, roughly 150 per Iran gateway
- 10 stable local buckets on each Iran gateway

Required behavior:

- Each active x-ui user is assigned to one stable bucket.
- User assignment does not change just because Foreign load or health changes.
- Bucket→Foreign target can move dynamically.
- With all 5 Foreign nodes healthy, target exactly 2 buckets per Foreign per Iran gateway.
- Health has priority over load optimization.
- If one Foreign fails, all its buckets leave it immediately and spread over healthy nodes.
- With ~300 users and only 4 healthy Foreign nodes, the old desired cap of <=60 users per Foreign is mathematically impossible; availability takes priority.
- When the failed node recovers, restore healthy 2-buckets-per-node distribution gradually rather than moving everything at once.
- Load optimization should use bucket swaps so the node bucket quota remains balanced.
- Only connections of moved buckets should be drained; unrelated users should remain untouched.

---

## 5. Current Bucket5 data path

The current model is stable user→bucket routing followed by dynamic bucket→Foreign selection:

```text
                         public x-ui :443
                               |
                     VLESS/REALITY inbound
                               |
                     route by client email
                               |
       +-----------+-----------+-----------+ ... 10 buckets
       |           |           |
      B01         B02         B03
       |           |           |
   x-ui SOCKS  x-ui SOCKS  x-ui SOCKS
       |           |           |
    18101       18102       18103        ... 18110
       |           |           |
       +---- Xray XUDP multi-path bridge ----+
       |           |           |
     7901        7902        7903          ... 7910
       |           |           |
   Mihomo      Mihomo      Mihomo
 selector     selector     selector
 BUCKET-01    BUCKET-02    BUCKET-03
       \           |            /
        +------ F1..F5 --------+
```

Current port model on each Iran gateway:

- `7890`: legacy Mihomo carrier listener
- `7891`: legacy XUDP SOCKS listener
- `7901..7910`: ten Mihomo bucket carrier SOCKS listeners
- `18101..18110`: ten dedicated XUDP SOCKS bucket listeners used by x-ui routing
- controller: loopback port from `deploy.env`
- x-ui public inbound remains TCP/443

**18101..18110 is canonical.** References to 8101..8110 are historical/stale unless reviewing an old commit.

How user identity is preserved:

1. `bucket5-xui.py` reads active x-ui clients.
2. Every active client must have a unique non-empty email, because Xray routing `rules.user` uses that email identity.
3. A persistent user→bucket mapping is maintained in `/var/lib/anytls-tunnel/bucket5-users.json`.
4. Existing mapped users stay in their bucket; new users are assigned to a least-populated bucket through reconcile.
5. x-ui gets ten loopback SOCKS outbounds corresponding to XUDP bucket ports.
6. No public UUID is changed.

---

## 6. Actual current five-node transport topology

The current topology is defined by the **fresh/resume runtime wrappers**, not the stale base installer declaration:

| Node | Transport | Default cover in fresh wrapper | Foreign role |
|---|---|---|---|
| F1 | AnyTLS + ShadowTLS v3 | Cloudflare | `foreign-a` |
| F2 | AnyTLS + ShadowTLS v3 | Microsoft | `foreign-a` |
| F3 | AnyTLS + ShadowTLS v3 | Cloudflare | `foreign-a` |
| F4 | AnyTLS + ResTLS | Microsoft | `foreign-b` |
| F5 | AnyTLS + ResTLS | Cloudflare | `foreign-b` |

The cover choices intentionally alternate independently from the transport type.

Historical IP observations (volatile, not canonical configuration):

- F1 observed: `194.77.69.57`
- F2 observed: `194.77.69.58`
- F3 observed: `194.77.69.59`
- F5 observed: `194.77.69.56`

F4 had several generations:

- an earlier F4 was observed at `194.77.69.51`; an early failure there was eventually proven to be a wrong ResTLS password, not filtering.
- the later incident F4 was `194.77.69.60`, host `s4-1`; it worked in production, then developed intermittent flow-specific failures.
- a replacement F4 was provisioned successfully on 2026-09-17. Its current IP was intentionally not copied into this history because live `/etc/anytls-tunnel/bucket5.env` is the source of truth and the IP was not captured in the final conversation state.

Foreign logs/captures showed Iran public IPs `94.184.4.38` and `5.10.248.50`; do not assume which one is maya1 or maya3 without live verification.

---

## 7. Bucket5 commit chronology

Core Bucket5 lineage, oldest→newest for the major production milestones:

- `f3c40ad9b3793721ff26b51512580ab85fcb86ad` — Add Bucket5 Mihomo and XUDP renderer
- `ca07544dd5dd20655f26f2f97c365f008dd63e52` — Add stable x-ui user to bucket routing
- `42d560fa26775195b1665e6564f3280bc54b91bf` — Add isolated full probe for each Bucket5 Foreign node
- `c5eb4a76d005b843cf00e3d626c4126949221506` — Add health-aware Bucket5 traffic scheduler
- `36ef30e4693d56881d6889a3a0f6031d8ba21acc` — Add safe live installer for five-node Bucket5 mode
- `5ab89a2ddc0db01ff63865fbe57efdefc5201c33` — Add Bucket5 user reconcile helper
- `c2d018c093272d1e6f02f13e407a13980b73ce22` — Add Bucket5 operational status helper
- `e9a4b5ded58a749e6cc68a670ce114498bfdbd76` — Bump Bucket5 architecture to v2.0.0
- `15c418bde51b556db034e8ef918c7e765b4ae986` — Add Bucket5 v2 production runbook
- `28f0e0557f058cb3a42de3671291b2525067cf28` — Harden Bucket5 load accounting with listener metadata
- `3d4793b84e00a636a6069823caef9758a098cc59` — Add fresh-five wrapper for all-new Foreign nodes
- `2af09051bceb9f723c8fce7c3b6e1142a2915a99` — Bump Bucket5 fresh-five release to 2.0.1
- `2da8621168600fa188cbe8a47b785eeb2b5c7308` — Match fresh Bucket5 installer to 3 ShadowTLS + 2 ResTLS topology
- `99c45b853266012146477a1b1d23409a470a9789` — Bump Bucket5 version for actual five-node transport topology
- `c1234e65d398c78888e3336c41c4268ac1419dac` — Use dynamic free ports for Bucket5 isolated probes
- `a1d9ce9778e7e56c4e2b783e0457a9348f573a96` — Bump Bucket5 version for dynamic probe ports
- `38eb5138929763fc058d58671069f80dbff9942f` — Add isolated carrier-vs-XUDP node diagnostic
- `9883ef3ab3b0883759c6971c24243180cab4b978` — Bump version for node diagnostic
- `edbbcffe940c552cf1f90ab595deecc1c2ee0581` — Fix Bucket5 candidate validation temp permissions
- `d819e74ab7d4df6a31134663c6934150132832eb` — Bump Bucket5 to 2.0.5
- `fc9960e23b1c9fd8ae31b9cc3d3e4405d1de5e31` — Add runtime hardening for Bucket5 listener activation
- `b11d949eef66e87d400e7782be36f5d26c7bd75e` — Harden Bucket5 runtime activation and rollback
- `04357332d92c667ec8742e2c1054e7bfe7cb30de` — Use hardened runtime activation in fresh Bucket5 installs
- `a27b07fdd0fbc1ecbea6cfd2322aeb64e6f8dbc6` — Add safe Bucket5 resume installer using saved verified credentials
- `068ae9562d60360363471f631175b9d677c60fc3` — Bump Bucket5 to v2.0.6
- `e2f5170cf94e76d87ec8d3b04aa41822a0660f66` — Bucket5: move XUDP bucket listeners to dedicated 18101 range
- `5dff0343e5a11ae67ed24588e1aa7fa661978a44` — Bucket5: use dedicated 18101 XUDP bucket range
- `0108eef763fad75eb2f037dd0ab9cf9dcd06da3b` — Bucket5: preflight real XUDP start and harden activation
- `de6cd6735a84eee04c1117dcec5dc070d362dfcf` — Bucket5: bump version to 2.0.7

Documentation-only commits after that may exist; check current branch HEAD before work.

---

## 8. Current important repo files and verified SHAs at cutoff

- `VERSION`: 2.0.7, blob `f1547e6d13417c452a8d34bf74026c26dd9fe339`
- `bucket5-render.py`: `1adaadea2e8e59581beb43aa43dbbba24ca81d62`
- `bucket5-xui.py`: `4025f4019d7b9d9991a8b3084993015854bd787e`
- `bucket5-scheduler.py`: `545c421ff9633bc93fb8ade116cde6ebea3cd61d`
- `bucket5-probe.sh`: `a144349638df91a04999bae9f5776849c72be83d`
- `bucket5-diagnose-node.sh`: `cd2dea789a11fcbc53bcdd5f186c9f19ce2bbf0d`
- `bucket5-reconcile.sh`: `08cf47065c51ea62422914f4e7bc17b3124f6567`
- `bucket5-status.sh`: `f910a8fb52c33ce9506d94a8a2d4872ea032adb5`
- `bucket5-runtime-patch.py`: `57e4c300646b1d8be97d815c05152a732a372301`
- `install-bucket5-fresh.sh`: `84e155e88f716d7cf87354d9acebfb435fbb99a4`
- `install-bucket5-resume.sh`: `0d48bfe547aca7d619f55a99268d908c3d0b0d38`
- `install-bucket5.sh`: `f07d1c328358aef69cbab86a3780d308cdcc27d6`
- `setup-final.sh`: `b9f0e2d85985b9bd5075e64a02525b6a15b47169`

Important: SHAs are historical anchors. Always fetch current SHAs before editing.

---

## 9. Why the base installer is not canonical

`install-bucket5.sh` contains older assumptions in its literal source. The current wrappers are what made v2.0.7 production-safe:

- `install-bucket5-fresh.sh` deliberately ignores old Foreign addresses/credentials and prompts for all five.
- it transforms topology to F1/F2/F3=ShadowTLS and F4/F5=ResTLS.
- it applies `bucket5-runtime-patch.py` before running the temporary installer.
- `install-bucket5-resume.sh` validates and reuses saved `/etc/anytls-tunnel/bucket5.env`, checks that topology is F1/F2/F3 shadow + F4/F5 restls, applies runtime patch, then proceeds.

The runtime patch was necessary because several production failures exposed weaknesses in the original activation sequence.

---

## 10. Installer failures and fixes that must not be reintroduced

### 10.1 False candidate invalid — temp directory permissions

Symptom: Mihomo candidate validation failed even though the generated YAML was valid.

Root cause: temporary directory ancestry was root-only (`0700`), so validation executed as service user could not traverse into the candidate file.

Fix: grant safe traverse/group permissions for candidate validation while keeping secret files locked down. Associated commit: `edbbcffe...` and later hardening.

### 10.2 Mihomo listener topology not reliably updated by API reload

Symptom: config reload returned success but required listeners such as 7890/7901..7910 were not actually present.

Root cause: controller config reload was not reliable enough for listener topology mutation.

Fix: runtime hardening uses a controlled `systemctl restart anytls-tunnel` for topology activation/rollback, followed by explicit listener checks. Associated commits: `fc9960e...`, `b11d949...`, wrapper integration.

### 10.3 Xray `run -test` does not prove runtime bind

Symptom: candidate XUDP config passed syntax validation but production activation later exposed collisions/bind problems.

Root cause: `xray run -test` parses configuration; it does not prove the process can bind all listeners and remain running.

Fix: v2.0.7 preflight actually launches a temporary XUDP candidate on isolated/free ports, confirms listeners, then tears it down before production cutover.

### 10.4 XUDP bucket port range collision/ambiguity

Older design used 8101..8110. That was replaced with dedicated range 18101..18110 to avoid collisions and make validation safer.

Fix commits: `e2f5170...`, `5dff034...`.

### 10.5 Probe port conflicts

Fixed by allocating dynamic free ports for isolated Mihomo/Xray probes (`c1234e65...`).

---

## 11. Full isolated probe semantics

`bucket5-probe.sh` is the authoritative recovery/candidate test. It intentionally exercises more than raw reachability.

For a node F# it:

1. checks raw TCP/443 reachability,
2. launches a temporary isolated Mihomo instance using that node's AnyTLS + ShadowTLS/ResTLS credentials,
3. launches an isolated Xray XUDP bridge using the deployment's XUDP UUID and Foreign loopback port 2443,
4. tests through the XUDP path:
   - `https://www.gstatic.com/generate_204` must return 204,
   - YouTube must return an accepted 2xx/3xx/4xx code,
   - ytimg accepted 2xx/3xx/4xx (404 is valid),
   - Instagram accepted 2xx/3xx/4xx,
5. performs a sustained 1 MB transfer (must transfer at least 750k),
6. performs UDP DNS round trip through XUDP to 1.1.1.1,
7. only then reports PASS.

Dynamic probe ports prevent collisions with production listeners.

`bucket5-diagnose-node.sh` was added later to isolate the failure layer:

1. raw TCP/443,
2. direct AnyTLS outer carrier **without XUDP**,
3. XUDP/full path.

This distinction was critical during the F4 incident.

---

## 12. Scheduler behavior at cutoff

`bucket5-scheduler.py` current constants:

```text
FAIL_THRESHOLD=2
RECOVER_QUICK_THRESHOLD=2
MOVE_COOLDOWN=600
MIN_SWAP_DIFF_BPS=500000
MIN_SWAP_RATIO=1.8
```

### Quick health

For each `F1..F5`, every scheduler run asks the local Mihomo controller for delay tests through that exact proxy:

- gstatic generate_204, expected 204,
- YouTube, expected 200–499,
- Instagram, expected 200–499.

The quick test is an AND: all three must pass.

### Healthy→unhealthy

- first failed quick health increments `fail_count`,
- two consecutive failures marks node unhealthy,
- all buckets currently targeting it are immediately moved to healthy nodes,
- health failover is not held by the normal 600s load-move cooldown.

### Unhealthy→healthy

- node must first pass quick health twice consecutively,
- then `anytls-bucket5-probe F#` must pass full isolated test,
- only then is it restored healthy.

### Bucket failover target selection

Scheduler prefers:

1. fewer buckets,
2. lower observed traffic,
3. lower active connections,
4. profile-specific deterministic tiebreak order.

### Return to normal quota

When all five nodes are healthy, scheduler gradually restores exactly 2 buckets/node, one movement at a time under the move cooldown.

### Load balancing

Only when:

- all 5 healthy,
- each node already has exactly 2 buckets,
- valid byte-delta sampling exists,
- cooldown permits a move.

It calculates node traffic from `/connections`, finds highest/lowest load, and may swap the hottest bucket from the high node with the coolest bucket from the low node if:

- bandwidth difference >=500,000 B/s,
- ratio >=1.8,
- predicted swap improves imbalance by at least 25%.

Only connections belonging to moved buckets are deleted/drained so clients reconnect through the new target.

### State

Persistent state:

`/var/lib/anytls-tunnel/bucket5-state.json`

Includes mapping, per-node health/fail/recover counters, last move/sample, previous connection byte counters, last bucket B/s, and active counts.

---

## 13. Maya1 production migration result

Maya1 successfully migrated to Bucket5 v2.0.7 after installer/runtime fixes.

Verified install sequence included:

- all five Foreign nodes passed full isolated pre-probe,
- dedicated XUDP ports 18101..18110 were checked free,
- actual temporary XUDP candidate start succeeded,
- controlled Mihomo activation succeeded,
- selectors initialized,
- XUDP bridge activated,
- all 10 bucket paths smoke-tested,
- x-ui stable user routing verified,
- scheduler installed and enabled.

Initial Maya1 mapping contained 147 users:

- BUCKET-1..BUCKET-7: 15 users each,
- BUCKET-8..BUCKET-10: 14 users each.

One healthy production snapshot showed active connections approximately:

- F1 87
- F2 65
- F3 70
- F4 54
- F5 85
- total 361

Traffic byte-delta sampling became non-zero and usable.

---

## 14. Maya3 production migration result

Maya3 also successfully migrated.

Initial user distribution was 152 users:

- B1 16
- B2 16
- B3..B10 15 each.

Scheduler traffic sampling eventually showed real non-zero load. A real load-balancing action occurred:

```text
LOAD SWAP: BUCKET-09 F5->F4, BUCKET-08 F4->F5
```

The scheduler drained 37 existing connections for each moved bucket. Resulting mapping at that point:

```text
B1/B2  -> F1
B3/B4  -> F2
B5/B6  -> F3
B7/B9  -> F4
B8/B10 -> F5
```

This proved that load sampling, bucket swaps, mapping persistence, and controlled drains worked in production.

---

## 15. Early F4 credential incident — not filtering

Before the later network incident, an earlier F4 setup failed. Hash comparison proved:

- AnyTLS credential entered on Maya matched the actual F4 server value,
- ResTLS credential did **not** match.

After correcting the ResTLS password, the node passed.

Lesson: do not label a failed carrier as filtering before credential identity is proven. Never paste secrets; compare hashes.

---

## 16. Major F4 incident — 2026-09-17

### 16.1 First observed scheduler state

After about a day of production, F4 was marked unhealthy and had zero user traffic. Example active connection snapshot:

```text
F1 63
F2 115
F3 73
F4 0
F5 78
total 329
```

Scheduler health:

- F1 true
- F2 true
- F3 true
- F4 false
- F5 true

F4's buckets had been redistributed across the other four nodes. Example mapping count after failover was approximately:

```text
F1=2 buckets
F2=3
F3=3
F4=0
F5=2
```

This was correct failover behavior: users stayed operational while F4 was quarantined.

### 16.2 F4 server itself looked healthy

Old incident F4: `194.77.69.60`, hostname observed `s4-1`.

On F4:

- `anytls-tunnel` active,
- `anytls-xudp-bridge` active,
- AnyTLS listening publicly on TCP/443,
- XUDP listening loopback-only on 127.0.0.1:2443,
- server outbound HTTPS to Microsoft returned HTTP 200.

F4's Mihomo logs also contained incoming connections from both observed Iran IPs to gstatic/YouTube and even to `127.0.0.1:2443`.

Therefore this was not a simple “server is down” failure.

### 16.3 Quick health failed on both Maya gateways

Direct controller delay tests for F4 on both Maya servers produced:

- gstatic: 503 / delay-test error,
- YouTube: 504 timeout,
- Instagram: 503 / delay-test error.

Therefore it was not merely YouTube/Instagram being independently inaccessible.

### 16.4 Full isolated probe failed on both Maya gateways

Both Maya gateways showed:

```text
raw TCP/443 = OK
full probe gstatic = HTTP 000 / receive failure
```

So F4's IP:443 accepted TCP, but usable tunneled traffic failed.

### 16.5 Carrier-vs-XUDP diagnostic isolated the fault before XUDP

`bucket5-diagnose-node.sh F4` output:

- stage 1 raw TCP/443: OK,
- stage 2 direct AnyTLS/ResTLS carrier, NO XUDP: failed repeatedly,
  - SSL connection timeout,
  - OpenSSL `SSL_ERROR_SYSCALL`,
  - HTTP 000,
- final: `DIRECT CARRIER FAILED before XUDP`.

This conclusively removed XUDP from the root-cause path.

### 16.6 Restarting old F4 did not fix it

`anytls-tunnel` was restarted on old F4. It returned cleanly and logged:

`AnyTLS[anytls-restls] proxy listening at: [::]:443`

But isolated full probe still failed immediately afterward.

Therefore the incident was not a stuck Mihomo process/session state.

---

## 17. Was F4 filtered because it carried more traffic?

Scheduler history was analyzed from before the first F4 DOWN event.

Measured historical load:

| Node | avg Mbps | max Mbps | p95 Mbps | avg conn | max conn |
|---|---:|---:|---:|---:|---:|
| F1 | 2.89 | 15.0 | 6.8 | 56.3 | 156 |
| F2 | 3.23 | 60.1 | 9.9 | 66.5 | 191 |
| F3 | 2.66 | 30.7 | 6.7 | 51.6 | 170 |
| F4 | 2.84 | 17.1 | 7.1 | 63.0 | 279 |
| F5 | 2.69 | 19.9 | 6.8 | 54.4 | 150 |

F4 max connections:

- 279 at 2026-09-16 11:11:16
- bandwidth then only 6.9 Mbps

F4 max bandwidth:

- 17.1 Mbps at 2026-09-16 20:26:05
- 85 connections

First F4 DOWN:

- 2026-09-16 22:34:57

Last 15 scheduler samples before failure:

```text
22:19  7.8 Mbps  50 conn  UP
22:20  5.5       70       UP
22:21 15.0       75       UP
22:22  3.9       86       UP
22:23  7.3       65       UP
22:24 15.2       64       UP
22:25  0.6       51       UP
22:26  8.6       66       UP
22:27  5.0       67       UP
22:28  6.9       61       UP
22:29  5.9       60       UP
22:30  2.8       59       UP
22:31  3.0       46       UP
22:32  3.5       44       UP
22:33  2.5       50       UP
22:34  0.0        0       DOWN
```

Conclusion with high confidence:

- bandwidth was not abnormally high,
- F4 was not the highest average bandwidth node,
- F2 had a far higher max bandwidth,
- the 279-connection spike happened more than 11 hours before failure,
- just before DOWN, F4 load was ordinary.

So “F4 was filtered because it had more traffic” is **not supported by the available data**. Connection/session churn can remain an experimental variable, but no causal evidence was found.

---

## 18. Replacement F4 operation

A replacement F4 was provisioned as `foreign-b` and successfully completed:

```text
setup-final.sh foreign-b
anytls-final-health
```

Observed final health on the replacement:

- anytls-tunnel active + enabled,
- anytls-xudp-bridge active + enabled,
- AnyTLS listening TCP/443,
- XUDP loopback-only on 2443,
- Mihomo binary present,
- FINAL HEALTH = OK,
- `SUCCESS: AnyTLS Tunnel FINAL v1.6.0 role=foreign-b installed and healthy`.

A one-off safe F4 replacement procedure was then used on the first Iran gateway. Its design:

1. prompt for new F4 address/cover/AnyTLS/ResTLS secrets without echoing secrets,
2. build a temporary `bucket5.env` containing only the new F4 values,
3. run `BUCKET5_ENV=temp anytls-bucket5-probe F4` **before production mutation**,
4. read the existing XUDP UUID locally (never print it) and render a candidate Bucket5 config,
5. validate candidate Mihomo config,
6. back up `bucket5.env`, `config.yaml`, and scheduler state,
7. temporarily stop scheduler,
8. replace only F4's configuration,
9. perform one controlled Mihomo restart,
10. verify legacy + 10 bucket listeners,
11. restart scheduler and run it to begin recovery,
12. run final isolated F4 probe,
13. rollback automatically if anything fails.

The operation deliberately did **not** restart x-ui, did **not** restart XUDP, and did **not** change user→bucket mapping.

The user reported successful install and a healthy F4 afterward.

**Important current uncertainty:** the conversation conclusively confirms this replacement procedure on the first Maya where it was run (the instructions explicitly said “first only maya1”). It does **not** conclusively record that maya3 was subsequently updated. Future session must verify both gateways before assuming they point to the same current F4.

---

## 19. Post-replacement healthy snapshot

One confirmed snapshot after new F4 activation on the updated Maya showed 147 users:

```text
BUCKET-1  15
BUCKET-2  15
BUCKET-3  15
BUCKET-4  15
BUCKET-5  15
BUCKET-6  15
BUCKET-7  15
BUCKET-8  14
BUCKET-9  14
BUCKET-10 14
```

Mapping at that moment:

```text
BUCKET-01 -> F1
BUCKET-02 -> F3
BUCKET-03 -> F5
BUCKET-04 -> F5
BUCKET-05 -> F2
BUCKET-06 -> F5
BUCKET-07 -> F1
BUCKET-08 -> F2
BUCKET-09 -> F4
BUCKET-10 -> F3
```

Mihomo node delay snapshot:

```text
F1 ~168 ms
F2 ~418 ms
F3 ~162 ms
F4 ~422 ms
F5 ~179 ms
```

Active connection snapshot:

```text
F1 44
F2 29
F3 54
F4 12
F5 83
total 222
```

Scheduler health was true for all five nodes. F4 had only one bucket at that instant because recovery redistribution is gradual under the scheduler cooldown. This snapshot is historical, not a current-state promise.

---

## 20. Old F4 became intermittently usable again

After replacement, the saved pre-replacement F4 environment from `/var/lib/anytls-tunnel/backups/f4-replace-*/bucket5.env` was used to probe the old F4 in isolation without touching production.

Important result: old F4 was **intermittent**, not permanently hard-blocked.

One probe around 14:36 passed completely:

- raw TCP/443 OK,
- gstatic 204,
- YouTube 200,
- ytimg 404,
- Instagram 200,
- 1 MB transfer succeeded in ~0.316s,
- UDP/XUDP DNS OK.

Minutes later another probe failed again at gstatic with SSL timeout / HTTP 000.

Therefore old `194.77.69.60` was not permanently denied at the IP level. The failure depended on flow/time/state.

---

## 21. Dual-ended tcpdump forensic result — most important network evidence

A synchronized capture was taken on:

- Maya side: `94.184.4.38`
- old F4 side: `194.77.69.60`
- same TCP flow source port: `43476`

The exact sequence numbers and ports prove both captures describe the same flow.

### 21.1 What worked

TCP 3-way handshake succeeded.

Maya sent the initial ~517-byte TLS/transport flight; F4 received it and acknowledged to seq 518.

F4 then sent approximately 8.8 KB of response data; Maya received and acknowledged it.

Maya next sent 80 + 332 bytes; F4 received those and ACK advanced to 930.

Both directions continued carrying data successfully until roughly:

- Maya sequence reached 2777,
- F4 sequence reached 13335.

### 21.2 Where failure began

On Maya's NIC, additional **payload-bearing** packets were visibly transmitted after seq 2777, including chunks around:

- 26 bytes,
- 830 bytes,
- 919 bytes,
- 761 bytes,
- plus retransmissions.

However, in the simultaneous old-F4-side capture, those post-2777 Maya payload packets **never appeared at the F4 NIC**.

F4 remained stuck acknowledging Maya only up to seq 2777.

At the same time, F4→Maya direction was still alive: F4 repeatedly sent its seq 13335:13460 payload, Maya received it and sent ACK/SACK responses.

No injected TCP RST was observed.

### 21.3 What this rules out / weakens

Strongly inconsistent with:

- complete IP block,
- complete TCP/443 block,
- XUDP fault,
- crashed F4 service,
- a simple stuck Mihomo process,
- classic RST injection.

A simple MTU problem is also unlikely because small payload packets were among those lost while much larger packets had already passed.

Traffic volume as a trigger is unsupported by the historical load data.

### 21.4 Best interpretation at cutoff

High-confidence observation:

> After an initially successful TCP/TLS exchange, payload-bearing Maya→F4 traffic for a live flow can be silently discarded somewhere between the Maya NIC and the F4 NIC, while some reverse traffic and ACK-only traffic continue to pass.

This is an **asymmetric, stateful / flow-specific silent drop**.

Possible locations/causes include:

- stateful DPI/filtering on the Iran-side path,
- a transit middlebox,
- destination/provider anti-DDoS or traffic classification,
- another stateful path device.

Do **not** call it “definitely Iranian DPI” yet. The capture proves the packet disappears in-network, but does not identify which administrative network drops it.

Simple ECMP/path failure is less convincing because the same 5-tuple initially succeeds and then selective payload disappears, but it has not been mathematically eliminated.

Best future localization test:

- repeatedly test old F4 from one or more Foreign VPSes,
- compare success/failure rate with both Maya gateways,
- if Foreign→old-F4 is stable while both Iran→old-F4 show the same intermittent silent drop, the evidence shifts strongly toward Iran-side/path filtering.

---

## 22. Current conclusions by confidence

### High confidence

- Bucket5 stable user routing and bucket failover work in production.
- F4 incident was not a complete IP/443 outage.
- XUDP was not the cause of the major F4 carrier failure.
- The old F4 process being stuck was not the cause; restart did not fix it.
- F4's bandwidth was not anomalously high before failure.
- Old F4 later became intermittently usable again.
- During a captured failing flow, post-handshake Maya→F4 payload left Maya but did not reach F4 NIC.
- No classic RST injection was observed in that capture.

### Medium confidence

- A stateful middlebox/classifier is a better explanation than simple routing loss.
- Protocol/flow fingerprint may matter because the failure begins after an initial successful exchange.
- Having transport diversity on the same logical Foreign node may reduce the blast radius if filtering is transport-specific rather than IP-wide.

### Unknown / not yet proven

- whether the dropping middlebox is inside an Iranian network, transit, or Foreign provider infrastructure,
- whether ResTLS specifically is being classified,
- whether ShadowTLS on the same old F4 IP would remain reliable when ResTLS fails,
- whether fixed/periodic transport rotation reduces failure probability,
- whether session churn contributes materially,
- whether Maya3 has already been updated to the replacement F4.

---

## 23. Current operational commands

Common safe read/test operations:

```bash
sudo anytls-bucket5-status
```

```bash
sudo anytls-bucket5-probe F1
sudo anytls-bucket5-probe F2
sudo anytls-bucket5-probe F3
sudo anytls-bucket5-probe F4
sudo anytls-bucket5-probe F5
```

```bash
sudo anytls-bucket5-diagnose F4
# or the installed diagnose helper name if it differs; verify /usr/local/sbin before use
```

Scheduler logs:

```bash
journalctl -u anytls-bucket5-scheduler.service -n 100 --no-pager
```

After intentionally adding/removing/changing x-ui users:

```bash
sudo anytls-bucket5-reconcile
```

Reconcile is **not** a Foreign-node replacement command. It performs a controlled x-ui restart because it updates stable user→bucket routing.

---

## 24. Config/state locations

On Iran gateways:

- repo checkout: `/opt/anytls-tunnel`
- deploy environment: `/etc/anytls-tunnel/deploy.env`
- Bucket5 node env: `/etc/anytls-tunnel/bucket5.env`
- Mihomo config: `/etc/anytls-tunnel/config.yaml`
- XUDP bridge config: `/etc/anytls-tunnel/xudp-bridge.json`
- user→bucket map: `/var/lib/anytls-tunnel/bucket5-users.json`
- scheduler state: `/var/lib/anytls-tunnel/bucket5-state.json`
- backups: `/var/lib/anytls-tunnel/backups/`
- x-ui DB: `/etc/x-ui/x-ui.db`
- x-ui runtime config observed at `/usr/local/x-ui/bin/config.json`

Important services:

- `x-ui`
- `anytls-tunnel`
- `anytls-xudp-bridge`
- `anytls-bucket5-scheduler.timer`
- `anytls-bucket5-scheduler.service`

On Foreign nodes:

- AnyTLS public listener: TCP/443 in current single-transport design
- XUDP endpoint: `127.0.0.1:2443`
- role env historically under `/root/anytls-foreign-a.env` or `/root/anytls-foreign-b.env`

---

## 25. Next-generation idea: logical node with multiple transports

This is the most important design direction discussed at the end of the session. **It is not implemented yet.**

Observation motivating it:

- old F4's IP remained TCP-reachable,
- some flows even passed completely,
- failing flows were silently dropped after an initial exchange,
- therefore a different outer transport on the same IP may remain usable if classification is transport-specific.

Proposed logical F4 model:

```text
                        logical F4
                            |
                    transport selector
                     /              \
          F4-RESTLS :443       F4-SHADOW :8443
                     \              /
                      \            /
                   same Foreign host
                            |
                  XUDP 127.0.0.1:2443
```

Key principle: do **not** have the Foreign server unilaterally mutate port 443 and expect Maya to guess the new protocol. Both sides must have pre-provisioned matching carriers.

On Maya, buckets continue to target logical `F4`; an internal transport selector chooses the currently active F4 carrier. That preserves:

- user UUIDs,
- x-ui public inbound,
- user→bucket mapping,
- bucket→logical-node mapping,
- F1/F2/F3/F5 state.

### Proposed transport-failover policy

1. Current carrier has quick failures.
2. Probe backup carrier in isolation.
3. If backup full/light health passes, switch F4 internal selector to backup.
4. Stop new F4 connections on old carrier and drain only remaining F4 old-carrier connections.
5. Keep logical F4 `healthy=true`; do **not** redistribute F4 buckets.
6. Only if all F4 carriers fail, mark logical F4 unhealthy and invoke existing Bucket5 node failover.

### Recovery / anti-flap

Do not immediately switch back when the original carrier briefly recovers. Use hysteresis/sticky selection, e.g. remain on backup until a longer stability period or until backup itself fails.

State may evolve to something like:

```json
{
  "F4": {
    "node_health": true,
    "active_transport": "shadow",
    "transports": {
      "restls": {"healthy": false},
      "shadow": {"healthy": true}
    }
  }
}
```

Do not implement this schema blindly; design a backward-compatible scheduler state migration first.

---

## 26. Periodic / randomized transport hopping idea

The user then proposed proactively changing the transport approximately every 6 hours so one transport fingerprint is not used continuously.

This is also **not implemented yet**.

A safer proposed policy than blind fixed 6-hour rotation:

- multiple carriers are always pre-provisioned,
- health-first: if current carrier fails, attempt backup immediately rather than waiting for a timer,
- before a scheduled rotation, probe the destination carrier,
- if destination carrier is unhealthy, do not switch,
- use randomized dwell rather than a rigid 6-hour signature, e.g. minimum 3h / maximum 8h,
- after a failover, use sticky/hysteresis behavior to avoid flapping,
- stagger rotations across F1..F5 so many users do not reconnect simultaneously,
- drain only connections belonging to the logical node whose transport changes.

A fixed 6-hour schedule may reduce continuous exposure to one carrier, but it cannot prevent a DPI that classifies a flow within seconds. The real benefit is **transport diversity + fast failover**, not the timer by itself.

Potential future transport set:

- AnyTLS + ResTLS
- AnyTLS + ShadowTLS v3
- possibly JLS later, only after isolated compatibility tests

Start with two carriers; do not add a third before the two-carrier state machine is proven.

---

## 27. Recommended A/B research before deploying transport hopping

Use the retired/old F4 as a canary where possible. It has no production bucket requirement and already exhibited the failure.

Test one variable at a time, multiple repetitions (for example 20–50 isolated attempts):

- ResTLS TLS13 + current cover
- ResTLS TLS13 + different cover
- ResTLS TLS12 + same cover (if current stack supports it end-to-end)
- ShadowTLS v3 on the same old F4 IP

Record:

- raw TCP result,
- carrier handshake result,
- gstatic result,
- full-probe result,
- latency,
- failure stage,
- timestamp,
- source gateway.

Interpretation examples:

- If ResTLS variants fail frequently but ShadowTLS on same IP is stable, transport-aware failover is strongly justified.
- If every transport on the old IP has similar intermittent failure, IP/path/provider reputation is more likely than one protocol fingerprint.
- If Foreign→old-F4 is stable but both Maya→old-F4 fail intermittently, Iran-side/path filtering becomes much more likely.

---

## 28. Scheduler improvements discussed but not yet implemented

Potential next changes, to be evaluated rather than blindly committed:

1. Per-test health logging instead of collapsing quick health to one boolean. Log `GSTATIC/YOUTUBE/INSTAGRAM` results separately.
2. More explicit failure reasons: `TCP_FAIL`, `CARRIER_FAIL`, `APP_FAIL`, `XUDP_FAIL`, `UDP_FAIL`.
3. For a currently unhealthy node, consider periodic full isolated probe even if a single quick app endpoint fails, so a flaky quick endpoint cannot permanently quarantine an otherwise healthy transport. This was a concern during early diagnosis, though the F4 incident ultimately proved a real carrier failure.
4. Stronger recovery hysteresis to prevent flapping.
5. Transport-level health beneath logical-node health.
6. Backward-compatible scheduler state version bump if adding transport state.
7. Metrics/history persistence for node bandwidth, connection count, transport success rate, and failure stage.

Any scheduler modification must preserve current immediate node failover behavior until the new transport layer is proven.

---

## 29. What must be verified at the start of the next session

Before writing code or giving live mutation commands:

1. Fetch GitHub `bucket5-v2` current HEAD and `VERSION`.
2. Fetch current `bucket5-render.py`, `bucket5-scheduler.py`, `bucket5-probe.sh`, `bucket5-runtime-patch.py`, fresh/resume wrappers and exact SHAs.
3. On **maya1 and maya3**, ask for or obtain:
   - `sudo anytls-bucket5-status`
   - service states
   - current F4 address/type/cover without printing secrets
   - full `sudo anytls-bucket5-probe F4` result if relevant.
4. Verify whether maya3 already points to the replacement F4. Do not assume it does.
5. Confirm F1..F5 current transport types from `/etc/anytls-tunnel/bucket5.env` on both Maya gateways.
6. Do not expose credentials.
7. If designing multi-transport, build and prove it first on the retired F4/canary before touching the healthy replacement F4.

---

## 30. Production safety checklist for any future deployment

Every production-affecting change should follow this order:

```text
1. current status / health snapshot
2. GitHub exact-file + SHA verification
3. local backup of every file/state that will change
4. render candidate config in isolated temp directory
5. syntax validation
6. real candidate process start where listener topology changes
7. isolated end-to-end probe
8. smallest possible live cutover
9. listener/service verification
10. end-to-end production smoke test
11. scheduler/state verification
12. automatic/manual rollback path retained
```

Never sacrifice production user continuity to “see if it works.”

---

## 31. Known stale / dangerous assumptions to avoid

Do not assume:

- F2 is ResTLS because an old runbook says so; current wrappers define F2 as ShadowTLS.
- F5 is ShadowTLS because an old file says so; current wrappers define F5 as ResTLS.
- Bucket XUDP ports are 8101..8110; current canonical range is 18101..18110.
- a raw TCP/443 PASS means a Foreign node is usable.
- `xray run -test` proves listeners can start.
- successful Mihomo controller reload means listener sockets changed correctly.
- an F4 outage means its IP is permanently filtered.
- an F4 outage was caused by high Mbps; historical data did not support that.
- maya3 has the same replacement F4 as maya1; verify.
- current IPs/latencies/user counts equal historical examples in this document.

---

## 32. Communication / operator preference

The user expects:

- Persian/Finglish communication,
- exact terminal-ready commands,
- no guesses based on memory when current repo/live state can be checked,
- minimal production downtime,
- explicit rollback behavior,
- no secrets pasted into chat,
- evidence-driven diagnosis before architecture changes.

When a change is complex, complete the design/repo patch first, validate it, then give concise production commands rather than sending a long chain of speculative terminal experiments.

---

## 33. Immediate continuation objective

The immediate next engineering topic at the end of the originating chat is:

> Design and validate **transport-aware logical-node failover**, then optionally health-aware randomized transport hopping, while preserving the existing Bucket5 user/bucket architecture.

Target concept:

```text
user -> stable bucket -> logical F# -> transport selector -> carrier A/B -> Foreign XUDP -> Internet
```

First implementation should likely focus on F4/canary with two transports (ResTLS and ShadowTLS) and only generalize to F1..F5 after measured proof.

Critical requirements:

- do not change x-ui UUIDs,
- do not remap users,
- do not disturb healthy F1/F2/F3/F5,
- candidate transport must be probed before switch,
- logical node should leave the pool only if all its transports fail,
- rotation, if added, must be health-aware and staggered,
- state migration must be backward-compatible,
- recovery must have hysteresis.

---

## 34. Final state at history cutoff

At the end of the originating chat:

- Bucket5 is live in production on maya1 and maya3.
- scheduler failover and load balancing have both been demonstrated.
- five-node health can return to all-true after replacement F4 on at least the updated gateway.
- old F4 `194.77.69.60` is retained/usable as a valuable intermittent-failure canary.
- the strongest forensic evidence points to an in-network stateful asymmetric silent drop for some old-F4 flows, not hard IP blocking or high-load exhaustion.
- no multi-transport failover or scheduled transport hopping code has yet been committed.
- `VERSION` remains 2.0.7 for production code at this cutoff.
- documentation added after this point should not be interpreted as a production code version bump.

Future sessions should continue from this state, verify live facts first, and treat this document as the historical continuity record.
