# Dual Trust + Mieru v1.0.0 — Final Split Architecture

This branch is the final validated dual-tunnel build after production A/B testing.

## Final data path

```text
x-ui public VLESS/REALITY :443
  -> SOCKS 127.0.0.1:7990 (Mihomo health-aware round-robin)
     -> PATH A SOCKS 7991
        TCP -> TrustTunnel SOCKS 7993 -> Trust foreign -> Internet
        UDP -> Xray VLESS/XUDP -> TrustTunnel SOCKS 7993 -> Trust foreign loopback :2443 -> Internet
     -> PATH B SOCKS 7992
        TCP -> Mieru SOCKS 7994 -> Mieru foreign -> Internet
        UDP -> Xray VLESS/XUDP -> Mieru SOCKS 7994 -> Mieru foreign loopback :2443 -> Internet
```

The public-facing x-ui inbound and both outer transports stay unchanged. TCP no longer traverses the inner VLESS/XUDP layer. XUDP is retained only for UDP compatibility, including UDP/443. Load balancing remains connection-level round-robin with full-path health checks.

## Production fixes retained

- Mieru client uses `MULTIPLEXING_OFF`; `MULTIPLEXING_LOW` was measurably unstable.
- Mieru uses `HANDSHAKE_STANDARD` and no traffic pattern; fragment-only traffic pattern was rejected by testing.
- TCP bypasses inner VLESS/XUDP on both Trust and Mieru paths.
- UDP continues through VLESS/XUDP with `xudpConcurrency=16` and UDP/443 allowed.
- Trust XUDP uses the proven `xudp-trust.internal` loopback hostname pattern.
- Mieru foreign requires close clock synchronization; the final installer requests NTP automatically.
- Mieru foreign replacement keeps `MULTIPLEXING_OFF` and validates both TCP and UDP/XUDP.
- Final Iran installation runs strict repeated TCP/UDP tests before x-ui is attached.

## Pinned releases

- TrustTunnel endpoint `v1.0.33`
- TrustTunnel CLI client `v1.0.49`
- Mieru / mita `v3.37.0`
- Mihomo `v1.19.31`
- Xray-core `v26.9.8`

## Canonical branch

```text
dual-trust-mieru-v1-final
```

Use `install-iran-final.sh`, not the legacy `install-iran.sh`, for new Iran installations. The final wrapper validates and transforms the legacy rc15 template into the production-tested split architecture before activation.

## Fresh deployment order

1. Install Trust foreign with `install-foreign-trust.sh`.
2. Install Mieru foreign with `install-foreign-mieru-final.sh`.
3. Copy `/root/dual-trust-client.json` and `/root/dual-mieru-client.json` to Iran without exposing their contents.
4. Run `install-iran-final.sh` on Iran.
5. Verify `dual-tunnel-probe --full`.
6. Only then run `attach-xui.sh` on Iran.

## Iran ports

- `7990`: dual dispatcher entry for x-ui
- `7991`: forced Trust split path (TCP direct, UDP XUDP)
- `7992`: forced Mieru split path (TCP direct, UDP XUDP)
- `7993`: TrustTunnel local SOCKS carrier
- `7994`: Mieru local SOCKS carrier
- `19090`: loopback Mihomo controller

## Foreign endpoints

Each foreign Xray endpoint listens only on `127.0.0.1:2443`. Do not expose `2443` publicly.

Trust uses HTTP/2 TLS on public TCP/443. Mieru uses its configured public TCP range, normally `20000-20020`.

## Replacing one foreign later

Generate the new foreign bundle, transfer it to Iran, then use:

```bash
sudo dual-tunnel-replace-foreign trust /root/new-trust-bundle.json
# or
sudo dual-tunnel-replace-foreign mieru /root/new-mieru-bundle.json
```

The helper backs up the live config, restarts only the affected carrier plus shared split/XUDP router, and validates TCP plus UDP/XUDP before declaring success.

## Safety rules

- Never paste client bundles into chat or a repository.
- Do not run `uninstall-iran.sh` while x-ui is attached to `127.0.0.1:7990`.
- Do not expose foreign loopback XUDP port `2443` publicly.
- Do not re-enable Mieru `MULTIPLEXING_LOW` without a new controlled A/B test.
- Do not put normal TCP traffic back through inner VLESS/XUDP unless a new controlled test proves a reason to do so.
