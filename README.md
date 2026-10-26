# FRP Tunnel

Repository migrated from `backhaul-ha-installer` FRP tunnel work.

## Start here

For the consolidated history of the production tunnel evolution from Trust/Mieru dual-carrier through Triple Trust+Mieru+Naive and the current Maya4 Naive Lite workflow, read:

- [`TUNNEL-PROJECT-HISTORY.md`](./TUNNEL-PROJECT-HISTORY.md)
- [`NEW-CHAT-PROMPT-TUNNEL.md`](./NEW-CHAT-PROMPT-TUNNEL.md)

These are cross-branch handoff documents. For production changes, current branch code and live runtime output remain authoritative.

## Current branch families

- `trust-mieru-dual` — stable Trust + Mieru dual-carrier architecture.
- `triple-carrier-naive` — unified Trust + Mieru + Naive architecture.
- `maya3-multilane-naive` — earlier selective Lane3 design.
- `naive-mieru-dual` — Naive replacement experiment.
- `maya4-naive-lite` — lightweight Maya4 single-Naive architecture and automatic foreign replacement dashboard.

## Purpose

This repository is the main home for the Iran ↔ Foreign tunnel projects.

Primary goals:

- stability first;
- low freeze/disconnect rate;
- server-side foreign replacement;
- simple recovery;
- reversible production changes;
- documented deployment and troubleshooting.

## Safety

Do not commit or paste private bundles, passwords, XUDP UUIDs, x-ui user UUIDs, private keys or other secrets.

For all live work, current runtime output has priority over historical documentation.
