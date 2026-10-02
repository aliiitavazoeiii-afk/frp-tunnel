# Naive/Mieru Dual Migration

Branch: `naive-mieru-dual`  
Version: `2.0.0-rc1`

## Goal

Replace the role-A TrustTunnel carrier with NaiveProxy while preserving:

- public x-ui inbound
- SOCKS dispatcher `127.0.0.1:7990`
- forced role-A path `7991`
- forced Mieru path `7992`
- role-A direct carrier `7993`
- Mieru direct carrier `7994`
- existing Xray bridge tags (`xudp-trust` / `carrier-trust`) as legacy internal compatibility names
- Mieru MULTIPLEXING_OFF
- dispatcher sticky-sessions

The migration does not restart Mieru, the shared Xray bridge, dispatcher, or x-ui.

## 1. Install a new Naive foreign

Point a dedicated A record at the new VPS first.

```bash
sudo apt-get update && sudo apt-get install -y git && sudo rm -rf /opt/frp-tunnel && sudo git clone --depth 1 --branch naive-mieru-dual --single-branch   https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel && cd /opt/frp-tunnel/dual-trust-mieru && sudo bash install-foreign-naive.sh
```

Inputs:

- public IPv4
- Naive domain
- Let's Encrypt email

Output bundle:

`/root/dual-naive-client.json`

Do not paste the bundle into chat or commit it.

## 2. Upgrade the Iran/Maya manager in place

This does not migrate automatically.

```bash
cd /root && sudo rm -rf /opt/frp-tunnel && sudo git clone --depth 1 --branch naive-mieru-dual --single-branch   https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel && cd /opt/frp-tunnel/dual-trust-mieru && echo "VERSION=$(cat VERSION)" && sudo bash dual-install-iran.sh
```

Expected version: `2.0.0-rc1`.

## 3. Migrate from the panel

Run:

```bash
dual status
```

Before migration option 3 is:

`Migrate Trust -> Naive foreign server`

After migration it becomes:

`Replace Naive foreign server`

The helper:

1. connects to the new Naive VPS using one reusable SSH session;
2. preserves the live Maya XUDP UUID without printing it;
3. preflights Naive on temporary SOCKS/17993;
4. pauses autoheal;
5. switches only role-A SOCKS/7993;
6. validates direct HTTP, forced TCP/7991, Telegram, and UDP/XUDP;
7. updates the bridge boot dependency from legacy Trust client to Naive client without restarting the bridge;
8. disables the legacy Trust client only after all gates pass.

On failure it restores the previous role-A carrier.

The old Trust foreign VPS is deliberately not deleted automatically.

## Foreign uninstall

```bash
cd /opt/frp-tunnel/dual-trust-mieru
sudo bash uninstall-foreign-naive.sh
```

## Health

```bash
dual health --full all
```

After migration the health screen should show `Naive foreign` and `dual-naive-client`.

## Safety invariants

- never restart x-ui during migration
- never restart Mieru during Naive migration
- never restart the shared Xray bridge for the carrier swap
- preserve the live XUDP UUID
- keep Mieru multiplexing OFF
- keep dispatcher strategy sticky-sessions
- do not delete the old Trust VPS until Naive has been stable in production
