# AnyTLS Tunnel v1.1.0

GitHub-first deployment. No file transfer between Iran and foreign servers is required.

## Roles

- `foreign-a`: AnyTLS + ShadowTLS v3 on TCP/443
- `foreign-b`: AnyTLS + ResTLS on TCP/443
- `iran`: local Mihomo load-balancer with health-check and sticky sessions

## Install on every VPS

```bash
sudo rm -rf /opt/anytls-tunnel
sudo git clone --depth 1 --branch anytls-v1.1.0 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/anytls-tunnel
cd /opt/anytls-tunnel
sudo bash setup.sh
```

Install in this order: Foreign A, Foreign B, then Iran.

On each foreign server, pressing Enter at the password prompts generates strong local secrets. Save the values printed at the end. When installing the Iran role, paste the four secrets and the two foreign IPs/cover hostnames. No env file or secret file needs to move between machines.

Secrets are stored locally under `/root/anytls-*.env` with mode `0600` and copied into `/etc/anytls-tunnel/deploy.env`. They are not stored in GitHub.

## Verify on Iran

```bash
sudo anytls-tunnel-status
sudo anytls-tunnel-health
sudo anytls-tunnel-probe-test
```

The Iran mixed proxy is bound to `127.0.0.1:7890` by default and should not be exposed publicly.

## Rollback

```bash
sudo anytls-tunnel-rollback
```

The core is pinned to Mihomo v1.19.30 and the installer verifies the expected release SHA-256 before activation. Candidate configs are checked with `mihomo -t` before restart.
