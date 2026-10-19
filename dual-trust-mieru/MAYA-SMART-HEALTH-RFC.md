# Maya Smart Health & Quota Controller — RFC v0.1

**Status:** Design only; NOT deployed, NOT tested on live hosts.
**Base branch:** \`triple-carrier-naive\`
**Target nodes:** Maya1 / Maya3 (each 2 vCPU, 4 GiB RAM), 3x-ui **v2.9.4 pinned**.
**Invariant:** Existing VLESS+REALITY TCP/443 client configs, UUIDs and public inbounds remain unchanged. No new client profiles.
**Intent:** Exclude failed foreign endpoints from user egress quickly; keep active checks low-noise; preserve quota and user availability. No nightly timing rotation.

## A. Topology

- Maya1 → F1 TrustTunnel TCP/H2/TLS; F2 Mieru over TCP; F5 shared Naive over TCP/H2/TLS.
- Maya3 → F3 TrustTunnel TCP/H2/TLS; F4 Mieru over TCP; F5 shared Naive, independently authenticated.
- F5 has one **global** consumption budget, not 100 GiB from each gateway.
- The two gateways manage their own user buckets but cooperate through the F5 capacity arbiter for its shared quota.
- Do not change Mieru production settings: \`MULTIPLEXING_OFF\`, \`HANDSHAKE_STANDARD\`, empty traffic pattern.
- Trust / Mieru TCP transport is distinct from UDP user payload carried by XUDP inside TCP; ordinary Iran→foreign UDP loss does not by itself prove these carriers are down.

## B. Why existing health is insufficient

- \`dual-health.sh\` performs an HTTP 204 check, Telegram check, and full-mode UDP DNS over SOCKS; healthy HTTP ≠ healthy user experience.
- Existing Mihomo dispatcher uses \`interval: 120\`, \`lazy: true\`, \`max-failed-times: 2\`, \`sticky-sessions\`.
- Existing \`dual-autoheal.sh\` (roughly 5-minute timer with jitter) restarts selectively failed local services; it does **not** manage authoritative quarantine when destination IP/path is censored.
- Existing \`lane3-pool.py\` edits \`dispatcher.yaml\` and restarts \`dual-dispatcher.service\` when joining/leaving Naive; unsuitable as repeated automatic failover actuator.
- Existing \`bucket5-scheduler.py\` elsewhere in the repo has per-user stable bucket concept and Mihomo selector API usage, but belongs to a different AnyTLS deployment and MUST NOT be installed on Dual Trust/Mieru.

## C. State machine per foreign path

\`HEALTHY\` → \`SUSPECT\` → \`QUARANTINED\` → \`PROBATION\` → \`HEALTHY\`.

- HEALTHY: accepts new traffic subject to capacity.
- SUSPECT: recent real user-flow failure signal; trigger bounded confirmatory tests promptly, temporarily prefer healthy peers for new sessions.
- QUARANTINED: no new user traffic, irrespective of a stale Mihomo 'alive' flag. A different foreign endpoint is selected; do not silently re-enable. Do not restart x-ui, the unaffected carrier or shared XUDP bridge.
- PROBATION: after isolated successful probes and minimum dwell, accept <=10% newly allocated load, watch errors and throughput; progressive 10%→30%→100% if stable.
- DRAINING: planned redistribution, no new sessions, allow old sessions to complete.
- CAPPED: quota/capacity exhausted; not synonymous with DOWN.
- UNKNOWN: controller cannot prove health; do not enable standby solely from an old 'green' result.

Persist state atomically; retain previous routing and an audit log. After controller restart, do not erase quarantine history.

## D. Health observation layers

1. Local: process up, CPU/RAM, file descriptors, listening SOCKS \`7991\` Trust / \`7992\` Mieru / \`7996\` Naive, dispatcher \`7990\`; local-only checks cause **zero foreign traffic**.
2. Carrier: actual SOCKS-through-path TCP/TLS request with a strict HTTP status and timeout. Validate on individual forced path, NOT solely unified \`7990\`.
3. Real user traffic: sliding-window dial failures, connection timeouts, stalled transfers, retransmits, flow duration (where observable) and application-level failures. Normalize noisy logs; avoid assuming all application HTTP errors are proxy failures.
4. Functional: two independent HTTPS destinations and a small bounded transfer via the forced path when in SUSPECT or recovery.
5. UDP/XUDP: SOCKS UDP ASSOCIATE + DNS response with validated transaction ID/destination on a forced path. Diagnose separately from TCP. If UDP fails but TCP works, set \`UDP_DEGRADED\` and isolate affected UDP traffic; do not eject TCP users blindly.
6. User ingress: public REALITY TCP/443 reachability, x-ui queue/CPU, TLS accept latency and internal xray→SOCKS errors on Maya, distinguishing ingress/local exhaustion from foreign block.

Do not label IP-level filtering solely from an HTTP 204 failure. Distinguish timeout, no route, HTTP host failure, failed TLS handshake, TCP carrier failure, backend/XUDP failure, and local overload.

## E. Low-noise probe policy — STARTING VALUES FOR A/B TEST

- HEALTHY active path: one small full-path HTTPS check about every 60–120 seconds with ±20% jitter, stagger across nodes/gateways. No simultaneous whole-pool probe storm.
- Idle F5: infrequent availability check about every 3 minutes; always run a just-in-time isolated confirmatory test before any failover admission.
- Triggered: evidence of repeated actual user-flow failures raises SUSPECT immediately; run two bounded independent confirmatory requests spaced a few seconds apart; stop if clear local resource problem explains the symptom.
- Eject target: approximately 10–25 seconds **when passive failure evidence exists**; if relying only on background probes, detection delay may be 60–120 seconds or more. This is a target to benchmark, not an SLA guarantee.
- If clearly QUARANTINED: exponential recovery probes at 2, 5, 15, then 30 minutes max, with per-node jitter and rate limit; do not hammer a blocked IP.
- Recovery: >=2 independent successful full-path probes separated in time, optionally with small transfer/UDP check; require >=10 minutes quarantine dwell before low-volume PROBATION; never immediate automatic return after a single 204 response.
- Configure Mihomo's own health behavior to avoid duplicated, competing active probes. Log number of probes/day and their bytes.

Frequent checks are not automatically evidence of detection by DPI; deterministic repetitive activity can be an avoidable signal. Favor passive telemetry + event-triggered probes over multi-target continuous synthetic traffic.

## F. Pool actuation without service restarts

- Before activation, deploy a tested stable Xray user/bucket route → loopback Mihomo **selector** for each bucket; requires one controlled migration with backups and rollback.
- Each bucket selector lists only its gateway's own 2 foreign nodes and shared F5.
- Use local authenticated Mihomo Controller API \`PUT /proxies/<bucket>\` for switching; verify \`GET /proxies/<bucket>\` read-back. This is supported for Selector groups; do NOT assume a load-balance group accepts PUT selection.
- Quarantine a node globally in controller state: reassign **all** buckets pointing to it; never trust a stale 'alive' flag.
- For confirmed hard path failure, close **only connections on the failed node/buckets** through Mihomo connection ID endpoint; existing TCP streams cannot migrate transparently. Users may need app auto-reconnect / manual reconnect, with original VLESS Reality profile unchanged.
- For scheduled capacity changes, drain old connections naturally and keep per-user exit-IP stability as much as possible.
- Never use global \`/connections\` DELETE, \`pkill xray\`, or restart x-ui for routine failover.
- If controller API is unavailable, keep last-known-good routing and raise operator alert; do not repeatedly restart global service.

## G. Rolling 24-hour quota

- Policy target per *physical foreign VPS*: **100 GB/user-download-equivalent over rolling 24h** (define GiB versus decimal GB and traffic direction before enforcement).
- F1–F4 have separate counters. F5 sums Maya1 + Maya3 **centrally on F5**; independent gateway-only counters can overspend.
- Measure true foreign egress/backhaul bytes from persistent per-node/per-service accounting (e.g. firewall/service counters with scoped paths) and correct for reset/restart. Mihomo sampled active \`/connections\` alone is insufficient: short-lived completed flows can be missed.
- Suggested planner stages: at 70% redistribute new flows proactively; at 90% stop new discretionary assignments; at 100% set CAPPED for new flows and route only through eligible nodes. These thresholds are tunable and require hysteresis.
- Current stated traffic ~250 GB/day per Maya => ~500 GB/day combined; exactly 5 × 100 GB/day. **No spare capacity at a hard 100 GB limit.** Loss of any node leaves 400 GB/day. Either accept service throttling/denials, acquire capacity or explicitly authorize emergency cap up to 125 GB for the remaining 4 (4×125=500); do not silently break a strict 100-GB cap.
- If F5 coordinator unreachable, F5 grants no unreserved quota; optional preallocated leases must not permit aggregate overspend. Distinguish F5 admission failure from its data-plane health.
- Rolling quota uses byte counters, not user count/connection count. A soft cap balances load; a hard cap necessarily risks reduced service when aggregate demand exceeds capacity.

## H. Cross-gateway coordination

- F5 shared occupancy and quota are authoritative on F5, with separately authenticated Maya identities. F5 need not query Maya's sensitive x-ui database.
- Separate service identity/UUID/certificate/credential on F5 per gateway; do not run the current single-tenant Lane3 foreign installer twice.
- F5 should enforce per-Maya reservations/admissions within one total budget. Concurrent Maya1+Maya3 failures may exhaust shared headroom; arbitration and explicit degraded mode are required.
- Keep the control API private, limited to authenticated localhost/service communication; never expose Mihomo controller \`19090\` publicly.

## I. Prevent 'Trust failure slows Maya users'

- On early failures, stop assigning new flows to Trust before expensive timeout cascades; don't wait for local service restart to decide path health.
- Confirm whether slowness is user→Maya REALITY ingress, Maya CPU exhaustion, x-ui/xray→Mihomo queue, Trust external TCP SYN retransmit, or Mihomo stale routing. Collect local /proc and ss statistics without dumping user identifiers.
- Exclude blocked route globally; selectively clear stuck failed-path connections on confirmed quarantine to avoid retry pileup.
- Never assume a successful unified :7990 health check proves Trust/Mieru are both healthy.

## J. Acceptance and rollback

Preproduction tests:
1. All paths healthy; user file/inbound unchanged; load obeys quota policy.
2. Simulate Trust foreign unreachable, partial TLS handshake failure, silent/slow path, selective application block, and local carrier service crash; verify correct ejection.
3. Bring the path back; verify staged recovery, no flap after single successful probe.
4. Simulate UDP-only failure; ensure TCP policy not unnecessarily quarantined.
5. Simulate F5 concurrent failures/load/central ledger unavailability.
6. Verify no x-ui/dispatcher restart in steady-state route changes, only changed sessions affected.
7. Controller kill/reboot leaves safe last state; no secret leakage.
8. Soak test with user-like traffic; compare QUARANTINE latency, reconnect success, existing session losses, resource use, probe volume.
9. Restore prior routing via a versioned backup and turn controller to OBSERVE_ONLY if regression occurs.

**Deployment:** OBSERVE_ONLY 48h → MANUAL_FAILOVER simulation → gradual AUTO_EJECT per one Maya → second Maya only after verified stability. Do not directly activate the controller in production with untested synthetic assumptions.

## K. Implementation backlog (not yet built)

- \`maya-health/controller.py\`: state machine, event ingestion, rate-limited adaptive probe scheduler.
- \`maya-health/probes.py\`: forced-path HTTP/TLS/small transfer and SOCKS XUDP checks.
- \`maya-health/actuator.py\`: bucket-to-proxy mapping through local Mihomo Controller with readback, targeted connection drains.
- \`maya-health/quota.py\`: per-node persistent rolling-byte ledger and shared-F5 lease client.
- \`maya-health/foreign5-agent.py\`: authenticated shared quota arbiter on F5.
- \`maya-health/schema.json\`: configuration; only loopback/local admin endpoints.
- \`maya-health/tests/\`: unit+integration+fault injection and soak harness.
- \`maya-health/install-observe-only.sh\`: read-only first, with safe rollback and no x-ui restart.
- Explicit tests against pinned 3x-ui 2.9.4, bundled Mihomo v1.19.31, TrustTunnel and Mieru versions in repo README.

References:
- https://wiki.metacubex.one/en/api/
- https://wiki.metacubex.one/en/config/proxy-groups/load-balance/
- https://github.com/aliiitavazoeiii-afk/frp-tunnel/blob/triple-carrier-naive/dual-trust-mieru/dual-health.sh
- https://github.com/aliiitavazoeiii-afk/frp-tunnel/blob/triple-carrier-naive/dual-trust-mieru/dual-autoheal.sh
- https://github.com/aliiitavazoeiii-afk/frp-tunnel/blob/triple-carrier-naive/dual-trust-mieru/lane3-pool.py
