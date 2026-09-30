# New Chat Prompt — Trust + Mieru Dual Tunnel

Copy/paste the prompt below into a new ChatGPT chat.

---

I want to continue my production **TrustTunnel + Mieru dual tunnel** project from its exact current state.

Repository:

```text
aliiitavazoeiii-afk/frp-tunnel
```

Branch to use:

```text
trust-mieru-dual
```

**Before giving me any commands or making any change, inspect this branch and fully read:**

```text
dual-trust-mieru/TRUST-MIERU-DUAL-PROJECT-CONTEXT.md
```

Also inspect the actual scripts on this branch, especially:

```text
dual-trust-mieru/replace-carrier-only-final.sh
dual-trust-mieru/dual-autoheal.sh
dual-trust-mieru/dual-probe-final.sh
dual-trust-mieru/install-foreign-trust.sh
dual-trust-mieru/install-foreign-mieru-final.sh
dual-trust-mieru/install-iran-final.sh
```

Treat the **real current VPS/runtime output** that I send you as more authoritative than old documentation.

Important production constraints:

- x-ui public VLESS/REALITY is live with users.
- Never broad-kill Xray and never use `pkill xray`.
- Do not restart x-ui as part of a Trust/Mieru carrier replacement.
- Keep Trust and Mieru as two independent paths.
- Do not permanently switch to only one carrier.
- Do not change both carriers simultaneously.
- During a carrier migration, preserve the currently live role XUDP UUID.
- `replace-carrier-only-final.sh` is the preferred carrier-only cutover helper.
- Stop autoheal during manual cutover and re-enable it afterward.
- Do not restart the shared `dual-xudp-bridge` unless direct carriers are confirmed healthy and the fault is proven to be bridge/path-only.
- Keep old foreign VPSes for rollback until the new path passes full validation.
- Never print/paste bundle credentials, UUID values, REALITY keys or other secrets. Compare UUIDs using MATCH/DIFFERENT only.
- Label command blocks clearly as IRAN, FOREIGN TRUST, or FOREIGN MIERU.
- Prefer short copy-paste command blocks because large terminal pastes can get mangled.

Current Iran node in the latest work is referred to as Maya3:

```text
Iran: 5.10.249.206
```

Latest selected foreign endpoints at handoff:

```text
Trust:  193.57.9.218
Mieru:  193.57.9.156
```

But do **not** assume those are fully validated just because they are listed. Read the project-context file: Trust had previous XUDP/internal-host issues on replacement servers, and the final Mieru migration to `193.57.9.156` had not yet been confirmed with a pasted full probe at the time of handoff.

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

Mieru final carrier settings:

```text
MULTIPLEXING_OFF
HANDSHAKE_STANDARD
```

When diagnosing, separate:

1. direct carrier health (`7993` Trust / `7994` Mieru)
2. forced split-path health (`7991` / `7992`)
3. dispatcher (`7990`)
4. role XUDP/UDP health
5. foreign endpoint health

Do not infer an IP is filtered solely from one HTTP=000/reset/timeout. First isolate the failing layer.

If Trust direct HTTP works but Trust UDP/XUDP fails, specifically inspect `xudp-trust.internal:2443` reachability through Trust SOCKS and read the incident notes in the context file before touching the Iran shared bridge.

If Mieru direct is itself intermittently failing, investigate Mieru server/path quality before blaming XUDP or the shared bridge.

At the start of this new chat, first tell me in a short summary:

- that you read the branch/context,
- what you believe the current architecture/state is,
- what is confirmed versus still needs runtime verification,
- and then continue from the exact server output I give you.

Do not redesign the system from scratch and do not ask me to repeat information already documented in the branch unless runtime verification is actually necessary.
