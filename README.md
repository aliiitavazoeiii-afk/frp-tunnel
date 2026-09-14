# AnyTLS Tunnel v1.5.0 — FINAL x-ui + XUDP mode

Production 3-node backend tunnel for an existing x-ui/Xray deployment:

- Foreign A / F1: AnyTLS + ShadowTLS v3 on public TCP/443
- Foreign B / F2: AnyTLS + ResTLS on public TCP/443
- Iran: Mihomo sticky load-balance/failover backend
- Mandatory XUDP compatibility bridge: pinned Xray v26.3.27
- Existing x-ui/Xray remains user-facing on TCP/443 and keeps the existing VLESS/REALITY users.

## Final traffic path

```text
User
  -> x-ui/Xray Iran :443
  -> 127.0.0.1:7891 (Xray XUDP bridge)
  -> inner VLESS/XUDP over TCP
  -> 127.0.0.1:7890 (Mihomo carrier)
  -> AnyTLS sticky A/B failover
  -> Foreign A/B :443
  -> 127.0.0.1:2443 (Foreign Xray XUDP endpoint)
  -> Internet
```

No extra public XUDP port is opened. Foreign `2443`, Iran `7890`, `7891`, and `9090` are loopback-only.

## Why XUDP is mandatory

A production compatibility failure was confirmed where direct SOCKS UDP through Mihomo/AnyTLS sent UDP requests but failed to return replies. This caused Google/YouTube failures in NPV Tunnel even when older v2ray/XHTTP paths worked.

The proven fix is:

```json
{
  "enabled": true,
  "concurrency": -1,
  "xudpConcurrency": 16,
  "xudpProxyUDP443": "allow"
}
```

See `XUDP-COMPATIBILITY-FIX.md` for the full diagnosis.

## Final fresh installation

Install in this order: Foreign A -> Foreign B -> Iran.

On every fresh server:

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

Iran, after x-ui/Xray already exists on public TCP/443:

```bash
sudo bash setup-final.sh iran
```

The Iran installer performs TCP + real UDP/XUDP validation before switching x-ui to `127.0.0.1:7891`.

## Health

```bash
sudo anytls-xudp-health
sudo anytls-tunnel-health
```

## Replace filtered F1/F2

First install the new Foreign server using the same final role installer. Then on Iran run:

```bash
sudo anytls-replace
```

Choose F1 or F2 and enter the new server IP/hostname, cover hostname, and credentials printed by the new Foreign installer.

`anytls-replace` probes the new node through an isolated temporary AnyTLS + XUDP path and requires both HTTP 204 and a real UDP DNS round-trip before production is changed. If activation fails, the previous production config/env is restored.

It does not change x-ui users, the public inbound, the XUDP bridge, or the other Foreign node.

## Existing older deployment

For an already installed v1.3.x/v1.4.x deployment, the XUDP compatibility upgrade remains:

```bash
sudo bash upgrade-xudp-v3.sh foreign-a
sudo bash upgrade-xudp-v3.sh foreign-b
sudo bash upgrade-xudp-v3.sh iran
```

Then install the replacement command on Iran:

```bash
sudo install -m 0755 replace-node.sh /usr/local/sbin/anytls-replace
```

## Pinned versions

- Mihomo `v1.19.30`
- Xray `v26.3.27`

Candidate configs are validated before activation and binaries are SHA-256 verified.

## Full operational documentation

Read `FINAL-RUNBOOK.md` for fresh installation, recovery, replacement, and non-regression rules.
