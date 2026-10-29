# Dual TCP/TLS HA — Ubuntu 24.04

This is a **staging implementation**, not a verified DPI-resistant system. It uses two independent stunnel TLS connections carrying SOCKS5 over TCP, with HAProxy connection-level load balancing and failover. Both remote nodes use the same mature transport technology, so protocol diversity is **not** achieved. No guarantee of evading DPI or preserving established connections during failover.

Topology:
- Iran: HAProxy 127.0.0.1:1080 -> stunnel clients 127.0.0.1:21001,21002
- Foreign 1/2: stunnel :443 -> Dante SOCKS5 127.0.0.1:11080
- Each foreign endpoint has a separate certificate, systemd service, and VPS.

## Foreign servers (run on EACH, independently)
```bash
sudo bash foreign.sh
```
Then retrieve `/etc/dual-tcp-ha/server.crt` securely from each host to Iran as `/etc/dual-tcp-ha/foreign1.crt` and `foreign2.crt`. Verify each certificate fingerprint out-of-band before installing.

## Iran server
```bash
sudo bash iran.sh <FOREIGN1_IP> <FOREIGN2_IP>
```
Before running, place the two foreign certificates as described above.

## Check
```bash
systemctl status dual-stunnel-client haproxy --no-pager
curl -v --socks5-hostname 127.0.0.1:1080 https://example.com/
```

### Operational caveats
- HAProxy TCP checks on localhost only detect local stunnel listeners, **not remote egress health**. This is not production-grade automatic failover; do not deploy to paying users until an end-to-end health checker is added.
- SOCKS5 TCP CONNECT only. UDP ASSOCIATE is not supported in this setup.
- Load balancing is per TCP connection, not per HTTP request.
- TCP-over-TCP can degrade performance on lossy links.
- Neither stunnel nor TLS automatically looks like ordinary browser HTTP traffic; DPI may recognize it.
- Do not expose port 1080 on Iran or port 11080 on foreign hosts.
- Ensure firewall allows inbound TCP 443 to foreign nodes, and outbound 443 from Iran.
- Existing x-ui configuration must explicitly use SOCKS5 127.0.0.1:1080.
- Test each node separately and soak-test 72 hours before production.
