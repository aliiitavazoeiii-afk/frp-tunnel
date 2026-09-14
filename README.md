# AnyTLS Tunnel v1.2.0

Three-node censorship-resilient tunnel:

- Foreign A: AnyTLS + ShadowTLS v3 on TCP/443
- Foreign B: AnyTLS + ResTLS on TCP/443
- Iran: VLESS/REALITY user ingress + Mihomo sticky load-balance/failover

## User traffic path

`VLESS/REALITY user -> Iran Mihomo -> TUNNEL group -> Foreign A or Foreign B -> Internet`

No Xray-to-SOCKS middle layer is required. The Iran node can reuse an existing VLESS UUID, REALITY private key, SNI and short-id so existing user URIs remain unchanged, provided the hostname resolves to the new Iran server and the private key matches the public key already present in users' URIs.

## YouTube / QUIC safe mode

The Iran setup asks whether to enable QUIC-safe mode. Default is yes. It rejects proxied UDP/443 so browsers and video apps fall back to HTTPS over TCP instead of carrying QUIC inside AnyTLS UDP-over-TCP. Other UDP is still allowed.

## Installation

Clone branch `anytls-v1.2.0` on each server and run one role:

```bash
sudo bash setup.sh foreign-a
sudo bash setup.sh foreign-b
sudo bash setup.sh iran
```

Foreign roles generate their own secrets locally. Copy only the displayed text values into the Iran setup. No files need to be transferred between servers.

## Safety

- Mihomo pinned to v1.19.30 and SHA-256 verified.
- Candidate config validated with `mihomo -t` before activation.
- systemd auto-restart.
- Backup/rollback support.
- Controller and local mixed proxy bind only to 127.0.0.1.
- Secrets saved mode 0600.
- Health check uses `https://www.gstatic.com/generate_204`, expected HTTP 204.
