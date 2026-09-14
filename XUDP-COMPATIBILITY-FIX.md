# XUDP Compatibility Fix — Google / YouTube / NPV Tunnel

## Why this file exists

This note records a production issue where some client applications behaved differently over the same Iran-facing x-ui/VLESS/REALITY service:

- v2ray-based clients could reach Google on older tunnel designs such as the XHTTP dual setup.
- NPV Tunnel could not reliably reach Google / YouTube over the initial AnyTLS design.
- After adding an Xray XUDP bridge around the AnyTLS carrier, Google and YouTube began working correctly in NPV Tunnel as well.

When a future tunnel project shows the same symptom, inspect this design before changing DNS, FakeDNS, MTU, SNI, or the public VLESS/REALITY inbound.

## Proven symptom pattern

The initial AnyTLS path was:

```text
User -> x-ui/Xray :443 -> SOCKS 127.0.0.1:7890 -> Mihomo -> AnyTLS A/B -> Foreign -> Internet
```

TCP worked, but UDP round-trip through the local Mihomo SOCKS path failed.

A direct SOCKS5 UDP DNS test through `127.0.0.1:7890` timed out:

```text
RESULT = FAIL
DNS response timed out through Mihomo/AnyTLS
```

At the same time, direct UDP DNS tests on BOTH foreign servers succeeded:

```text
1.1.1.1 UDP OK
8.8.8.8 UDP OK
```

This proved that the foreign VPS/provider UDP path was healthy and isolated the problem to UDP relay through the Iran Mihomo/AnyTLS path.

## The fix that worked

Do not send application UDP directly through Mihomo/AnyTLS.

Insert an Xray XUDP bridge BEFORE Mihomo on Iran and terminate it on localhost on each foreign server.

Final working path:

```text
User
  -> x-ui/Xray public VLESS+REALITY :443
  -> SOCKS 127.0.0.1:7891
  -> Xray XUDP bridge (Iran)
  -> VLESS/XUDP carried as TCP
  -> SOCKS 127.0.0.1:7890
  -> Mihomo load-balance/failover
  -> AnyTLS + ShadowTLS v3 OR AnyTLS + ResTLS over public TCP/443
  -> Foreign Mihomo
  -> localhost 127.0.0.1:2443
  -> Xray XUDP endpoint
  -> Internet
```

Important properties:

- Public user-facing x-ui/Xray inbound remains unchanged on TCP/443.
- Public AnyTLS transport remains unchanged on TCP/443.
- No new public port is opened.
- Foreign XUDP endpoint listens only on `127.0.0.1:2443`.
- Iran XUDP SOCKS endpoint listens only on `127.0.0.1:7891`.
- Mihomo keeps its existing SOCKS backend on `127.0.0.1:7890`.
- UDP/443 is explicitly allowed inside XUDP, which is important for QUIC/YouTube.

## XUDP settings known to work

The successful pattern came from the older XHTTP dual project and was reused here:

```json
"mux": {
  "enabled": true,
  "concurrency": -1,
  "xudpConcurrency": 16,
  "xudpProxyUDP443": "allow"
}
```

The XHTTP dual project had previously used this exact XUDP/mux approach to fix Instagram/YouTube behavior.

## Current implementation in this repository

Branch:

```text
anytls-v1.3.0
```

Project version after the fix:

```text
1.4.2
```

Foreign installation order:

```bash
sudo bash upgrade-xudp-v3.sh foreign-a
sudo bash upgrade-xudp-v3.sh foreign-b
```

Expected success on each foreign:

```text
SUCCESS: Foreign XUDP endpoint active on loopback 127.0.0.1:2443
No public firewall port was added.
```

Then on Iran:

```bash
sudo bash upgrade-xudp-v3.sh iran
```

The Iran script must pass both TCP and UDP tests before switching x-ui to port 7891.

Expected key result:

```text
UDP XUDP TEST = OK
SUCCESS: XUDP bridge active; x-ui now sends to SOCKS5 127.0.0.1:7891
```

## Important implementation detail for modern Xray

Do NOT use the removed/legacy outbound chaining method `proxySettings` for this bridge.

For modern Xray, use:

```json
"streamSettings": {
  "network": "raw",
  "sockopt": {
    "dialerProxy": "anytls-carrier"
  }
}
```

This makes the inner VLESS/XUDP TCP carrier dial through the existing local Mihomo SOCKS outbound.

Also note that Xray detects config format from the filename extension. Temporary config files must still end in `.json`. A temporary file named `xudp-bridge.json.new` failed before parsing with:

```text
Failed to get format
```

The fixed script uses a temporary file whose final suffix is `.json`.

## Do not regress these rules

When applying this fix to another tunnel project:

1. First prove that direct UDP on the foreign VPS works.
2. Then prove that SOCKS5 UDP through the tunnel fails.
3. Only then add the XUDP bridge.
4. Keep XUDP endpoints loopback-only.
5. Do not expose port 2443 publicly.
6. Keep public VLESS/REALITY and AnyTLS camouflage unchanged.
7. Allow UDP/443 inside XUDP (`xudpProxyUDP443: "allow"`).
8. Validate Xray config before service activation.
9. Test both TCP and UDP through the new Iran SOCKS endpoint before changing x-ui.
10. Keep rollback of the x-ui DB/config available before changing the backend port.

## What NOT to misdiagnose first

In this incident, these were investigated but were not the final root cause:

- FakeDNS
- server-side FakeDNS configuration
- IPv6 alone
- DNS resolver choice alone
- QUIC rejection alone
- foreign VPS UDP firewall/provider block

Those checks were still useful, but the decisive test was the SOCKS5 UDP round-trip failure through Mihomo/AnyTLS combined with successful direct UDP on both foreign servers.

## Future-chat shortcut

If the same symptom appears in another project, tell the next chat:

> Check `XUDP-COMPATIBILITY-FIX.md` in `aliiitavazoeiii-afk/frp-tunnel` branch `anytls-v1.3.0`. Reuse the XUDP bridge pattern that fixed Google/YouTube/NPV Tunnel compatibility, but verify the current tunnel's actual UDP failure first.

Do not blindly copy ports or paths if the target project uses different local listeners. Preserve the architecture and safety checks, then adapt the endpoints.
