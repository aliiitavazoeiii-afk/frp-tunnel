# AnyTLS Tunnel v1.3.0 — x-ui mode

Three-node backend tunnel for an existing x-ui/Xray deployment:

- Foreign A: AnyTLS + ShadowTLS v3 on TCP/443
- Foreign B: AnyTLS + ResTLS on TCP/443
- Iran: Mihomo local SOCKS5 backend + sticky load-balance/failover
- x-ui/Xray stays user-facing and keeps the existing VLESS/REALITY users and port 443.

## Traffic path

`User -> x-ui/Xray (Iran :443) -> SOCKS5 127.0.0.1:7890 -> Mihomo -> Foreign A/B -> Internet`

Mihomo does not bind public port 443 on the Iran role, so it does not conflict with x-ui. The SOCKS backend is loopback-only and has UDP enabled.

## YouTube / QUIC safe mode

Default `QUIC_SAFE_MODE=true` rejects proxied UDP destination port 443 inside Mihomo, causing browsers/video apps to fall back to HTTPS over TCP instead of carrying QUIC through AnyTLS UDP-over-TCP. Other UDP remains allowed.

## Installation

Clone branch `anytls-v1.3.0` on each server and run:

```bash
sudo bash setup.sh foreign-a
sudo bash setup.sh foreign-b
sudo bash setup.sh iran
```

After the Iran backend is healthy, configure Xray/x-ui with a SOCKS outbound to `127.0.0.1:7890` and route user traffic to that outbound.

## Safety

- Mihomo pinned to v1.19.30 and SHA-256 verified.
- Candidate config validated with `mihomo -t` before activation.
- systemd auto-restart and rollback support.
- Controller and SOCKS backend bind only to 127.0.0.1.
- Foreign nodes expose only TCP/443 for this service.
- Secrets saved mode 0600.
- Health checks use expected HTTP 204.
