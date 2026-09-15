# AnyTLS Tunnel v1.6.0 — FINAL x-ui + XUDP + remote-DNS mode

Production 3-node backend tunnel for an existing x-ui/Xray deployment:

- Foreign A / F1: AnyTLS + ShadowTLS v3 on public TCP/443
- Foreign B / F2: AnyTLS + ResTLS on public TCP/443
- Iran: Mihomo sticky load-balance/failover backend
- Mandatory XUDP compatibility bridge: pinned Xray v26.3.27
- Existing x-ui/Xray remains user-facing on TCP/443 and keeps existing VLESS/REALITY users.

## Final proven Iran state

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

Why `AsIs`: production testing showed some YouTube/Instagram CDN hostnames failed when locally resolved on the Iran server but worked immediately when the hostname was resolved through the proxy path. Sniffing recovers the hostname on the public inbound; `AsIs` preserves it into the local SOCKS/XUDP path so resolution happens remotely rather than through poisoned/local Iran DNS.

## Final traffic path

```text
User
  -> x-ui/Xray Iran :443
  -> sniff hostname
  -> SOCKS 127.0.0.1:7891, AsIs
  -> Xray XUDP bridge
  -> inner VLESS/XUDP over TCP
  -> SOCKS 127.0.0.1:7890 (Mihomo AnyTLS carrier)
  -> AnyTLS sticky A/B failover
  -> Foreign A/B public TCP/443
  -> Foreign Xray XUDP endpoint 127.0.0.1:2443
  -> Internet
```

No extra public XUDP port is opened. Foreign `2443`, Iran `7890`, `7891`, and `9090` are loopback-only.

## Fresh installation

Install in this order: Foreign A -> Foreign B -> Iran.

On each fresh server:

```bash
sudo rm -rf /opt/anytls-tunnel
sudo git clone -b anytls-v1.3.0 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/anytls-tunnel
cd /opt/anytls-tunnel
```

Foreign A / F1:

```bash
sudo bash setup-final.sh foreign-a
```

Foreign B / F2:

```bash
sudo bash setup-final.sh foreign-b
```

Iran, after x-ui/Xray already exists and the public VLESS/REALITY inbound is listening on TCP/443:

```bash
sudo bash setup-final.sh iran
```

The final Iran installer enforces `QUIC_SAFE_MODE=false`, builds and validates XUDP, bootstraps the x-ui outbound/routing if missing, enables sniffing on only the public :443 inbound, switches the x-ui SOCKS outbound to `127.0.0.1:7891`, sets `targetStrategy=AsIs`, then runs the final health check.

## Final health check

On any node:

```bash
sudo anytls-final-health
```

Iran validation includes:

- `anytls-tunnel`, `anytls-xudp-bridge`, and `x-ui` service state
- listeners `443`, `7890`, `7891`, `9090`
- x-ui route to `anytls-tunnel`
- `sniffing=ON`
- `targetStrategy=AsIs`
- real UDP DNS round-trip over XUDP
- remote-resolution probes for gstatic, YouTube image CDN, and Instagram
- per-node Mihomo controller health for F1/F2

Legacy helpers remain available where installed:

```bash
sudo anytls-xudp-health
sudo anytls-tunnel-health
```

## Replace a filtered F1/F2

First install the replacement Foreign server with the same role:

```bash
sudo bash setup-final.sh foreign-a
```

or:

```bash
sudo bash setup-final.sh foreign-b
```

Then on Iran:

```bash
sudo anytls-replace
```

Choose F1 or F2 and enter the replacement node values. The replacement workflow probes the new node before activation and rolls back if activation fails. It does not change x-ui users, the public VLESS/REALITY inbound, the other Foreign node, or the final `sniffing + AsIs` x-ui state.

## Uninstall

Normal uninstall, preserving AnyTLS backups and `/root/anytls-*.env` for possible reinstall:

```bash
sudo anytls-uninstall
```

Full purge of AnyTLS state/backups and role env files:

```bash
sudo anytls-uninstall --purge
```

On Iran, uninstall keeps x-ui and all x-ui users. It removes only the `anytls-tunnel` outbound/routing owned by this project, then removes AnyTLS/XUDP services and files. A safety copy of the x-ui DB is written under `/root/` before the x-ui cleanup. Public inbound sniffing is intentionally left unchanged because it is an x-ui inbound setting and may be useful independently.

Foreign firewall/provider TCP/443 allow rules are intentionally not deleted automatically because that port may be reused.

## Compatibility history

The project originally used direct SOCKS UDP through Mihomo/AnyTLS. Real UDP return traffic failed on some deployments. Adding an Xray XUDP bridge fixed Google/YouTube compatibility for NPV Tunnel. Later production testing showed that `ForceIPv4` caused local Iran DNS resolution for some CDN hostnames; `sniffing=ON + targetStrategy=AsIs` fixed YouTube/Instagram CDN resolution by preserving hostnames for remote resolution.

See `XUDP-COMPATIBILITY-FIX.md` for the earlier XUDP diagnosis.

## Pinned versions

- Mihomo `v1.19.30`
- Xray `v26.3.27`

Candidate configs are validated before activation and downloaded binaries are SHA-256 verified.
