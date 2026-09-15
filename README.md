# AnyTLS Tunnel v1.8.0 — x-ui + XUDP + remote-DNS + health-gated shared F5

Production backend tunnel for an existing x-ui/Xray deployment:

- Foreign A / F1: AnyTLS + ShadowTLS v3 on public TCP/443
- Foreign B / F2: AnyTLS + ResTLS on public TCP/443
- Iran: Mihomo health-gated load balancing behind Xray XUDP
- Mandatory XUDP compatibility bridge: pinned Xray v26.3.27
- Existing x-ui/Xray remains user-facing on TCP/443 and keeps existing VLESS/REALITY users.
- Optional shared F5: one additional Foreign A / ShadowTLS v3 node time-shared between `maya1` and `maya3`.

## Final Iran state

```text
Public x-ui inbound :443
  sniffing.enabled = true
  destOverride = http,tls,quic,fakedns

x-ui outbound anytls-tunnel
  protocol = socks
  target = 127.0.0.1:7891
  targetStrategy = AsIs
  mux.enabled = false

7891 = Xray XUDP bridge
7890 = Mihomo AnyTLS carrier
9090 = Mihomo controller
QUIC_SAFE_MODE = false
```

`AsIs` is intentional: production tests showed selected YouTube/Instagram CDN hostnames failed when resolved locally on the Iran server but worked when the hostname was resolved through the proxy path.

## Traffic path

```text
User
  -> x-ui/Xray Iran :443
  -> sniff hostname
  -> SOCKS 127.0.0.1:7891, AsIs
  -> Xray XUDP bridge
  -> inner VLESS/XUDP over TCP
  -> SOCKS 127.0.0.1:7890 (Mihomo)
  -> health-gated AnyTLS round-robin subset
  -> Foreign node public TCP/443
  -> Foreign Xray XUDP endpoint 127.0.0.1:2443
  -> Internet
```

No extra public XUDP port is opened. Foreign `2443`, Iran `7890`, `7891`, and `9090` are loopback-only.

## Fresh base installation

Install Foreign A, then Foreign B, then Iran.

```bash
sudo rm -rf /opt/anytls-tunnel
sudo git clone -b anytls-v1.3.0 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/anytls-tunnel
cd /opt/anytls-tunnel
```

Foreign A:

```bash
sudo bash setup-final.sh foreign-a
```

Foreign B:

```bash
sudo bash setup-final.sh foreign-b
```

Iran after x-ui already exists on public TCP/443:

```bash
sudo bash setup-final.sh iran
```

Final base health:

```bash
sudo anytls-final-health
```

## Shared F5 schedule

Install F5 as another Foreign A / ShadowTLS v3 node. The default validated cover is `www.cloudflare.com`.

On `maya1`:

```bash
sudo bash install-shared-node.sh maya1
```

On `maya3`:

```bash
sudo bash install-shared-node.sh maya3
```

Schedule uses `Asia/Tehran`:

```text
maya3: 15:00 -> 21:00
maya1: 21:00 -> 03:00
03:00 -> 15:00: F5 idle
```

## v1.8.0 health-gated balancing

The active pool is no longer a fixed sticky group. Healthy multi-node subsets use `strategy: round-robin` so new requests are distributed across the currently healthy nodes.

Prepared subsets include:

```text
TUNNEL-BASE   = A + B
BASE-A        = A only
BASE-B        = B only
TUNNEL-SHARED = A + B + F5
SHARED-AF5    = A + F5
SHARED-BF5    = B + F5
SHARED-F5     = F5 only
REJECT        = fail closed if no node is healthy
```

Every minute, each eligible node is checked separately from the Iran gateway against:

- `www.gstatic.com/generate_204`
- `www.youtube.com`
- `i.ytimg.com`
- `www.instagram.com`

A failed application test is retried once. A node that fails twice is excluded from new traffic. If it had active Mihomo connections, only those connections using that failed node are closed so applications reconnect through the remaining healthy subset.

Before a previously excluded node is allowed back into traffic, it must first pass a full isolated probe:

- public TCP/443
- AnyTLS / ShadowTLS or ResTLS
- inner XUDP path
- gstatic / YouTube / ytimg / Instagram
- sustained HTTPS transfer
- UDP DNS round-trip over XUDP

Mihomo policy groups also keep an independent 15-second `gstatic` health check with `expected-status: 204` as a second safety layer.

The scheduler changes only the local Mihomo selector. It does not restart x-ui or the XUDP bridge.

### Live upgrade from v1.7.x

On an already-working Iran gateway with shared F5 installed:

```bash
cd /opt/anytls-tunnel
sudo git fetch origin
sudo git checkout anytls-v1.3.0
sudo git pull --ff-only origin anytls-v1.3.0
cat VERSION
sudo bash upgrade-balanced-guard.sh
```

Expected version:

```text
1.8.0
```

Useful checks:

```bash
cat /var/lib/anytls-tunnel/shared-node.state
systemctl status anytls-shared-scheduler.timer --no-pager
journalctl -u anytls-shared-scheduler.service -n 100 --no-pager
```

Current selector:

```bash
set -a
source /etc/anytls-tunnel/deploy.env
set +a
curl -sS -H "Authorization: Bearer $CONTROLLER_SECRET" \
  "http://127.0.0.1:$LOCAL_CONTROLLER_PORT/proxies/TUNNEL" | jq '{type,now,all}'
```

Current active connection distribution:

```bash
curl -sS -H "Authorization: Bearer $CONTROLLER_SECRET" \
  "http://127.0.0.1:$LOCAL_CONTROLLER_PORT/connections" | jq '{
  foreign_a: [.connections[] | select(.chains | index("foreign-a-shadowtls"))] | length,
  foreign_b: [.connections[] | select(.chains | index("foreign-b-restls"))] | length,
  foreign_shared: [.connections[] | select(.chains | index("foreign-shared-shadowtls"))] | length,
  total: (.connections | length)
}'
```

Existing healthy connections are not force-rebalanced during an upgrade, so connection counts can remain skewed until old sessions naturally close. New requests follow round-robin immediately. A failed node is treated differently: its existing Mihomo connections are drained to avoid leaving users frozen on that route.

## Node probes

Shared F5 full probe:

```bash
sudo anytls-shared-probe
```

Full isolated probe of any configured node:

```bash
sudo anytls-node-full-probe a
sudo anytls-node-full-probe b
sudo anytls-node-full-probe shared
```

## Replace a filtered base node

Install the replacement Foreign server with the same role, then on Iran:

```bash
sudo anytls-replace
```

The replacement workflow probes the new node before activation and does not modify x-ui users or the public VLESS/REALITY inbound.

## Remove shared F5 only

```bash
sudo anytls-shared-uninstall
```

## Remove AnyTLS/XUDP project

```bash
sudo anytls-uninstall
```

Full purge:

```bash
sudo anytls-uninstall --purge
```

On Iran, the base uninstaller keeps x-ui and its users.

## Pinned versions

- Mihomo `v1.19.30`
- Xray `v26.3.27`
