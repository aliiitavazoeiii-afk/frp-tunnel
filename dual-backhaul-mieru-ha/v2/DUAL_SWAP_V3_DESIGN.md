# Dual HA V3 — Transactional Foreign VPS Rotation (DESIGN ONLY)

**State:** design specification; NOT deployable code, NOT installed, no production changes.
**Base branch:** `dual-auto-multi-iran`.
**Targets:** Maya1 / Maya3 (maya-s3) / Maya4. Iran Xray/REALITY 443 and user identities are out of scope.

## User contract

Single command on the relevant Iran host:

```bash
sudo dual-swap mieru 203.0.113.10
sudo dual-swap backhaul 203.0.113.11
```

(Example IPs are documentation-only and will be rejected as non-global test addresses.)

Interactive input: **new VPS root SSH password once**, never on argv, never persisted or logged. A newly seen SSH host key **must be independently verified against the VPS provider**; one security verification may be needed in addition to the IP and password. Optional `--dry-run` must make no network changes.

The **previous foreign VPS must NOT be reachable or healthy** for candidate staging to proceed. Previous *role* state is preserved for rollback; the other role's health is recorded but not a hard precondition. In a no-survivor case warn about a short handover interruption; fail rather than assert zero downtime.

**Success means** candidate data plane has been verified from Iran BEFORE cutover; production egress has been verified AFTER cutover; old ingress/secret credentials have been revoked; old local connection configuration and managed firewall rules no longer affect the new server. Success must not be reported before all mandatory checks. Remote removal on an unreachable old VPS is impossible: report `REMOTE_CLEANUP_PENDING`, with old credentials revoked on Iran and the old host unable to resume the production tunnel.

## Actual source findings requiring V3 changes

1. `dual.py:safety_checks` (base: v2/dual.py, around lines 278–309) requires a fresh, HTTPS-healthy **other** path. It aborts exactly when the surviving path is unhealthy.
2. The legacy `dual.py:replace_backhaul` SSHes to **old** VPS to stop it. V3 must NEVER SSH old VPS as part of preflight/switch/rollback.
3. `dual_auto.py` improves this with an Iran-side firewall old-host block, but still checks survivor Mieru and only tests Backhaul on production port after switching; there is NO independent pre-switch Backhaul data-plane canary.
4. `dual.py:replace_mieru` installs foreign Mita, changes `/etc/dual-ha/mieru.json`, restarts the live Mieru service, then checks two HTTPS responses. It has no parallel local candidate SOCKS transfer test.
5. `dual.py:backhaul_candidate_bundle` keeps the **old BH_TOKEN** and only replaces BH_FOREIGN_IP. V3 must generate an independent fresh token and control/tunnel paths; old host must never be able to reconnect to the new production route.
6. Existing helpers intentionally retain old remote Mita and old UFW allow entries after success. In several deployments extra iptables guard chains / dynamic guard services exist. V3 must reconcile all **managed** ingress policies, including reboot persistence, without deleting unrelated rules.
7. The legacy guard contains `REJECT --reject-with tcp-reset` without preceding `-p tcp` on a catchall rule; this fails on iptables-nft. V3 must use protocol-specific TCP rules and unit tests.
8. The existing `dual status/health` 2/3 HTTPS pass can be misleading: real 1MiB downloads previously timed out on both paths on Maya1.

## Design: prepare / test / commit / verify / cleanup

```text
PRECHECK -> STAGE_FOREIGN -> STAGE_IRAN_CANARY -> TEST_CANARY
                                             |
                                 fail -------+--> CLEAN_CANDIDATE -> OLD_UNCHANGED
                                             |
                                           pass
                                             v
SNAPSHOT_AND_JOURNAL -> CUTOVER -> TEST_PRODUCTION -> OBSERVE -> REVOKE_OLD
                              |           |           |           |
                              +-- failure-+-- failure+--> ROLLBACK
                                                                   |
                                         CLEAN_LOCAL -> CLEAN_REMOTE_BEST_EFFORT
                                              |
                                          COMPLETED or
                                          REMOTE_CLEANUP_PENDING
```

