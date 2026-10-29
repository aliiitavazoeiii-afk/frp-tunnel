# Dual HA v2 staging — Custom Backhaul V2 + Mieru TCP

**Dedicated foreign hosts:** Backhaul V2 \`152.237.230.159\`; Mieru TCP \`152.237.230.248\`.
**Current Iran users:** Reality/X-UI on public TCP/443. **Do not change the existing inbound, UUID, Reality key, fingerprint, or user config.**

## Safety / current scope

This is an ISOLATED staging build; **not production-ready** and not validated on your real VPSs. Both transports and an end-to-end health-controlled HAProxy SOCKS5 gateway are included. The final Xray outbound/routing integration is **intentionally not automatic**, because it needs a live, redacted inspection of your specific x-ui/Xray configuration and a reversible canary rollout. No script replaces /etc/haproxy/haproxy.cfg or binds Iran public TCP/443.

Failure of one transport does **not** migrate a currently active TCP connection without interruption. Existing streams break and applications must reconnect; do not promise zero video freezes. New streams can use the surviving transport after health confirmation.

This is based on the **actual pinned Backhaul v0.7.2-derived Custom V2 source and patchset**. Because TCP/443 is occupied by existing Reality, its public carrier uses TCP/18443, and HAProxy (HTTP mode) replaces the prior nginx plain-HTTP decoy router. This is an adaptation, **not the exact network profile tested in August 2026**. DPI resistance and performance must be independently assessed.

## Topology

\`\`\`
Existing client -> Iran Xray REALITY :443 (unchanged)
                  [FUTURE: selective outbound via local SOCKS5]
   -> HAProxy 127.0.0.1:18080  (starts with BOTH paths disabled)
      |-- :21001 SOCKS5 -> local custom Backhaul V2 WSMux -> Foreign-1 Dante SOCKS5 :11080 (loopback) -> Internet
      |      Foreign-1 => Iran :18443/TCP, TLS/stunnel => HAProxy HTTP decoy => WSMux loopback
      |
      +-- :21002 SOCKS5 -> Mieru TCP (multiplexing OFF) -> Foreign-2 Mita :28443/TCP -> Internet
\`\`\`

The paths have independent machines, transport protocols, binaries, and credentials. The Iranian ingress on :443 is independent of this staging setup.

## Prerequisites

- Root shell on each Ubuntu/Debian amd64 host.
- Two fresh foreign VPSs with SSH reachability. Do not run these installers on an existing configured Mita/Dante service.
- On the Iran VPS, have one **NEW DNS-only** hostname \`YOUR_BH_DOMAIN\` with A record pointing to the Iran public IPv4. E.g. \`bh-new.example.com\` is only a placeholder, NOT a live DNS record.
- Need TCP/18443 inbound on Iran from Foreign-1 and TCP/28443 inbound on Foreign-2 from Iran (provider firewall + UFW).
- Port 80 on Iran free for Certbot initial certificate, or an existing valid certificate at \`/etc/letsencrypt/live/YOUR_BH_DOMAIN/\`.
- Ubuntu 24.04 / Go build external connectivity to GitHub, go.dev and proxy.golang.org.

## 0. Pull source safely

On Iran, where the original repo may have been cloned twice:

\`\`\`bash
cd /root/frp-tunnel/frp-tunnel   # or the directory containing this repository
git branch --show-current       # must be dual-backhaul-mieru-ha
git pull --ff-only
cd dual-backhaul-mieru-ha/v2
\`\`\`

On each foreign host:

\`\`\`bash
git clone --depth 1 --branch dual-backhaul-mieru-ha https://github.com/aliiitavazoeiii-afk/frp-tunnel.git
cd frp-tunnel/dual-backhaul-mieru-ha/v2
\`\`\`

## 1. Foreign-2: install isolated Mita TCP

First get the Iran public IP ON IRAN:

\`\`\`bash
curl -4fsS https://api.ipify.org; echo
\`\`\`

On Foreign-2 \`152.237.230.248\`:

\`\`\`bash
sudo bash foreign-mieru.sh YOUR_IRAN_PUBLIC_IP
\`\`\`

This downloads release **Mieru/Mita v3.39.0** with official SHA256, generates one random secret, starts \`dual-ha-mita\`, binds 28443/TCP only and restricts UFW ingress to the Iran IP if UFW is active.

Now ON IRAN copy the private bundle directly:

\`\`\`bash
scp root@152.237.230.248:/etc/dual-ha/mieru-bundle.env /root/dual-ha-mieru-bundle.env
chmod 600 /root/dual-ha-mieru-bundle.env
sudo bash iran-mieru.sh /root/dual-ha-mieru-bundle.env
\`\`\`

The result MUST show \`ip=\` on HTTPS egress via \`127.0.0.1:21002\`. Do not paste the bundle or passwords into chat.

## 2. Iran: build and deploy isolated Backhaul V2 WSS

Still on Iran:

\`\`\`bash
sudo bash build-backhaul.sh
sudo bash iran-backhaul.sh YOUR_BH_DOMAIN
\`\`\`

The build fetches pinned upstream commit + all three Custom V2 patches, executes Go tests, and writes ONLY \`/opt/dual-ha/bin/backhaul\`. It never overwrites \`/usr/local/bin/backhaul\`.

The Iran installer uses its own services \`dual-ha-backhaul\`, \`dual-ha-backhaul-router\`, \`dual-ha-backhaul-tls\`. It serves the external TLS carrier on **TCP/18443**, not :443. It generates a private bundle in \`/etc/dual-ha/backhaul-bundle.env\`.

## 3. Foreign-1: install Backhaul reverse client + SOCKS egress

ON IRAN transfer the bundle:

\`\`\`bash
scp /etc/dual-ha/backhaul-bundle.env root@152.237.230.159:/root/dual-ha-backhaul-bundle.env
\`\`\`

On Foreign-1 \`152.237.230.159\`:

\`\`\`bash
cd /root/frp-tunnel/dual-backhaul-mieru-ha/v2
sudo bash build-backhaul.sh
sudo bash foreign-backhaul.sh /root/dual-ha-backhaul-bundle.env
\`\`\`

Check on Iran:

\`\`\`bash
curl --socks5-hostname 127.0.0.1:21001 -fsS --max-time 15 \
  https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='
\`\`\`

This should report Foreign-1's egress IP (may differ from public IP under provider NAT).

## 4. On Iran: switch ONLY the isolated staging gateway

Disable the earlier empty test gateway if it is still running:

\`\`\`bash
sudo systemctl disable --now dual-ha-health dual-ha-haproxy
sudo bash install-gateway.sh
sleep 50
sudo bash staging-smoke.sh
\`\`\`

The HAProxy backend servers start **disabled**. Every 8 seconds the health controller makes real HTTPS requests using each SOCKS5 upstream. Two of three destinations must succeed; after five successful probe rounds, that path is enabled. After three failed rounds, the path is disabled. It does NOT send production traffic before this gate.

View current state:

\`\`\`bash
cat /run/dual-ha-v2/health.json
journalctl -u dual-ha-v2-health --since '15 minutes ago' --no-pager
\`\`\`

## 5. Failure-injection smoke tests (STAGING ONLY)

With *no existing customers routed to this staging gateway*, stop Mita on Foreign-2:

\`\`\`bash
sudo systemctl stop dual-ha-mita
\`\`\`

After repeated probes, Iran's \`/run/dual-ha-v2/health.json\` should show Mieru disabled, while HTTPS via \`127.0.0.1:18080\` continues via Backhaul. Then restore on Foreign-2:

\`\`\`bash
sudo systemctl start dual-ha-mita
\`\`\`

Repeat similarly by stopping/starting \`dual-ha-backhaul-client\` on Foreign-1.

**Do not run forced outages after moving production traffic!**

## 6. Before any production traffic

- Run 72h with a realistic representative load; capture disconnects, packet retransmissions, YouTube video QoE, RTT, and DNS results.
- Test several networks/operators from within Iran, including both HTTPS egress and a full Reality client path (the latter not installed automatically).
- Check the source IP returned by \`curl ... /cdn-cgi/trace\` on both upstreams and ensure they are different.
- Confirm two transports survive reboot and rapid shutdown of the other foreign VPS.
- Record initial x-ui/Xray config and DB backups, build a canary outbound for test users, validate billing/traffic accounting, and prepare a one-command revert. Existing inbound :443 + client configs must remain identical.
- DNS and valid certificate for WSS are required. Because the Iran public :443 remains Xray, the Backhaul TLS carrier on :18443 can be more conspicuous to filtering than ordinary HTTPS; no DPI immunity claim.

## Status

CI tests include Bash syntax, Python controller unit tests, and HAProxy configuration validation on Ubuntu 24.04. CI does NOT test actual foreign connectivity, DPI resistance, or video playback. **Do not consider staging CI success proof of customer-grade reliability.**
