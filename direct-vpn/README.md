# Direct VPN — NaiveProxy

Branch: `direct-vpn`  
Target VPS: `193.57.9.80`  
Version: `1.0.0`

This branch installs a direct-to-foreign NaiveProxy endpoint on TCP/443. It is deliberately isolated from the existing Trust/Mieru/VLESS tunnel stack.

## Design

```text
Client
  -> HTTPS / HTTP2 / TCP 443
  -> Caddy + klzgrad/forwardproxy naive fork
  -> direct Internet egress from 193.57.9.80
```

The client-facing endpoint is kept stable so the same `domain / username / password / 443` can later be reused on a tunnel backup server. The installer exports `/root/direct-naive-client.json` with mode `0600`; never commit that file.

### Fingerprint strategy

Do **not** invent a fixed custom TLS fingerprint. NaiveProxy's advantage is reusing Chromium's network stack on the client. A unique TLS signature would make classification easier. This branch instead adds per-deployment randomized encrypted front-page asset paths and a realistic multi-resource web front, while keeping the TLS/HTTP behavior standards-based.

The server uses:
- pinned verified `klzgrad/forwardproxy` Naive Caddy release;
- `probe_resistance`;
- `hide_ip` and `hide_via`;
- compression on the front page;
- no access logging configured;
- non-root systemd service with only `CAP_NET_BIND_SERVICE`;
- fail-closed checks if TCP/80 or TCP/443 are already occupied;
- DNS verification before ACME/certificate startup.

## First deployment

Create a clean hostname. Recommended neutral name:

```text
edge3.biya2film.top  A  193.57.9.80
```

Do not proxy it through a CDN for the first direct test. Wait until public DNS resolves to `193.57.9.80`.

Then on the VPS:

```bash
sudo apt-get update && sudo apt-get install -y git && \
sudo rm -rf /opt/frp-tunnel && \
sudo git clone --depth 1 --branch direct-vpn --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel && \
cd /opt/frp-tunnel/direct-vpn && \
sudo bash install.sh --public-ip 193.57.9.80 --domain edge3.biya2film.top
```

Health check:

```bash
cd /opt/frp-tunnel/direct-vpn
sudo bash health.sh
```

Show the private client bundle only on the server:

```bash
sudo cat /root/direct-naive-client.json
```

The `share_link` field is in the NekoBox-style standard form:

```text
naive+https://USER:PASSWORD@edge3.biya2film.top:443#direct-vpn
```

The generic official Naive endpoint is also stored as `proxy_url`:

```text
https://USER:PASSWORD@edge3.biya2film.top:443
```

## Front-profile rotation

This changes only the encrypted public web content and its resource paths. It does not change the user config, TLS hostname, username or password.

```bash
cd /opt/frp-tunnel/direct-vpn
sudo bash rotate-front.sh
```

Do not rotate aggressively. The purpose is to avoid shipping one static decoy resource profile forever, not to create a rapid-changing signature.

## Future server-side failover

Keep `/root/direct-naive-client.json`. On a future backup server, reuse the same username/password so users keep one config. The direct installer already supports:

```bash
sudo bash install.sh \
  --public-ip BACKUP_IP \
  --domain edge3.biya2film.top \
  --reuse-bundle /root/direct-naive-client.json
```

Important: this direct installer requires TCP/443 to be free. Existing tunnel servers that already run VLESS/REALITY on 443 need an SNI/TCP router integration instead of running this installer directly. That backup integration should be added separately so the existing tunnel users are not interrupted.

## Uninstall

```bash
sudo bash uninstall.sh
```

The private bundle is preserved by default. To remove it too:

```bash
sudo bash uninstall.sh --purge-bundle
```