Any validation failure prior to cutover must leave live `/etc/dual-ha/*`, Xray, HAProxy, firewall, and live services **byte-for-byte/behaviorally unchanged**, except the separately staged candidate files/services, which are dismantled. No current role is required to be healthy. A failed cutover restores the **previous role configuration and ingress policy**; if the old remote is filtered, rollback preserves its previous (possibly nonworking) state — cannot guarantee that a previously failed tunnel becomes working.

### Precheck (read-only)

- Must run as root **on an approved Iran host**; identify actual Iran host from trusted local config and route. Mapping table must be verified for Maya1/Maya3/Maya4; do not assume all deployed copies equal a Git branch.
- Confirm both role configs exist, no concurrent `dual-swap`, no existing stale/inconsistent rotation journal. Use `flock` on `/run/dual-ha-rotate.lock` for entire transaction.
- Validate new globally routable IPv4, distinct from Iran, both current foreign IPs and all unexpired candidate hosts.
- Identify actual systemd units, ports, HAProxy socket/server names, stunnel certificate, UFW/iptables/nft, *other* firewall guards and role-specific paths. Unknown ingress policy => FAIL CLOSED with precise message.
- Precheck SSH password/key + host key using `paramiko`; require independent host key fingerprint confirmation, no `AutoAddPolicy`; prevent SSH agent forwarding, host-key downgrade, untrusted preinstalled foreign role services. Use fresh host only, fail closed rather than destructively reuse.
- Store snapshots and transaction journal with 0700/0600 permissions; secrets must be redacted from stdout, errors and app logs. Separate `run_id` for staging resources; never run untrusted shell with interpolated IP/password.

### Mieru: non-disruptive candidate lane

- Install foreign `mita` on the new VPS (as current foreign installer does), using new random credentials and new root SSH key authorization.
- On Iran, spawn **separate** candidate Mieru client using independent temporary config, listening SOCKS `127.0.0.1:21102`, and distinct RPC port / process/service name. DO NOT alter live `127.0.0.1:21002` or `dual-ha-mieru.service` yet.
- Probe only this new candidate endpoint through SOCKS from Iran: fixed approved HTTPS data destination; at most 3 requests of exactly 1 MiB, max 15s each, no retry storm; verify `curl exit=0`, `HTTP=200`, exact bytes, observed egress IP equals candidate (check separately via trace), acceptable TTFB and transfer duration. Require >=2 of 3 complete in <=12s (document configurable threshold) and no contradiction in egress IP.
- If probe fails, only candidate resources are disabled and removed. Current Mieru local config, active service, HAProxy and firewall must remain untouched.
- Once passed: record a durable snapshot; replace the live Mieru config atomically; restart **only `dual-ha-mieru`** (or select a blue/green proxy indirection if later adopted); verify live SOCKS `:21002`, HAProxy new transactions and controller; if any check fails, immediately restore the prior file and restart old service.
- Existing sessions through this role can reconnect during restart; no zero-interruption promise.

### Backhaul: MUST have independent reverse tunnel canary before cutover

The current foreign client dials **Iran public :18443** and maps Iran SOCKS `127.0.0.1:21001` to foreign Dante `127.0.0.1:11080`. A TCP reachability probe on the new foreign VPS does NOT verify reverse Backhaul.

- Build an **isolated staging Backhaul** on Iran using a distinct service set/namespace:
  - External source-limited TLS ingress TCP `18444` (must be supported by local + provider firewall; otherwise fail without changing production).
  - Router loopbacks `19082 / 19083` (or verified unused ports), canary Backhaul SOCKS `127.0.0.1:21101`.
  - New independent cryptographically random BH_TOKEN and WS control/tunnel paths (not cloned from current production).
  - Dedicated staging stunnel/router/backhaul server configurations and services. Do not overwrite/restart current `18443`, `19080/19081`, `21001`, production Backhaul, or HAProxy.
