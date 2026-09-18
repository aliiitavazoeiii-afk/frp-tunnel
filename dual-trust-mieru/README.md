# Dual Trust + Mieru v1

Fresh replacement tunnel architecture for one Iran gateway and two independent foreign servers. There are **no buckets, no per-user mapping and no custom failover scheduler**.

## Final data path

```text
x-ui public VLESS/REALITY :443
  -> SOCKS 127.0.0.1:7990 (Mihomo health-aware round-robin dispatcher)
     -> PATH A: SOCKS 7991 -> Xray XUDP -> TrustTunnel SOCKS 7993
                -> HTTP/2 TLS TCP/443 -> Trust foreign -> XUDP 127.0.0.1:2443 -> Internet
     -> PATH B: SOCKS 7992 -> Xray XUDP -> Mihomo-native Mieru SOCKS 7994
                -> Mieru TCP port range -> Mieru foreign -> XUDP 127.0.0.1:2443 -> Internet
```

Load balancing is connection-level, never packet-level. New SOCKS connections are distributed with Mihomo `round-robin`; an established connection remains on the selected path. The dispatcher health-checks the **complete forced XUDP paths** on 7991/7992. If either full path fails, new connections use the healthy path. When it recovers, it automatically rejoins balancing.

## Why XUDP stays

Each foreign terminates an independent Xray XUDP endpoint on loopback `127.0.0.1:2443`. x-ui uses hostname-preserving sniffing and `targetStrategy=AsIs` after explicit attach, retaining the Google/YouTube/UDP behavior proven by the earlier system.

## Iran ports and services

Ports:
- `7990`: final dual entry for x-ui
- `7991`: forced Trust XUDP path
- `7992`: forced Mieru XUDP path
- `7993`: TrustTunnel local SOCKS
- `7994`: Mihomo-native Mieru local SOCKS
- `19090`: loopback dispatcher controller

Services:
- `dual-trust-client.service`
- `dual-mieru-carrier.service`
- `dual-xudp-bridge.service`
- `dual-dispatcher.service`

The new ports intentionally do not overlap the old AnyTLS/Bucket5 stack. `install-iran.sh` **does not modify x-ui**. `attach-xui.sh` is a separate explicit cutover step and backs up the x-ui database first.

## Foreign roles

### Trust foreign

Requires a dedicated server, public IPv4, and a DNS name whose A record points to that IP. TCP/80 and TCP/443 must be reachable. The installer obtains/uses a Let's Encrypt certificate, runs TrustTunnel as HTTP/2 over TCP/443 only, and runs Xray XUDP only on loopback.

The endpoint permits private/loopback targets intentionally because the only tunnel backend we need is its local XUDP listener on `127.0.0.1:2443`.

### Mieru foreign

Requires a dedicated server, public IPv4 and a TCP port range (default `20000-20020`). Open that range in the host/provider firewall. Keep NTP synchronized. The installer runs official `mita` plus an Xray XUDP listener on loopback. Its generated user explicitly allows loopback/private destinations so the Iran-side XUDP can reach `127.0.0.1:2443` through Mieru.

The Iran server does **not** install the official Mieru client daemon. Mihomo `v1.19.31` is the Mieru client/carrier, reducing services and keeping transport health local and isolated.

## Secrets

Foreign installers create root-only client bundles:
- `/root/dual-trust-client.json`
- `/root/dual-mieru-client.json`

Never paste their contents into chat or commit them. If the Iran server cannot SCP to the foreign servers, copy the files through your own computer. Verify SHA256 at source and destination.

## Test-server deployment order

Use this first only on an Iran server with no users.

1. Install the Trust foreign.
2. Install the Mieru foreign.
3. Transfer both root-only bundles to the empty Iran test server.
4. Install the Iran stack. This starts only the four local dual-tunnel services; x-ui is untouched.
5. Run `sudo dual-tunnel-probe --full`.
6. Run `sudo dual-tunnel-failover-test` on the empty test Iran.
7. Let both paths run and observe stability.
8. Only after the above succeeds, run `sudo bash attach-xui.sh` if that test server has an x-ui public inbound to test end-to-end.
9. Keep `sudo dual-tunnel-xui-rollback` until the new architecture has proved stable.
10. Only then repeat the proven procedure on Maya1/Maya2.

## Success criteria before Maya rollout

- Trust forced path `7991`: gstatic, YouTube, ytimg, Instagram, sustained download and UDP DNS pass.
- Mieru forced path `7992`: the same tests pass.
- Dispatcher `7990` passes TCP and UDP.
- Repeated new connections through `7990` show both foreign egress IPs when both paths are healthy.
- Stopping Trust leaves dispatcher working through Mieru.
- Stopping Mieru leaves dispatcher working through Trust.
- Restarting either carrier automatically returns it to the healthy balancing set.
- No x-ui user/client configuration changes are required when only the internal tunnel stack changes.

## Pinned releases

- TrustTunnel endpoint `v1.0.33`
- TrustTunnel CLI client `v1.0.49`
- Mieru / mita `v3.37.0`
- Mihomo `v1.19.31`
- Xray-core `v26.9.8`

Xray `v26.9.9` is currently marked pre-release upstream, so this candidate deliberately stays on the latest non-pre-release 26.9.x pin. Downloaded release artifacts are SHA256 verified before installation.

## Cleanup

- Trust foreign: `sudo bash uninstall-foreign-trust.sh`
- Mieru foreign: `sudo bash uninstall-foreign-mieru.sh`
- Iran before x-ui attach: `sudo bash uninstall-iran.sh`
- Iran after attach: first `sudo dual-tunnel-xui-rollback`, then `sudo bash uninstall-iran.sh`

`uninstall-iran.sh` refuses to remove the stack while x-ui still points at `127.0.0.1:7990`.
