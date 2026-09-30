# New Chat Prompt — Trust + Mieru Dual Tunnel

Copy/paste the prompt below into a new ChatGPT chat.

---

I want to continue my production **TrustTunnel + Mieru dual tunnel** project from its exact current state.

Repository:

```text
aliiitavazoeiii-afk/frp-tunnel
```

Branch:

```text
trust-mieru-dual
```

Before giving commands or changing anything, inspect the current branch HEAD and fully read these files in this order:

```text
dual-trust-mieru/V1.1.0-RELEASE-CONTEXT.md
dual-trust-mieru/SIMPLE-INSTALL.md
dual-trust-mieru/TRUST-MIERU-DUAL-PROJECT-CONTEXT.md
```

`V1.1.0-RELEASE-CONTEXT.md` supersedes conflicting operational details in the older project context. The older file is still important for incident history.

Also inspect the actual current scripts, especially:

```text
dual-trust-mieru/dual-install-foreign.sh
dual-trust-mieru/dual-install-iran.sh
dual-trust-mieru/dual-manager.sh
dual-trust-mieru/dual-health.sh
dual-trust-mieru/replace-carrier-only-final.sh
dual-trust-mieru/dual-autoheal.sh
dual-trust-mieru/install-autoheal.sh
dual-trust-mieru/dual-probe-final.sh
```

Treat real current VPS/runtime output that I send as more authoritative than documentation.

Current normal operator interface is:

```text
dual-install-foreign.sh   # foreign Trust or Mieru installation
dual-install-iran.sh      # Iran fresh install or in-place v1.1 upgrade
dual status               # interactive management menu
dual health --full        # full non-interactive health
```

Important production constraints:

- x-ui public VLESS/REALITY is live with users.
- Never broad-kill Xray and never use `pkill xray`.
- Do not restart x-ui as part of a Trust/Mieru carrier replacement.
- Keep Trust and Mieru as two independent paths.
- Do not permanently switch to only one carrier.
- Do not change both carriers simultaneously.
- Preserve the currently live role XUDP UUID during a carrier migration.
- Do not restart the shared `dual-xudp-bridge` for a one-role problem.
- Never print/paste bundle credentials, UUID values, REALITY keys, TLS private keys or other secrets.
- Prefer short copy-paste command blocks.

Architecture/ports to preserve:

```text
7990 = dual dispatcher entry
7991 = forced Trust path
7992 = forced Mieru path
7993 = Trust direct carrier SOCKS
7994 = Mieru direct carrier SOCKS
19090 = dispatcher controller
```

Desired split behavior:

```text
trust-in TCP  -> carrier-trust
trust-in UDP  -> xudp-trust
mieru-in TCP  -> carrier-mieru
mieru-in UDP  -> xudp-mieru
```

Mieru production settings must remain unless deliberately benchmarked:

```text
MULTIPLEXING_OFF
HANDSHAKE_STANDARD
```

Do not casually turn Mieru multiplexing back on: the operator reports the current combination no longer has the earlier video-freeze problem.

v1.1 deliberately retired the old aggressive health cadence. The normal profile is now dispatcher health `interval: 120`, `lazy: true`, plus autoheal every 5 minutes with randomized delay. Autoheal must use actual UDP/XUDP probes for XUDP diagnosis; TCP HTTP through 7991/7992 is not XUDP proof.

When diagnosing, separate:

1. direct carrier health (`7993` Trust / `7994` Mieru)
2. forced TCP path (`7991` / `7992`)
3. role Telegram behavior
4. real role UDP/XUDP health
5. dispatcher (`7990`)
6. foreign endpoint/backend health

For ordinary foreign replacement, prefer the `dual status` menu. It is designed to replace one role without restarting the other carrier, x-ui or the shared bridge, and to require TCP + Telegram + UDP/XUDP validation before declaring the cutover successful.

For Trust replacement, the Trust domain A record must first resolve to the new Trust VPS. The manager checks this before installation/cutover.

Do not assume endpoint IPs from old handoff files are still current. Read the current bundles/runtime instead.

At the start of the new chat, briefly state:

- current branch HEAD/version,
- that you read the v1.1 release context and historical context,
- what architecture/invariants you will preserve,
- and what runtime facts still need verification.

Do not redesign from scratch and do not make me repeat documented information unless runtime verification is genuinely necessary.
