# DUAL MIERU TRUST TUNNEL v1.1.0 — Simple workflow

The operator-facing workflow is intentionally reduced to two scripts:

- Foreign VPS: `dual-install-foreign.sh`
- Iran VPS: `dual-install-iran.sh`

After Iran installation or upgrade, day-to-day operations use:

```bash
dual status
```

## 1. Foreign VPS

Run this on each clean foreign VPS. Run it once for the Trust role and once on the separate Mieru VPS.

```bash
apt-get update && apt-get install -y git
rm -rf /opt/frp-tunnel
git clone --depth 1 --branch trust-mieru-dual --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel
cd /opt/frp-tunnel/dual-trust-mieru
sudo bash dual-install-foreign.sh
```

The script asks which role to install.

Trust asks for:
- public IPv4
- Trust domain
- Let's Encrypt email

Before installing Trust, the domain A record must already resolve to that VPS IPv4.

Mieru asks for:
- public IPv4
- port range (default `20000-20020`)

The installer generates credentials itself and writes a root-only client bundle. It also runs a local end-to-end preflight from the carrier back into the role XUDP loopback backend before declaring success.

## 2. Iran VPS

```bash
apt-get update && apt-get install -y git
rm -rf /opt/frp-tunnel
git clone --depth 1 --branch trust-mieru-dual --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel
cd /opt/frp-tunnel/dual-trust-mieru
sudo bash dual-install-iran.sh
```

Fresh install asks for the Trust foreign IPv4 and Mieru foreign IPv4, retrieves both bundles over SCP, installs the stable split architecture, attaches x-ui when present, installs low-noise health/autoheal, and runs a full health check.

If an existing `/etc/dual-trust-mieru/iran/xudp.json` is detected, the same script performs an in-place v1.1 management/health upgrade instead of rebuilding the live carriers or x-ui.

The production traffic invariant remains:

- Trust TCP -> Trust carrier
- Trust UDP -> Trust XUDP
- Mieru TCP -> Mieru carrier
- Mieru UDP -> Mieru XUDP
- Mieru `MULTIPLEXING_OFF`
- Mieru `HANDSHAKE_STANDARD`

## 3. Management

```bash
dual status
```

The menu provides:
- quick health
- full TCP + Telegram + UDP/XUDP health
- replace Trust foreign
- replace Mieru foreign
- selective Trust restart
- selective Mieru restart
- recent warnings/errors
- re-apply the low-noise health profile

A carrier replacement preserves the live Iran XUDP UUID, bootstraps and validates the new foreign role first, changes only the selected Iran carrier, validates TCP + Telegram + UDP/XUDP, and leaves the other carrier, x-ui, and shared bridge untouched during the carrier cutover. On failure, the selected carrier configuration is rolled back.

For Trust replacement, change the existing Trust domain A record to the new Trust IPv4 first. The menu checks DNS and refuses to start the Trust migration until it resolves correctly.

After a successful replacement the manager triggers a dispatcher health refresh, so new connections can use the recovered role again. Existing established connections are not forcibly moved between carriers.

The manager attempts to stop/remove the old role configuration from the previous VPS when it remains reachable with non-interactive SSH. Deleting the actual VPS resource from a cloud provider is outside the server script and requires that provider's API/control panel.

## Low-noise health policy

The v1.1 profile changes dispatcher health checks from the old aggressive profile to:

```text
interval: 120
lazy: true
```

Autoheal runs every 5 minutes with up to 90 seconds of randomized delay. Direct carrier failure can restart only that carrier. A one-role UDP/XUDP failure is reported but does not bounce the shared bridge; the bridge is eligible for restart only after both role UDP/XUDP paths repeatedly fail.
