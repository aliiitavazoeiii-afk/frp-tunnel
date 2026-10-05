#!/usr/bin/env bash
set -Eeuo pipefail
WEB=/var/www/direct-naive
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
[[ -d "$WEB" ]] || { echo 'direct-naive web root not found' >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/assets"
A=$(openssl rand -hex 6); B=$(openssl rand -hex 6); C=$(openssl rand -hex 6); D=$(openssl rand -hex 6)
cat >"$T/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Media Notes</title><meta name="description" content="Notes, catalog entries and recent media updates."><link rel="icon" href="/assets/i-${D}.svg"><link rel="stylesheet" href="/assets/s-${A}.css"></head><body><header><strong>Media Notes</strong><nav><a href="/archive.html">Archive</a><a href="/contact.html">Contact</a></nav></header><main><article><small>RECENT</small><h1>Notes from the archive</h1><p>Selections, release notes and links are collected here.</p><img src="/assets/c-${C}.svg" width="720" height="240" alt="Archive cover"></article></main><script src="/assets/a-${B}.js" defer></script></body></html>
EOF
cat >"$T/archive.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Archive</title></head><body><main><h1>Archive</h1><p>Older entries are moved here.</p><a href="/">Home</a></main></body></html>
EOF
cat >"$T/contact.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Contact</title></head><body><main><h1>Contact</h1><p>General information page.</p><a href="/">Home</a></main></body></html>
EOF
cat >"$T/assets/s-${A}.css" <<'EOF'
:root{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;color:#202124;background:#f7f8f9}body{margin:0}header,main{max-width:920px;margin:auto;padding:24px}header{display:flex;justify-content:space-between}nav{display:flex;gap:18px}a{color:inherit;text-decoration:none}article{margin-top:7vh;padding:34px;background:white;border:1px solid #e5e7e9;border-radius:16px}h1{font-size:clamp(2rem,5vw,3.8rem);margin:.25em 0}small{letter-spacing:.16em;color:#6b7075}img{width:100%;height:auto;margin-top:26px;border-radius:12px}@media(max-width:620px){nav{display:none}}
EOF
cat >"$T/assets/a-${B}.js" <<'EOF'
document.documentElement.dataset.loaded=String(Date.now()>0);
EOF
cat >"$T/assets/c-${C}.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 240"><rect width="720" height="240" rx="20" fill="#eef0f2"/><path d="M90 70h540v100H90z" fill="#e1e4e7"/><circle cx="170" cy="120" r="36" fill="#cfd3d7"/><path d="M240 96h270M240 122h220M240 148h245" stroke="#c7cbd0" stroke-width="12" stroke-linecap="round"/></svg>
EOF
cat >"$T/assets/i-${D}.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="16" fill="#5d6268"/><circle cx="32" cy="32" r="13" fill="#f1f3f4"/></svg>
EOF
find "$T" -type f -exec chmod 0644 {} +
rm -rf "$WEB.old"
mv "$WEB" "$WEB.old"
mv "$T" "$WEB"
trap - EXIT
rm -rf "$WEB.old"
echo 'SUCCESS: front profile rotated; proxy credentials and TLS identity unchanged'
