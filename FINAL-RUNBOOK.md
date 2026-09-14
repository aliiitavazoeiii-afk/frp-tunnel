# AnyTLS Tunnel v1.5.0 — Final Runbook

This is the production runbook for the final 3-node AnyTLS + XUDP architecture.

## Architecture

```text
Users
  -> x-ui/Xray Iran public :443 (existing VLESS/REALITY users stay unchanged)
  -> SOCKS 127.0.0.1:7891 (Xray XUDP bridge)
  -> inner VLESS/XUDP over TCP
  -> SOCKS 127.0.0.1:7890 (Mihomo carrier)
  -> sticky load-balance / failover
       F1: AnyTLS + ShadowTLS v3 -> Foreign A :443
       F2: AnyTLS + ResTLS      -> Foreign B :443
  -> Foreign Xray XUDP endpoint 127.0.0.1:2443
  -> Internet
```

Public exposure:

- Iran: existing x-ui/Xray TCP/443 only.
- Foreign A/B: AnyTLS TCP/443 only.
- 7890, 7891, 9090, and 2443 are loopback-only.

The XUDP layer is mandatory in final mode because it fixed the confirmed NPV Tunnel / Google / YouTube compatibility failure. See `XUDP-COMPATIBILITY-FIX.md`.

## Fresh installation order

Prerequisite on Iran: x-ui/Xray must already be installed with the desired public VLESS/REALITY inbound on TCP/443.

Always install in this order:

1. Foreign A
2. Foreign B
3. Iran

Clone command on each fresh server:

```bash
sudo rm -rf /opt/anytls-tunnel
sudo git clone -b anytls-v1.3.0 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/anytls-tunnel
cd /opt/anytls-tunnel
```

### Foreign A / F1

```bash
sudo bash setup-final.sh foreign-a
```

Save the printed values:

- `COVER_HOST_A`
- `ANYTLS_PASS_A`
- `SHADOWTLS_PASS_A`

Expected final state:

- AnyTLS + ShadowTLS v3 on public TCP/443
- XUDP endpoint on `127.0.0.1:2443`

### Foreign B / F2

```bash
sudo bash setup-final.sh foreign-b
```

Save the printed values:

- `COVER_HOST_B`
- `ANYTLS_PASS_B`
- `RESTLS_PASS_B`

Expected final state:

- AnyTLS + ResTLS on public TCP/443
- XUDP endpoint on `127.0.0.1:2443`

### Iran

```bash
sudo bash setup-final.sh iran
```

Enter:

- Foreign A public IP/hostname
- Foreign B public IP/hostname
- the cover hostnames and secrets printed by both Foreign installers

The installer creates the Mihomo backend, XUDP bridge, validates TCP and UDP/XUDP, and only then switches the existing x-ui outbound to `127.0.0.1:7891`.

Expected listeners:

```text
public :443     = x-ui/Xray
127.0.0.1:7890 = Mihomo SOCKS carrier
127.0.0.1:7891 = Xray XUDP SOCKS bridge
127.0.0.1:9090 = Mihomo controller
```

Health commands:

```bash
sudo anytls-xudp-health
sudo anytls-tunnel-health
```

## Safe node replacement

The final Iran installer installs:

```bash
sudo anytls-replace
```

This command is used when F1 or F2 is filtered, degraded, or intentionally replaced.

Important: first prepare the new Foreign server with the same role.

For a new F1 server:

```bash
sudo rm -rf /opt/anytls-tunnel
sudo git clone -b anytls-v1.3.0 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/anytls-tunnel
cd /opt/anytls-tunnel
sudo bash setup-final.sh foreign-a
```

For a new F2 server:

```bash
sudo rm -rf /opt/anytls-tunnel
sudo git clone -b anytls-v1.3.0 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/anytls-tunnel
cd /opt/anytls-tunnel
sudo bash setup-final.sh foreign-b
```

Then on the Iran server run:

```bash
sudo anytls-replace
```

Choose F1 or F2 and enter the new server address, cover hostname, and credentials printed by the new Foreign installer.

Before production is changed, `anytls-replace` starts isolated temporary Mihomo + Xray probe paths and requires both:

- HTTP `204` through the new AnyTLS + XUDP path
- a real UDP DNS round-trip through the new AnyTLS + XUDP path

Only after both probes pass is the production node replaced. Production config/env files are backed up first. If activation or post-activation verification fails, the previous production config is restored.

`anytls-replace` does not modify:

- x-ui users
- the public x-ui inbound
- the XUDP bridge configuration
- the other Foreign node

## Compatibility settings that must not regress

XUDP mux settings:

```json
{
  "enabled": true,
  "concurrency": -1,
  "xudpConcurrency": 16,
  "xudpProxyUDP443": "allow"
}
```

Xray chaining must use current `streamSettings.sockopt.dialerProxy`, not removed/legacy `proxySettings` chaining.

Foreign XUDP endpoint must remain loopback-only on `127.0.0.1:2443`.

## Current pinned components

- Mihomo: `v1.19.30`
- Xray bridge: `v26.3.27`

Both installers verify pinned SHA-256 values before activation.

## Related files

- `setup-final.sh` — fresh final installation wrapper
- `replace-node.sh` — safe F1/F2 replacement implementation
- `upgrade-xudp-v3.sh` — XUDP compatibility upgrade for older deployments
- `XUDP-COMPATIBILITY-FIX.md` — diagnosis and Google/YouTube/NPV compatibility history
- `FINAL-RUNBOOK.md` — this file
