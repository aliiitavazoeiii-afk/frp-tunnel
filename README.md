# AnyTLS Tunnel v1.4.0 — x-ui + XUDP bridge mode

Three-node backend tunnel for an existing x-ui/Xray deployment:

- Foreign A: AnyTLS + ShadowTLS v3 on TCP/443
- Foreign B: AnyTLS + ResTLS on TCP/443
- Iran: Mihomo sticky load-balance/failover backend
- XUDP bridge: pinned Xray v26.3.27 carries client UDP (including QUIC/UDP 443) inside TCP before it enters AnyTLS
- x-ui/Xray stays user-facing and keeps the existing VLESS/REALITY users and public port 443.

## Why the XUDP bridge exists

Direct SOCKS UDP through the current Mihomo/AnyTLS path can send UDP requests while failing to return UDP replies on some deployments. The XUDP bridge avoids that path entirely: Xray aggregates UDP into XUDP carried over an inner VLESS/TCP connection, and AnyTLS only sees TCP.

The XUDP settings intentionally match the previously proven YouTube/Instagram fix:

```json
{
  "enabled": true,
  "concurrency": -1,
  "xudpConcurrency": 16,
  "xudpProxyUDP443": "allow"
}
```

`concurrency: -1` means ordinary TCP is not Muxed; XUDP is used for UDP.

## Traffic path after v1.4.0 upgrade

```text
User
  -> x-ui/Xray Iran :443
  -> SOCKS 127.0.0.1:7891 (Xray XUDP bridge)
  -> inner VLESS/XUDP over TCP
  -> SOCKS 127.0.0.1:7890 (Mihomo AnyTLS carrier)
  -> AnyTLS A/B sticky load-balance/failover
  -> Foreign Mihomo
  -> 127.0.0.1:2443 (Foreign Xray XUDP endpoint)
  -> Internet
```

The Foreign XUDP endpoint is loopback-only. No new public port is opened.

## Existing install

Base install remains:

```bash
sudo bash setup.sh foreign-a
sudo bash setup.sh foreign-b
sudo bash setup.sh iran
```

For an existing v1.3.x deployment, update the branch and apply the XUDP upgrade in this order:

```bash
# Foreign A
sudo bash upgrade-xudp.sh foreign-a

# Foreign B
sudo bash upgrade-xudp.sh foreign-b

# Iran, only after both Foreign upgrades succeeded
sudo bash upgrade-xudp.sh iran
```

The Iran upgrade is fail-closed:

1. Installs and validates the Xray bridge.
2. Tests TCP through `127.0.0.1:7891` and expects HTTP 204.
3. Tests a real UDP DNS round-trip through `127.0.0.1:7891`.
4. Only if both tests succeed, backs up the x-ui database and changes the existing `anytls-tunnel` SOCKS outbound from port `7890` to `7891`.
5. If x-ui fails to restart or the runtime config does not contain `7891`, the x-ui database is restored automatically.

Run after upgrade:

```bash
sudo anytls-xudp-health
sudo anytls-tunnel-health
```

Then disconnect/reconnect the client and test YouTube/Shorts.

## Safety

- Mihomo pinned to v1.19.30 and SHA-256 verified.
- Xray bridge pinned to v26.3.27 and SHA-256 verified.
- Candidate XUDP config validated with `xray run -test` before activation.
- Existing public x-ui/Xray listener on TCP/443 is not replaced.
- Mihomo SOCKS/controller and both XUDP endpoints are loopback-only.
- Foreign nodes still expose only AnyTLS TCP/443 for this project.
- No new provider firewall rule is required for XUDP.
- Iran x-ui routing is changed only after end-to-end TCP and UDP bridge tests pass.
- x-ui DB snapshot is stored under `/var/lib/anytls-tunnel/backups/` before switching the outbound.
