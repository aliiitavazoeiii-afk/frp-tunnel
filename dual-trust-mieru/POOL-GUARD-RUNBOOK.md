# Dual adaptive quarantine — isolated canary v1

Base: `trust-mieru-dual` at `133be735d21a112fc0af842227fd4b07ade08818`.

**Scope: Dual Trust/Mieru only.** Does NOT support `triple-carrier-naive`, Maya4, or a generic Mihomo config. Does NOT touch public x-ui, REALITY, inbound 443 or user UUIDs.

## Why

- Existing Mihomo `DUAL` group relies on a 120-second, lazy single-URL synthetic check and sticky session mapping; a soft/partial failure can remain user-visible.
- The old 5-minute autoheal timer restarts local carrier daemons but cannot quarantine an unreachable foreign endpoint.
- HTTPS `https://api.telegram.org/` is a **Bot API** signal, **not** proof that Telegram MTProto connections, media DCs or a given user's Telegram session work.
- A pre-existing TCP connection never migrates to a different carrier; new connections can be redirected after quarantine.
- Rapid repeated IP failures **do not prove** DPI signature detection. Investigate public IP/ASN reachability, TCP handshake, TLS, Mieru authentication, XUDP and provider/host pressure separately.

## Components

- `dual-pool-guard.py`: forced-path HTTP 204 and Telegram HTTPS probes via SOCKS 7991 (Trust) and 7992 (Mieru). Explicit `observe` (default) and `auto` modes. In auto, a failed role needs a second confirmatory round and a healthy peer. If both are failing, never remove the last route.
- Live pool change: construct a minimal membership-only YAML edit, run Mihomo `-t`, back up the whole prior file, use local authenticated `PUT /configs` (without `force=true`), verify `GET /proxies/DUAL` actual members, atomically persist. On error, request rollback of prior in-memory config. No x-ui or dispatcher restart.
- Recovery after >=600 seconds dwell and >=3 consecutive healthy check cycles. A restored path returns at normal load-balance weight; **weighted 10% probation is not implemented**.
- `dual-autoheal.sh`: avoids restarting local carrier for a role already quarantined by the guard. Its old behavior is untouched until auto mode is approved and installed.
- `dual-manager.sh`: no longer deletes the old foreign VPS automatically after replacement.

## Read-only runtime preflight (Maya1/Maya3 Iran server)

Use this *before* installing anything. Outputs do not include credentials:

```bash
printf 'Host: '; hostname
printf 'Current command: '; command -v dual || true
printf 'Dual services:\n'
for u in x-ui dual-dispatcher dual-xudp-bridge dual-trust-client dual-mieru-carrier; do
  printf '%-24s %s\n' "$u" "$(systemctl is-active "$u.service" 2>/dev/null || true)"
done
printf 'Pool config (only safe public fields):\n'
sed -n '/^proxy-groups:/,/^rules:/p' /etc/dual-trust-mieru/iran/dispatcher.yaml | sed '/^rules:/d'
printf 'Listeners:\n'
ss -ltn | awk '$4 ~ /:(7990|7991|7992|7993|7994|19090)$/ { print $4 }'
printf 'Recent local restarts:\n'
systemctl show dual-dispatcher dual-trust-client dual-mieru-carrier --property=Id,NRestarts --no-pager
```

Do **not** paste `dispatcher.yaml` in full; it embeds a controller secret. Do **not** print any private bundles.

## Offline tests

```bash
python3 -m unittest discover -s dual-trust-mieru/tests -p test_pool_guard.py -v
python3 -m py_compile dual-trust-mieru/dual-pool-guard.py
bash -n dual-trust-mieru/install-pool-guard.sh dual-trust-mieru/dual-autoheal.sh dual-trust-mieru/dual-manager.sh
```

The GitHub Actions workflow also executes these tests, but cannot reproduce live filtering, Telegram MTProto, or failover reconnection.

## Rollout stages

1. Fetch this feature branch to a **new directory**; do not replace the currently deployed repo or run `install-iran.sh` / `attach-xui.sh`.
2. Read current live pool. Verify it is truly Dual; do not activate if Naive joins `7990`.
3. Install **observe-only** (new timer and sidecar, no tunnel restart):
   ```bash
   sudo bash dual-trust-mieru/install-pool-guard.sh --observe
   ```
4. Review 48 hours of per-path observations, compare with real user connectivity and any failures on the Bot API endpoint. Verify the separate role health tests and the actual local Mihomo controller schema.
5. **Only after live canary/rollback validation**, enable automatic quarantine explicitly:
   ```bash
   sudo env DUAL_POOL_GUARD_LIVE_APPROVED=YES bash dual-trust-mieru/install-pool-guard.sh --auto
   ```
   This modifies only the pool-guard systemd unit/timer and next-run autoheal script. On quarantine, the Mihomo API reload may affect in-flight sessions; test this on a canary gateway before auto mode on all users.

## Emergency disable

Disable only the new guard, **not the tunnel**:

```bash
sudo systemctl disable --now dual-pool-guard.timer
```

If pool membership was changed in auto mode, **stopping the timer does not restore it**. Inspect `/var/lib/dual-trust-mieru/pool-guard/` backups and the safe `DUAL` member list. Restore the correct saved config and reload it via the authenticated local Mihomo controller as a controlled operation; do not restart x-ui.

## Security and detection limits

- Existing controller binds `127.0.0.1:19090` with a password stored in a root-only file. Do not widen its bind address.
- Existing provisioning uses `StrictHostKeyChecking=accept-new`; replace this with verified host keys/fingerprints before trusting newly provisioned foreign hosts, particularly when moving private XUDP credentials.
- Do not silently change `MULTIPLEXING_OFF`, `HANDSHAKE_STANDARD`, TLS verification or Trust/Mieru fingerprints. Benchmarks are required. Mieru traffic-pattern settings may change overhead and cannot guarantee resistance to filtering.
- The guard's probes are synthetic and can cause false positives. Current v1 has **no passive error telemetry, no MTProto test, no UDP-only routing isolation, no weighted probation and no automatic targeted connection drain**. See `maya-smart-health-rfc:MAYA-SMART-HEALTH-RFC.md` for the longer-term staged architecture.
