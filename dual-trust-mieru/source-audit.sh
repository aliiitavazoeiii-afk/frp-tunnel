#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"

echo "=== Dual Trust/Mieru source audit ==="
printf 'version='; cat VERSION
printf 'git_head='; git -C "$B" rev-parse HEAD 2>/dev/null || echo unknown

echo
echo "--- bash syntax ---"
for f in *.sh; do
  printf '%-36s ' "$f"
  bash -n "$f"
  echo OK
done

echo
echo "--- obsolete Iran runtime references ---"
# Only flag retired Iran runtime artifacts. rc15's official-carrier migration
# intentionally uses an isolated 17994 candidate and a temporary official
# Mieru JSON config, so exclude that migration helper from this legacy check.
if grep -RInE --exclude='source-audit.sh' --exclude='common.sh' --exclude='migrate-mieru-carrier-official.sh' \
  'dual-mieru-client([.]service|[[:space:]]|$)|17994|/mieru-client[.]json' .; then
  echo "ERROR: obsolete Iran runtime reference found" >&2
  exit 1
else
  echo "none"
fi

echo
echo "--- required project files ---"
for f in common.sh install-foreign-trust.sh install-foreign-mieru.sh install-iran.sh dual-probe.sh failover-test.sh status.sh attach-xui.sh replace-foreign.sh diagnose-mieru.sh migrate-mieru-carrier-official.sh uninstall-iran.sh; do
  [[ -s "$f" ]] || { echo "missing: $f" >&2; exit 1; }
  echo "OK $f"
done

echo
echo "SUCCESS: source audit passed"
