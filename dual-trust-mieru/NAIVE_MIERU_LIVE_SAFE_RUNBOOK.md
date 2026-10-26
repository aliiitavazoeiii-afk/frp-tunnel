# Naive + Mieru: live-safe migration runbook (v1)

Base branch: `triple-carrier-naive` commit `9cc755bab9cac5399c940a5751069ac415b37611`. Existing Iran production is the already-deployed **Dual Trust/Mieru** topology, with split TCP direct and UDP over XUDP. No use of the legacy Triple migration that restarts x-ui.

**STRICT INVARIANT:** Never restart x-ui, dual-mieru-carrier, dual-xudp-bridge or dual-dispatcher as part of Naive preparation or port swap. Never edit their live config. Public VLESS+REALITY TCP/443 and UUIDs remain unchanged. Users currently on Mieru must not be disconnected.

## Known limitations

- The initial port swap requires stopping the **broken Trust client only**, then Naive binds **the same loopback 7993**. Xray split 7991 already routes TCP via the 7993 SOCKS dialer and UDP/XUDP through it to `xudp-trust.internal:2443`. The new Foreign Caddy explicitly supports the legacy internal XUDP hostname. The live bridge and dispatcher stay up.
- During the zero-reload stage, Mihomo **still names the Naive leg `XUDP-TRUST` internally** and keeps sticky-sessions. Operator commands `dual status` and `dual health` show Naive/Mieru instead. The old client service is disabled, not automatically deleted.
- `nm-pool-balance.py` can change the internal names to Naive/Mieru and choose `round-robin` with 60-second eager checks. It **refuses to apply while there are ANY active dispatcher connections**, because even a non-force local Mihomo config reload has not been proven to preserve pre-existing Mieru streams in this production build. Do not bypass the guard.
- Round-robin aims at **50/50 new connection selections**, not 50/50 bytes or users. This may change exit IP between Telegram connections. Health failures temporarily shift allocation to the healthy carrier.
- Neither Naive nor any particular TLS/Caddy version guarantees immunity to blocking. Track forced-path success and realistic Telegram user experience over time.

## New Foreign VPS (not existing Mieru or old Trust)

Provision new Ubuntu VPS. Have NEW_IP, a distinct NEW_DOMAIN with its DNS A record pointing to NEW_IP, and an ACME contact EMAIL. Verify the new server's SSH host fingerprint out-of-band. Do not paste bundle, UUID, password or real controller token in chat or GitHub.

On IRAN, copy the **existing Trust XUDP UUID** securely to the new Foreign (it is only reused for the leg being replaced; Mieru UUID is never modified):

```bash
sudo install -d -m 0700 /root
sudo sh -c 'umask 077; jq -er '\''.outbounds[]|select(.tag=="xudp-trust")|.settings.id'\'' /etc/dual-trust-mieru/iran/xudp.json > /root/nm-live-xudp.uuid'
sudo scp -o StrictHostKeyChecking=ask /root/nm-live-xudp.uuid root@NEW_IP:/root/nm-live-xudp.uuid
```

On **NEW FOREIGN**, after DNS is correct:

```bash
git clone --depth 1 -b naive-mieru-live-safe-v1 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel-nm
cd /opt/frp-tunnel-nm/dual-trust-mieru
sudo bash install-foreign-lane3-naive.sh --public-ip NEW_IP --domain NEW_DOMAIN --email EMAIL --xudp-uuid-file /root/nm-live-xudp.uuid --non-interactive
sudo rm -f /root/nm-live-xudp.uuid
```

Foreign Caddy (v2.11.7-naive2) has `probe_resistance`, `hide_ip`, `hide_via`, TLS and a minimal legitimate HTTPS front page. Caddy forward proxy is authenticated. UDP/XUDP backend binds loopback only. NaiveProxy client (v154.0.8037.49-5) verifies release SHA-256, keeps certificate verification enabled, uses Chromium network stack and avoids unsafe extra concurrency.

## IRAN prepare (does not change any user routes)

```bash
sudo scp -o StrictHostKeyChecking=ask root@NEW_IP:/root/lane3-naive-client.json /root/lane3-naive-client.json
sudo chmod 0600 /root/lane3-naive-client.json
git clone --depth 1 -b naive-mieru-live-safe-v1 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel-nm
cd /opt/frp-tunnel-nm/dual-trust-mieru
sudo bash nm-iran.sh prepare /root/lane3-naive-client.json
```

This starts ONLY `nm-naive-candidate` on 17993 and `nm-xudp-candidate` on 17991. It validates forced-path HTTPS, Telegram HTTPS (synthetic only), and actual SOCKS UDP DNS over XUDP to the new Foreign. Mieru and all public users remain on existing paths.

## IRAN cutover (only failed Trust client replaced)

After `prepare` reports CANDIDATE PASS, run a 20-request full-path Telegram canary via the unchanged isolated candidate (plus direct Naive and Mieru comparisons):

```bash
cd /opt/frp-tunnel-nm/dual-trust-mieru
sudo bash nm-iran.sh soak
```

Any failed request blocks the migration; do not bypass the gate or remove its marker. With `SOAK PASS` recorded within 15 minutes, and provided neither candidate service has restarted, the cutover will also require strict 3/3 Telegram HTTPS and UDP readiness. Only then:

```bash
cd /opt/frp-tunnel-nm/dual-trust-mieru
sudo bash nm-iran.sh cutover
dual status
dual health --full all
```

This holds the existing autoheal lock, installs role-aware local-only autoheal, stops ONLY `dual-trust-client`, starts `nm-naive-client` on 7993, tests both 7993 and the live unchanged Xray 7991 path, checks Mieru paths 7994/7992, compares protected service PIDs, and disables only the old Trust client. It does NOT reload Mihomo/dispatcher or shared Xray bridge, and does NOT restart x-ui/Mieru. If the live path test fails, it attempts to restore the former Trust client and original autoheal.

**Do NOT run** `install-iran-lane3-helper.sh`, `lane3-manager.sh`, `lane3-pool.py enable`, `migrate-xui-split-to-unified.sh` or original `install-iran.sh`: they are for different workflows and may restart live services.

## Future 50/50 pool strategy — NOT while users are connected

```bash
dual balance-plan
sudo /usr/local/sbin/nm-pool-balance --apply
```

The `--apply` operation refuses all nonzero dispatcher connection counts. Only during a verified zero-connection maintenance window may it validate an updated YAML, save a root-only rollback copy, use authenticated localhost Mihomo `PUT /configs` without force, verify exact DUAL membership by GET, then atomically persist the new YAML. No systemd restart is requested. Round-robin means roughly equal *new connection count* over time, not equal traffic volume.

To roll back pool config (also requires zero dispatcher sessions):

```bash
sudo /usr/local/sbin/nm-pool-balance --rollback
```

Do not invoke this with active Mieru users. In production, the safest interim configuration is the existing sticky sessions with Naive underneath the legacy XUDP-TRUST alias.

## Retiring legacy local Trust

After several days of verified Naive+Mieru health and clean operator dashboard:

```bash
cd /opt/frp-tunnel-nm/dual-trust-mieru
sudo bash nm-retire-trust.sh
```

This backs up and removes only the old local Trust unit and client bundle/config, verifies both live legs first, and never touches the old Foreign VPS. The internal compatibility aliases in the running Xray bridge remain until a separately planned, controlled migration; removing/renaming them needs bridge reconfiguration and could disconnect active users.

Do not automatically delete the old Foreign VPS until the Naive path is stable and an operator explicitly authorizes retirement; old credentials should then be revoked on that former host. Replacing the physical VPS is a provider operation, not something this repo can do.
