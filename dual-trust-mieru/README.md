# Dual Trust + Mieru v1

Fresh replacement tunnel architecture. No Bucket5 and no per-user bucket mapping.

## Data path

```text
x-ui public VLESS/REALITY :443
  -> SOCKS 127.0.0.1:7990 (Mihomo health-aware round-robin dispatcher)
     -> PATH A: SOCKS 7991 -> Xray XUDP -> TrustTunnel SOCKS 7993 -> HTTP/2 TCP/443 -> Trust foreign -> XUDP 127.0.0.1:2443
     -> PATH B: SOCKS 7992 -> Xray XUDP -> Mieru SOCKS 7994 -> Mieru TCP port range -> Mieru foreign -> XUDP 127.0.0.1:2443
```

Load balancing is **connection-level**, not packet-level. Mihomo round-robin selects a path for each new SOCKS connection. Health checking removes an unhealthy full XUDP path from the dispatcher. Existing connections are not moved between transports mid-stream.

## Why XUDP stays

Both paths terminate in an independent Xray XUDP endpoint on each foreign server. Hostnames are preserved with x-ui sniffing + `targetStrategy=AsIs`, retaining the Google/YouTube/UDP behavior proven by the previous deployment.

## Isolation from the old tunnel

Iran local ports are intentionally new:

- `7990`: final dual entry for x-ui
- `7991`: forced Trust XUDP path
- `7992`: forced Mieru XUDP path
- `7993`: TrustTunnel local SOCKS
- `7994`: Mieru local SOCKS
- `17994`: Mieru client RPC
- `19090`: loopback Mihomo controller

This allows the new stack to run beside the old 7890/7891/790x/181xx stack during a later Maya migration. `install-iran.sh` does **not** modify x-ui. `attach-xui.sh` is the explicit cutover step and creates an x-ui DB backup first.

## Foreign roles

### Trust foreign

Requirements:
- dedicated server
- public IPv4
- a DNS name whose A record points to that IPv4
- TCP/443 and TCP/80 reachable (80 is used for Let's Encrypt issuance/renewal)
- if the provider has a cloud firewall/security group, open TCP/80 and TCP/443 there too

The installer deploys TrustTunnel endpoint HTTP/2 only, plus an Xray loopback XUDP endpoint. The endpoint is authenticated and allows private/loopback target forwarding because XUDP is `127.0.0.1:2443` on the foreign host.

### Mieru foreign

Requirements:
- dedicated server
- public IPv4
- a TCP port range (default `20000-20020`)
- open that entire TCP range in both the host firewall and provider firewall/security group
- keep NTP/time synchronization enabled; Mieru derives session keys from credentials plus system time

The installer deploys official `mita` plus an Xray loopback XUDP endpoint. The generated Mieru user has `allowLoopbackIP=true` so the Iran Xray client can reach the remote loopback XUDP endpoint.

## Secrets

Foreign installers generate credentials locally. They write root-only bundles:

- `/root/dual-trust-client.json`
- `/root/dual-mieru-client.json`

Never paste these into chat or commit them. Transfer them to the Iran server through your own machine if Iran cannot SSH/SCP to the foreign servers.

## Deployment order

1. Trust foreign:
   `sudo bash install-foreign-trust.sh --public-ip TRUST_IP --domain trust.example.com --email YOU@example.com`
2. Mieru foreign:
   `sudo bash install-foreign-mieru.sh --public-ip MIERU_IP --port-range 20000-20020`
3. Transfer both root-only bundles to the empty Iran test server.
4. Iran:
   `sudo bash install-iran.sh /root/dual-trust-client.json /root/dual-mieru-client.json`
5. Full forced-path test:
   `sudo dual-tunnel-probe --full`
6. Single-carrier failover test (safe only on the empty test server):
   `sudo dual-tunnel-failover-test`
7. Only after all tests pass, attach the test x-ui:
   `sudo bash attach-xui.sh`
8. `attach-xui.sh` prints and installs `sudo dual-tunnel-xui-rollback`. Keep it until the new path has proven stable.

`uninstall-iran.sh` refuses to remove the new local services while x-ui still points to `127.0.0.1:7990`; roll x-ui back first.

## Success criteria before Maya rollout

- Trust forced path `7991`: gstatic, YouTube, ytimg, Instagram, 1 MB transfer and UDP DNS all pass.
- Mieru forced path `7992`: same tests all pass.
- Dispatcher `7990` passes TCP and UDP and shows both foreign egress IPs across repeated new connections.
- Stopping either client individually leaves dispatcher healthy through the other path.
- Re-enabling the carrier returns both paths without changing x-ui users.

## Pinned versions

- TrustTunnel endpoint `v1.0.33`
- TrustTunnel CLI client `v1.0.49`
- Mieru / mita `v3.37.0`
- Mihomo `v1.19.31`
- Xray-core `v26.9.8`

All downloaded release artifacts used by installers are SHA256-pinned.

## Cleanup commands for the test phase

- Trust foreign: `sudo bash uninstall-foreign-trust.sh`
- Mieru foreign: `sudo bash uninstall-foreign-mieru.sh`
- Iran (before x-ui attach): `sudo bash uninstall-iran.sh`
- Iran (after x-ui attach): first `sudo dual-tunnel-xui-rollback`, then `sudo bash uninstall-iran.sh`