- Install and start new foreign client pointing to the dedicated Iran :18444 staging ingress, with its dedicated tokens; test real SOCKS egress on :21101 from Iran using the exact full-data policy above.
- **Fail closed if staging port, certificate, router, or IP egress cannot be independently validated.** Do not 'temporarily just switch to see whether it works'.
- Only after canary passes, snapshot production bundle and configs. At cutover, prepare **new** production role with fresh secrets and explicit allow rule for the new source; revoke/block old foreign source on production :18443 *before* permitting the new foreign reverse client to claim the live relay. Move new foreign client to production :18443 and new role credentials to production configs atomically as far as filesystem allows; restart only the Backhaul-specific components required.
- Test actual Iran `:21001` transfer **and** egress IP, gateway selection, controller status; failed check => reverse the local config/policy and attempt old connection recovery. If old remote IP was already filtered, preserve previous configuration but truthfully report `ROLLED_BACK_OLD_PATH_STILL_UNHEALTHY`.
- A short interruption on existing Backhaul sessions can occur during replacement; minimize with a future blue/green stable listener design but NEVER promise zero gap with current layout.

### Deterministic quality gate (identical per role)

- Candidate tests originate from Iran through **candidate** SOCKS, not `curl` on VPS itself.
- 3 x 1 MiB HTTPS responses via a fixed allowlisted test URL, bounded duration, exact byte count, exit status, HTTP status, TTFB and throughput.
- >=2/3 fully completed <=12 seconds, egress IP independently confirmed to be `new_ip`; with slow/failed tests, do not cut over. 1MiB in 12s (~85 KiB/s) is a minimum usability gate, not a high-throughput SLA.
- Post-cutover repeat from live role SOCKS and gateway; validate controller sees role up and **new connections** reach it. If the other path is available, use source-specific direct probes instead of random gateway result to avoid false positives.
- No schedule/continuous traffic generation. Strict single-job lock, bounded retries and connection/time limits. Test a second independent HTTPS destination if canonical Cloudflare test is unavailable rather than treating a destination outage as censorship.

### Transaction, crash and rollback safety

- Write-ahead journal with atomic + fsync phases: `PRECHECK`, `STAGED`, `VERIFIED_CANARY`, `CUTOVER_STARTED`, `PRODUCTION_VERIFIED`, `CLEANUP`, `COMPLETED` / `ROLLED_BACK` / `NEEDS_REVIEW`.
- Store exact hashes/copies of **owned** live config files, unit/drop-in changes, ingress guard script, managed firewall rule identities, and current role port ownership; pre-record an idempotent undo action for **every** mutation before performing it.
- `--recover` after restart must resume safe rollback or finish commit idempotently. Never silently assume a rollback worked; verify actual egress. Distinguish `OLD_UNCHANGED`, `ROLLED_BACK`, `ROLLED_BACK_OLD_PATH_UNHEALTHY`, `SWITCHED_REMOTE_CLEANUP_PENDING`, `COMPLETED`.
- Reboot persistence: test managed guard and service order, not just current iptables state. Never flush the entire INPUT chain, alter unrelated UFW/nftables rules or remove unrelated systemd drop-ins.
- If guard owner isn't established, stop with `UNSAFE_FIREWALL_LAYOUT` instead of guessing.

### Post-commit cleanup / deletion contract

- **Never delete previous credentials before cutover verification**: that would prevent rollback.
- After successful post-cutover probes and a bounded observation period (e.g. 120s), revoke old path at Iran:
  - Mieru: active config only contains new IP and credentials; no old credentials in live program configs; remove candidate client and temporary config.
  - Backhaul: new BH_TOKEN/control/tunnel paths and source allowlist; old source explicitly denied and stale *managed* UFW/iptables/guard entries removed/reconciled including at reboot.
