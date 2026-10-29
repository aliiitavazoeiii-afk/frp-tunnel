# Connect 3x-ui REALITY to isolated HAProxy gateway — safe canary

**Current live topology:** X-UI (Iran `94.184.4.38`) owns public `TCP/443`. HAProxy is a separate loopback SOCKS5 gateway at `127.0.0.1:18080`, with Custom Backhaul V2 (`127.0.0.1:21001`) and Mieru TCP (`127.0.0.1:21002`).

**Caution:** this is **TCP-only**. Both available SOCKS backends have been tested with HTTPS but have **not** been load-tested for the entire user base. Do not route UDP/QUIC through this gateway or promise established TCP sessions will migrate between paths.

## Step 0. Read-only live audit (no outage)

On the Iran server:

```bash
cd /root/frp-tunnel/frp-tunnel
git pull --ff-only
sudo bash dual-backhaul-mieru-ha/v2/xray-readonly-audit.sh
```

The audit does not print client UUIDs, email addresses, secret keys, DNS hostnames or passwords. Inspect the current outbound tags, Routing order, 443 inbound tag, and Xray core version. Existing `api`, `stats`, `blocked`, private-IP, and other internal/critical rules must stay intact.

## Step 1. Store a private, consistent backup before editing 3x-ui

```bash
sudo bash dual-backhaul-mieru-ha/v2/xui-snapshot.sh
```

This backs up the live SQLite database (when configured) via SQLite's online backup API and checks integrity. For a PostgreSQL deployment, use a database-level `pg_dump` instead. **Never send the backup to chat**; it contains real user credentials and traffic counters. Prefer an independent off-server encrypted backup as well.

## Step 2. Configure *one new* SOCKS outbound in the panel

On 3x-ui -> **Xray Settings** -> **Outbounds**, append, without replacing existing outbounds:

```json
{
  "tag": "dual-ha-socks",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": 18080
  }
}
```

The object above is for Xray builds with flat SOCKS settings supported by the current upstream Xray outbound schema. **Confirm the installed core accepts it using the panel's config test before saving**, especially if the deployed core is older. Keep the first/default outbound unchanged.

## Step 3. Add only one TCP canary Routing rule

Prefer matching one known test-client **email identifier** if that field is populated on the actual VLESS/REALITY inbound. On 3x-ui -> Xray Settings -> Routing add a rule like:

```json
{
  "type": "field",
  "inboundTag": ["ACTUAL_REALITY_INBOUND_TAG"],
  "user": ["ACTUAL_TEST_CLIENT_EMAIL"],
  "network": "tcp",
  "outboundTag": "dual-ha-socks"
}
```

Replace values locally. Never send client credentials to chat. If the running Xray does not include a client email identifier, use an independently known **single external client source IP**:

```json
{
  "type": "field",
  "inboundTag": ["ACTUAL_REALITY_INBOUND_TAG"],
  "sourceIP": ["ACTUAL_TEST_SOURCE_IP/32"],
  "network": "tcp",
  "outboundTag": "dual-ha-socks"
}
```

Only use source-IP selection if the IP is uniquely yours (beware shared carrier NAT). Add the canary after protective `api`/block/private-IP rules but **before any catch-all rule** that would intercept it. Keep all other routing rules and inbound definitions unchanged. Use the panel's route test to verify that the selected user/IP routes to `dual-ha-socks`, and other users still route exactly as before.

Do not insert a blanket `inboundTag`-only rule or make the new outbound the first/default outbound at this stage — that would migrate all user traffic.

## Step 4. Apply at a planned low-traffic moment and test

3x-ui saves the Xray template and reloads/restarts Xray when it changes. This can interrupt existing TCP sessions even though REALITY clients' subscriptions, UUIDs and keys remain unchanged. There is no guarantee of zero disconnection on apply.

After the canary is applied, on Iran verify:

```bash
systemctl is-active x-ui dual-ha-v2-gateway dual-ha-v2-health
ss -lntp '( sport = :443 )'
cat /run/dual-ha-v2/health.json
```

Connect using the canary client's **existing REALITY configuration** from an external network and visit `https://www.cloudflare.com/cdn-cgi/trace`. The client should see one of the two Foreign IPs (`152.237.230.159` or `152.237.230.248`), while a non-canary user should retain their previous route. Test YouTube and other real workloads for latency, reconnects and interruptions. The existing SOCKS5 direct-port curl checks do not prove REALITY clients are routed correctly.

## Rollback

If the canary fails or clients have errors, remove **only** the added canary routing rule and outbound from 3x-ui Xray Settings and apply the original settings. If any unrelated changes were made accidentally, recover the original template from the local private backup and/or the 3x-ui panel backup through an operator-controlled recovery procedure. Avoid an unreviewed full database restore because it can overwrite live traffic accounting since the snapshot. After revert, verify x-ui/443 and client accounting. Preserve the prechange database backup.

**Status:** never mark entire production migration complete based only on gateway curl tests. First verify one real REALITY client, then a small canary cohort, then an observed progressive rollout. The current HAProxy algorithm is least-connection, not strict 50/50 or sticky-per-user.
