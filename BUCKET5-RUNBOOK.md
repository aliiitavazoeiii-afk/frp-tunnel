# Bucket5 v2.0.0

This branch replaces connection-level load balancing with stable per-user buckets across five Foreign nodes.

## Topology

Each Iran gateway keeps 10 stable user buckets. Users are assigned once by Xray client email; the mapping persists. Bucket targets can move without changing user UUIDs.

- F1: AnyTLS + ShadowTLS v3
- F2: AnyTLS + ResTLS
- F3: AnyTLS + ShadowTLS v3
- F4: AnyTLS + ResTLS
- F5: AnyTLS + ShadowTLS v3

With about 150 users on maya1 and 150 on maya3, each Iran node contributes about 30 users to each Foreign in the healthy state, giving about 60 users per Foreign globally.

## Safety rules

- Installer audits active x-ui clients before any change. Every active client must have a unique non-empty email because Xray `routing.rules.user` matches client email.
- All five Foreign nodes must pass the isolated full probe before activation: TCP/443, AnyTLS wrapper, XUDP, gstatic, YouTube, ytimg, Instagram, sustained transfer, UDP DNS over XUDP.
- Mihomo candidate config and XUDP candidate config are validated before activation.
- Existing x-ui UUIDs and public inbound are preserved.
- First installation requires one controlled XUDP bridge restart and one controlled x-ui restart.
- Later bucket moves use the Mihomo controller API and close only connections belonging to the moved bucket.
- A node is marked unhealthy after two consecutive quick health failures. Its buckets are immediately moved to healthy nodes.
- A recovered node requires quick recovery passes plus a full isolated probe before it can receive traffic again.
- With all five nodes healthy, each Iran gateway targets exactly two buckets per Foreign. Load balancing uses bucket swaps so the user quota stays balanced.
- If a Foreign is down, keeping every remaining Foreign at <=60 users is mathematically impossible with 300 active users; emergency failover prioritizes availability until all five are healthy again.

## Foreign preparation

Install/reinstall healthy Foreign nodes with the existing final installer. F1/F3/F5 use `foreign-a`; F2/F4 use `foreign-b`.

```bash
sudo rm -rf /opt/anytls-tunnel
sudo git clone -b bucket5-v2 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/anytls-tunnel
cd /opt/anytls-tunnel
```

F1, F3, F5:

```bash
sudo bash setup-final.sh foreign-a
sudo anytls-final-health
```

F2, F4:

```bash
sudo bash setup-final.sh foreign-b
sudo anytls-final-health
```

All five Foreign XUDP endpoints must use the same existing XUDP UUID/port expected by the Iran gateways. The standard project defaults already do this unless they were manually overridden.

## Iran migration

Do maya1 first, validate it, then maya3.

```bash
cd /opt/anytls-tunnel
sudo git fetch origin
sudo git checkout bucket5-v2
sudo git pull --ff-only origin bucket5-v2
cat VERSION
```

Expected:

```text
2.0.0
```

maya1:

```bash
sudo bash install-bucket5.sh maya1
```

The installer reuses maya1's current F1/F2 credentials and existing F5 shared credentials when present, then securely asks for missing F3/F4 credentials.

maya3:

```bash
sudo bash install-bucket5.sh maya3
```

The installer reuses maya3's current F3/F4 credentials and existing F5 shared credentials when present, then securely asks for missing F1/F2 credentials.

## Operations

Status:

```bash
sudo anytls-bucket5-status
```

Manual isolated node probe:

```bash
sudo anytls-bucket5-probe F1
sudo anytls-bucket5-probe F2
sudo anytls-bucket5-probe F3
sudo anytls-bucket5-probe F4
sudo anytls-bucket5-probe F5
```

Scheduler logs:

```bash
journalctl -u anytls-bucket5-scheduler.service -n 100 --no-pager
```

After adding/removing x-ui users, reconcile the stable user->bucket mapping:

```bash
sudo anytls-bucket5-reconcile
```

Reconcile performs one controlled x-ui restart. Existing mapped users remain in their current buckets; new users are assigned to the least-populated bucket.

## Ports on Iran

All are loopback only:

- 7890: legacy Mihomo listener for newly-added users not yet reconciled
- 7891: legacy XUDP SOCKS fallback
- 7901-7910: Mihomo bucket carrier listeners
- 8101-8110: XUDP SOCKS bucket listeners used by x-ui per-user routes
- 9090 (or configured controller port): Mihomo local controller

The public x-ui VLESS/REALITY inbound remains on TCP/443.
