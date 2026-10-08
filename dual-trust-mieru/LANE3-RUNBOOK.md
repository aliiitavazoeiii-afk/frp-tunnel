# Unified Triple Carrier — Trust + Mieru + Naive

Branch: `triple-carrier-naive`  
Triple extension version: `1.1.0`  
Production base: Trust/Mieru `v1.1.7`

## Architecture

The existing public x-ui inbound stays unchanged:

```
Users
  -> Maya3 / x-ui / VLESS REALITY :443
  -> SOCKS dispatcher 127.0.0.1:7990
       -> Trust full path :7991
       -> Mieru full path :7992
       -> Naive full path :7996
```

Direct carrier ports:

- Trust direct: `7993`
- Mieru direct: `7994`
- Naive direct: `7995`

Naive full path `7996` uses TCP directly through Naive and UDP through its own XUDP router.

The dispatcher remains:

```yaml
strategy: sticky-sessions
interval: 120
lazy: true
max-failed-times: 2
```

All three carriers are members of the same health-aware load-balance group. If one becomes unhealthy, new/reconnected flows are selected from the remaining healthy members. Existing TCP sessions cannot migrate between carriers mid-connection.

## Safety properties

- x-ui database and routing are not modified by Triple installation.
- Trust, Mieru and the shared Trust/Mieru XUDP bridge are not restarted when Naive is imported.
- Joining/leaving Naive changes only the dispatcher config and restarts only `dual-dispatcher.service`.
- Dispatcher changes are backed up, validated with Mihomo, and rolled back if the post-check fails.
- Naive has its own carrier and XUDP router services.
- Naive auto-heal never restarts the shared Trust/Mieru bridge.
- Foreign replacement preserves the Naive XUDP UUID.
- Old foreign VPS instances are not deleted automatically.

## Foreign Naive installation

Create a dedicated DNS-only A record pointing to the third foreign VPS.

Then:

```bash
apt-get update && apt-get install -y git ca-certificates
rm -rf /opt/frp-tunnel
git clone --depth 1 --branch triple-carrier-naive --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel
cd /opt/frp-tunnel/dual-trust-mieru
bash install-foreign-lane3-naive.sh
```

Inputs:

- foreign public IPv4
- dedicated Naive domain
- Let's Encrypt email

Success creates:

```
/root/lane3-naive-client.json
```

Do not paste or commit that bundle.

## Maya3 helper installation

On the existing Iran/Maya3 production server:

```bash
rm -rf /opt/frp-tunnel
git clone --depth 1 --branch triple-carrier-naive --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel
cd /opt/frp-tunnel/dual-trust-mieru
bash install-iran-lane3-helper.sh
```

The helper runs the source audit before installation and updates the unified health/manager/autoheal tools without changing x-ui routing.

Open the main manager:

```bash
dual status
```

Naive management is available from option 10, or directly:

```bash
lane3
```

Choose option 1 to import the first Naive foreign. The manager:

1. fetches the private bundle over SSH;
2. installs the Naive client on `7995`;
3. installs the Naive TCP/XUDP full path on `7996`;
4. runs full Naive health;
5. only after health passes, adds `XUDP-NAIVE` to the existing `:7990` dispatcher pool.

## Unified health

```bash
dual health --full all
```

Expected sections include:

```
Trust foreign : ...
Mieru foreign : ...
Naive foreign : ...

Trust direct :7993
Trust path   :7991

Mieru direct :7994
Mieru path   :7992

Naive direct :7995
Naive path   :7996

Unified entry :7990
```

Role-specific Naive health:

```bash
dual health --full naive
```

## Emergency removal of Naive from user traffic

This does not stop Trust or Mieru:

```bash
lane3
```

Choose:

```
4) Disable Naive from unified :7990 pool
```

The dispatcher is backed up and validated before restart. All new/reconnected traffic then uses Trust and Mieru only.

To return Naive:

```
3) Enable Naive in unified :7990 pool
```

Enable is refused unless Naive quick health passes.

## Failover behavior

With all three healthy:

```
:7990 -> Trust / Mieru / Naive
```

If Trust fails:

```
:7990 -> Mieru / Naive
```

If Mieru fails:

```
:7990 -> Trust / Naive
```

If Naive fails:

```
:7990 -> Trust / Mieru
```

When the failed carrier becomes healthy again, new flows become eligible for it again. Sticky sessions are retained to reduce related application sessions exiting through different IPs.