- Remove tool-owned previous IP/credential references from active configs, tool-owned temporary bundles and staging; keep encrypted or root-restricted rollback snapshot only until commit reaches irreversibility, then delete its secrets. Secure erasure on SSD/cow filesystems cannot be guaranteed.
- Attempt cleanup on **old VPS** only if old SSH can be independently authenticated: stop/disable only this project's old `dual-ha-*` role services, remove its relevant owned secrets, preserve unrelated VPS software. Old VPS root may be unreachable (filtered): **remote physical cleanup cannot be guaranteed**; report `REMOTE_CLEANUP_PENDING`, but old credentials are revoked from the current Iran production route. Never make new deployment depend on contacting old host.
- Do not delete the old VPS or wipe its OS: that is an independent irreversible billing/infrastructure action.
- Persist non-secret audit record: role, Iran host, old/new IP, exact test metrics, cutover times, cleanup status, errors; never store root passwords or token values.

## Suggested interface

```text
$ sudo dual-swap mieru 203.0.113.10
Iran host: Maya1     Current Mieru: OLD_IP
New VPS SSH password: [hidden]
SSH host key: SHA256:...  Verify in provider console; type YES:
PRECHECK OK
STAGE NEW MIERU OK
CANARY: 1MiB [PASS 2.1s] [PASS 2.3s] [PASS 2.0s]
COMMIT ...
LIVE: 1MiB [PASS] ...  HAProxy UP
OLD REVOKED; local stale state removed
RESULT: COMPLETED (REMOTE_CLEANUP_PENDING if old unreachable)
```

Other commands: `sudo dual-swap status`, `sudo dual-swap --dry-run backhaul IP`, `sudo dual-swap recover --run-id ...`, `sudo dual-swap cleanup --run-id ...`. The proposed command is **not yet installed**.

## Acceptance tests (mock + live staging, without production cutover first)

| Scenario | Required behavior |
|---|---|
| Old Mieru is filtered; Backhaul also unhealthy | Mieru candidate test runs; no old-host SSH and no forced survivor check |
| Old Backhaul SSH times out | New Backhaul canary runs independently on staging port |
| New VPS password invalid or host key mismatch | Stop before local production mutation |
| New Mieru TCP connect works but 1MiB stalls | Fail candidate; old config unchanged |
| New Backhaul canary inaccessible at 18444 | Fail candidate; do NOT attempt production switch |
| Candidate good; live test fails | Restore old active config + managed firewall + service (and verify status) |
| Kernel killed / power loss mid-rotation | `recover` safely resolves journal without uncontrolled reattempt |
| Old Backhaul starts reconnecting on reboot | New credentials and persistent firewall deny old reentry |
| Remote old VPS unreachable after success | Local old creds revoked; report `REMOTE_CLEANUP_PENDING` |
| Legacy Maya3 guard with nft reject syntax | Protocol-specific rules; no iptables syntax failure |
| Two concurrent swaps | Second rejected by lock |
| Other Maya server | No accidental cross-server changes; only local confirmed Iran host acted upon |
| HAProxy health says UP but transfer stalls | Do NOT mark success |
| Need rollback despite both old paths down | Restore old configuration; clearly report old path still not usable |
| Reused IP / shared VPS / IP source mismatch | Fail preflight, never clobber existing services or source bind |

## Deployment gate

1. Implement code on a **new feature branch**; do not install to any Maya from this spec.
2. Unit/mocked failure-injection tests must demonstrate every rollback boundary and old-host-offline behavior.
3. Test Mieru on a separate nonproduction candidate first.
4. Test Backhaul parallel canary on a lab Iran host with explicit staging TCP/18444 and strict firewall and certificate validation.
5. Before production use, inspect live Maya1, Maya3 and Maya4 service/guard inventories and validate differences against actual deployments.
6. Create backups and a one-command rollback/recovery procedure. Only then enable production cutover per host with explicit operator approval.

**Cannot promise both full old-remote deletion and automatic success when old VPS is unreachable**; the enforceable guarantee is that no old local route, token, or ingress authorization remains in the active Iran configuration after confirmed success.