# Maya4 Naive Lite

Dedicated single-carrier profile for a small Iran VPS (1 vCPU / 1 GiB RAM).

## Architecture

```
Maya4 users
  -> 3X-UI / Xray public inbound
  -> SOCKS 127.0.0.1:7996
       TCP -> Naive client 127.0.0.1:7995 -> Maya4 foreign :443
       UDP -> XUDP over the same Naive carrier -> foreign loopback :2443
```

There is intentionally no Mihomo, dispatcher, Trust, Mieru, or multi-carrier logic.

This profile uses a standard authenticated Naive HTTPS transport with normal TLS. It does not include specialized anti-detection, probing-resistance, traffic-shaping, or fingerprint-evasion tuning.

## Resource profile

Iran services:

- 3X-UI + its Xray core
- `maya4-naive-client.service`
- `maya4-xudp-router.service`

The Naive client and the dedicated XUDP router have systemd memory guardrails. The installer also creates a 1 GiB swapfile only when the host has less than 256 MiB of swap.

Maya4 is pinned to **3X-UI v2.9.4 exactly**. The Iran installer never installs "latest" and never upgrades or downgrades an existing panel implicitly. It verifies the installed panel binary reports version 2.9.4 before continuing.

## 1. Foreign server

Create a DNS-only A record for the Maya4 Naive hostname and point it at the new foreign IPv4.

Then run on the foreign VPS:

```bash
apt-get update && apt-get install -y git
rm -rf /opt/frp-tunnel
git clone --depth 1 --branch maya4-naive-lite --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel
cd /opt/frp-tunnel/maya4-naive-lite
bash install-foreign.sh
```

Inputs:

- foreign public IPv4
- Maya4 Naive domain
- Let's Encrypt email

Success creates the private client bundle:

```
/root/maya4-naive-client.json
```

Do not paste or commit that file.

## 2. Iran server

Run on the Maya4 Iran VPS:

```bash
apt-get update && apt-get install -y git
rm -rf /opt/frp-tunnel
git clone --depth 1 --branch maya4-naive-lite --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel
cd /opt/frp-tunnel/maya4-naive-lite
bash install-iran.sh
```

Enter the foreign IPv4. The installer connects over SSH and fetches the private bundle itself.

If 3X-UI is not present, the installer downloads the upstream installer from the **v2.9.4 tag** and invokes it explicitly for **v2.9.4**. If another 3X-UI version is already installed, Maya4 aborts without changing it.

## 3. Create the public inbound

For a fresh 3X-UI install, open the panel and create the public inbound you want to use. This branch does not auto-generate client credentials or public protocol settings.

The attach helper expects exactly one public inbound on TCP/443.

Use the 3X-UI management menu:

```bash
x-ui
```

## 4. Attach x-ui to Naive

After the public :443 inbound exists:

```bash
maya4 attach
```

The attach operation:

1. verifies the Naive full path is healthy;
2. backs up `/etc/x-ui/x-ui.db`;
3. stops x-ui once;
4. adds a local SOCKS outbound to `127.0.0.1:7996`;
5. routes the public :443 inbound to that outbound;
6. starts x-ui;
7. validates the generated runtime config;
8. rolls back the database automatically on failure.

## Health and operations

```bash
maya4 health
```

Expected:

```
OK maya4-naive-client
OK maya4-xudp-router
OK x-ui
OK Naive direct :7995
OK Naive full   :7996
OK Telegram :7996=3/3
OK UDP/XUDP :7996=2/2
```

The health output also shows current memory usage for the three Iran services.

Restart only the Maya4 tunnel components:

```bash
maya4 restart
```

This does not restart x-ui.

## Ports on Iran

- `7995/tcp`: Naive direct local SOCKS
- `7996/tcp+udp`: full TCP/XUDP local SOCKS
- public `443`: managed by 3X-UI

## Ports on foreign

- public `443/tcp`: Naive HTTPS endpoint
- `2443/tcp`: XUDP backend bound to loopback only


## One-input foreign replacement dashboard

For routine Maya4 foreign swaps, do **not** rerun `install-iran.sh` and do
**not** rerun `maya4 attach`.

The Iran-side dashboard keeps x-ui v2.9.4, its database, public :443 inbound,
and all client configurations untouched.

The replacement hostname is fixed:

```
naive4.biya2film.top
```

Before starting a swap, point the DNS-only A record for that hostname to the
new foreign IPv4. The current Maya4 Naive client keeps an explicit
host-resolver mapping to the old foreign IP, so changing public DNS does not
move the live Iran tunnel before cutover.

Install/update the dashboard on Maya4 Iran:

```bash
cd /root
rm -rf /opt/frp-tunnel
git clone --depth 1 --branch maya4-naive-lite --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel
cd /opt/frp-tunnel
sudo bash maya4-naive-lite/enable-replace-command.sh
```

Then run:

```bash
sudo maya4
```

Choose:

```
1) Replace foreign server (enter new IP only)
```

The helper asks only for the new IPv4. It then:

1. verifies `naive4.biya2film.top` resolves to that IPv4;
2. connects to the fresh foreign VPS over SSH;
3. clones the `maya4-naive-lite` branch there;
4. installs the Naive HTTPS endpoint and XUDP backend non-interactively;
5. fetches the private bundle without printing its secrets;
6. runs isolated candidate tests on localhost ports 17995/17996;
7. cuts over only if direct TCP, full TCP and UDP/XUDP all pass;
8. restarts only `maya4-naive-client` and `maya4-xudp-router`;
9. leaves x-ui untouched;
10. runs final Maya4 health and preserves the old foreign/config backup.

The old foreign VPS is never deleted automatically.

Direct CLI form is also available:

```bash
sudo maya4 replace NEW_FOREIGN_IP
```

Manual bundle replacement remains available for recovery:

```bash
sudo maya4 replace-bundle /root/new-maya4-naive-client.json
```

Current profile version: **1.1.0**.
