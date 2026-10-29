# Dual Backhaul V2 + Mieru TCP — isolated integration (STAGING)

## Safety gate

**NOT production ready.** This repository contains an isolated HAProxy SOCKS5 traffic switch and a genuine egress probe controller. It does NOT install Custom Backhaul V2 or Mieru, does NOT change x-ui/Xray, and does NOT touch :443. Do not send customers to this until both upstream paths have been separately provisioned and soak-tested.

### Intended topology

Existing client -> Iran Xray REALITY :443 (unchanged) -> Xray SOCKS outbound 127.0.0.1:18080 -> HAProxy TCP (connection-level LB) ->

- BACKHAUL SOCKS endpoint 127.0.0.1:21001 -> Custom Backhaul V2 transport -> Foreign 1 SOCKS egress
- MIERU SOCKS endpoint 127.0.0.1:21002 -> Mieru TCP -> Foreign 2 SOCKS egress

Both endpoint sockets MUST speak SOCKS5 and complete a CONNECT; a raw Backhaul forwarded Xray inbound is **not** a SOCKS5 server. An adapter or foreign SOCKS server with a reverse port mapping is required. Mieru must be explicitly configured with TCP port bindings only. Custom Backhaul v2 currently installs its own HAProxy and SNI router on Iran :443; it MUST be refactored for dedicated ports and coexistence with the existing Xray before use.

### Installation of ISOLATED HA layer only

On a fresh staging Iran VM, after arranging two working SOCKS5 endpoints:

```bash
sudo bash dual-backhaul-mieru-ha/install-gateway.sh
sudo systemctl status dual-ha-haproxy dual-ha-health --no-pager
curl --socks5-hostname 127.0.0.1:18080 -I --max-time 12 https://www.cloudflare.com/
```

This creates separate services and files under /etc/dual-ha, no modifications to /etc/haproxy/haproxy.cfg or x-ui.

### Checks

```bash
sudo journalctl -u dual-ha-health -n 80 --no-pager
sudo bash dual-backhaul-mieru-ha/preflight.sh
```

Probe uses HTTP GET via SOCKS5 (not TCP port check) to verify external HTTPS through each path; this verifies the proxy and a sample internet destination, not all websites. The probe does not prove that a path is unfiltered for every client or target.

### Failover semantics

- Each new TCP connection is assigned to one healthy path using leastconn.
- Health controller requires 3 consecutive failures to disable and 5 consecutive successes to re-enable, sampled every 8 seconds.
- Existing TCP sessions cannot migrate across foreign servers; they must reconnect. Video may freeze if its active connection dies.
- Distinct foreign IPs, services, secrets, and independent transport processes.
- Never schedule periodic restarts of healthy transports.
- No UDP between Iran and foreign on either path (must verify in actual transport configuration).
- Test 72 hours under realistic concurrent load and forced outage before production.

### Blocking work

1. Refactor and integrate Custom Backhaul V2 to a dedicated ingress port without modifying :443 or the existing HAProxy.
2. Create and validate foreign SOCKS5 service and reverse mapping for Backhaul.
3. Pin and install audited Mieru/mita versions and config on independent foreign server.
4. Integrate Xray SOCKS outbound through a reversible, backed-up configuration update (without touching inbound).
5. Run real two-VPS network tests, packet capture for TCP-only, and 72h soak tests.

**No promise of DPI invisibility or zero playback interruption is made.**
