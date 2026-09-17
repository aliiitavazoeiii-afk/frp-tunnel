# Bucket5 transport-aware failover — canary phase

This branch is intentionally separated from `bucket5-v2` production code.
It starts with a retired-F4 canary and does **not** modify x-ui, public UUIDs,
user→bucket mapping, production bucket selectors, or the current Bucket5 scheduler.

## Goal

Prove whether a logical Foreign node can stay useful on the same public IP when
one outer carrier is degraded by switching among independent carriers:

1. AnyTLS + ResTLS
2. AnyTLS + ShadowTLS v3
3. VLESS + REALITY

The existing inner XUDP endpoint remains `127.0.0.1:2443` on the Foreign node.

## Canary ports

- ResTLS: TCP/443 (existing retired F4 service)
- ShadowTLS v3: TCP/8443
- VLESS + REALITY: TCP/8444

The exact public IP is supplied at install time and is never committed.
All credentials are generated/read locally and remain in root-only files.

## Safety

`setup-bucket5-transport-canary-foreign.sh` refuses to run without the explicit
`--retired-canary` acknowledgement. It validates the candidate Mihomo config,
backs up the old config, performs one controlled restart, verifies all listeners,
and writes a root-only rollback helper.

On Maya, `install-bucket5-transport-canary-iran.sh` only installs isolated probe
helpers and a root-only client bundle. It does not restart Mihomo, XUDP, x-ui, or
the Bucket5 scheduler.

## A/B workflow

Run isolated single probes first, then repeated measurements. Each probe tests:

1. raw TCP to that carrier port,
2. direct carrier HTTP without XUDP,
3. isolated XUDP startup,
4. gstatic / YouTube / ytimg / Instagram,
5. sustained 1 MB transfer,
6. UDP DNS over XUDP.

`bucket5-transport-ab.py` stores timestamp, carrier, result, elapsed time, and
failure stage without recording credentials.

## Interpretation

- ResTLS failing while ShadowTLS/REALITY succeed on the same IP and time window
  supports transport-specific classification/interference and justifies
  transport-aware failover.
- Similar failure rates across all carriers on the same IP shifts suspicion
  toward IP/path/provider-level interference.
- These observations still do not identify which administrative network is
  responsible for a drop.

## Production phase after proof

The next stage will make each logical node (`F1..F5`) a stable selector whose
members are transport carriers. Bucket selectors will continue to target logical
`F#` names. Scheduler order will be:

1. current carrier quick health fails,
2. isolated-probe backup carrier,
3. if backup passes, switch only logical-node carrier and drain that node's
   current connections,
4. keep logical node healthy and keep all bucket mappings unchanged,
5. only if every carrier fails, invoke existing Bucket5 node failover.

Night rotation will be staggered and pre-probed rather than a blind simultaneous
switch. Existing Bucket5 node failover remains the final safety net.

FRP is deliberately not one of the first three selector members. FRP is a raw
forwarding/tunneling system rather than a drop-in Mihomo forward-proxy carrier;
it can be evaluated later through STCP/XTCP or another local forwarding adapter,
but that requires a different integration path under XUDP.
