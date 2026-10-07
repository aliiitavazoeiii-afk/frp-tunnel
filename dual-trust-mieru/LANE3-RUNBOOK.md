# Maya3 Multi-Lane — Legacy + Lane 3 Naive

Branch: `maya3-multilane-naive`  
Lane 3 version: `1.0.0`

## Existing production remains intact

Legacy users continue to use the current public x-ui VLESS/REALITY inbound on TCP/443.

```
Maya3 :443
  -> x-ui
  -> dual-tunnel SOCKS 127.0.0.1:7990
  -> existing Trust + Mieru
```

Lane 3 is added in parallel:

```
Maya3 :443
  -> x-ui user routing
  -> lane3-naive SOCKS 127.0.0.1:7996
       TCP -> Naive SOCKS 127.0.0.1:7995 -> new foreign
       UDP -> XUDP over Naive -> new foreign
```

The user-facing protocol and port do not change: users still receive VLESS/REALITY on Maya3:443.

## Foreign install

Before installation, point a dedicated A record (for example a Lane 3-specific subdomain) to the new foreign VPS.

```bash
sudo apt-get update && sudo apt-get install -y git && \
sudo rm -rf /opt/frp-tunnel && \
sudo git clone --depth 1 --branch maya3-multilane-naive --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel && \
cd /opt/frp-tunnel/dual-trust-mieru && \
sudo bash install-foreign-lane3-naive.sh
```

Inputs:
- public IPv4
- dedicated Naive domain
- Let's Encrypt email

Successful output includes:
`Client bundle: /root/lane3-naive-client.json`

Never paste or commit that bundle.

## Install the helper on Maya3

```bash
cd /root && \
sudo rm -rf /opt/frp-tunnel && \
sudo git clone --depth 1 --branch maya3-multilane-naive --single-branch \
  https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel && \
cd /opt/frp-tunnel/dual-trust-mieru && \
echo "LANE3_VERSION=$(cat LANE3_VERSION)" && \
sudo bash install-iran-lane3-helper.sh
```

This helper installation does not modify x-ui routing and does not restart legacy tunnel services.

Open the panel:

```bash
lane3
```

## First foreign import

Use panel option:

`1) Import first Lane 3 foreign server`

Enter the new foreign IPv4. The helper downloads the private bundle over SSH, installs Naive locally on 7995, installs the split TCP/XUDP router on 7996, and runs health checks.

No users are moved by the import.

## Routing modes

### Split mode

Use:

`3) SPLIT mode`

Effective rules:
- email beginning with `L3-` -> Lane 3
- explicitly assigned email -> Lane 3
- every other user -> Legacy Trust/Mieru

### All users to Lane 3

Use:

`6) Route ALL users -> Lane 3`

### All users to Legacy

Use:

`7) Route ALL users -> Legacy`

This is also the emergency rollback route.

## New user workflow

Create the client in the same existing x-ui inbound used by current users:
- protocol: VLESS
- security: REALITY
- public port: 443
- server/address: same Maya3 address used today
- email/name: start with `L3-`, for example `L3-shop-001`

Do not create a second public inbound.

When routing mode is `split`, the new user's server-side email automatically sends that user's traffic to Lane 3. The client UUID/config is otherwise normal and uses the same Maya3:443 entry point.

## Move an existing user without changing the client config

Use option:

`4) Assign existing user -> Lane 3`

Enter the exact x-ui client email. The helper adds the email to its routing assignment list. It does not change the UUID or subscription.

To return the user:

`5) Return assigned user -> Legacy`

## Replace Lane 3 foreign

After the first import, panel option 1 automatically becomes:

`Replace Lane 3 foreign server`

Point the existing Lane 3 domain A record to the new foreign IP first. The helper:
1. connects to the new foreign;
2. preserves the existing Lane 3 XUDP UUID;
3. installs the new foreign from this branch;
4. downloads the new credentials;
5. restarts only the local Lane 3 Naive carrier;
6. runs full Lane 3 health;
7. rolls back to the previous foreign on failure.

The old foreign is not deleted automatically.

## Ports

- 7990 existing Dual entry (unchanged)
- 7991 existing Trust path (unchanged)
- 7992 existing Mieru path (unchanged)
- 7993 existing Trust direct (unchanged)
- 7994 existing Mieru direct (unchanged)
- 7995 Lane 3 Naive direct
- 7996 Lane 3 full TCP/XUDP entry

## Safety

- Legacy carrier services are not restarted by Lane 3 install/replace.
- x-ui is restarted only when a routing mode/user assignment is applied.
- x-ui DB is backed up before each routing change and automatically restored if validation fails.
- Lane 3 replacement preserves its XUDP UUID and keeps the old foreign available for rollback.
