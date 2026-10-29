#!/usr/bin/env bash
# Backup ONLY the local 3x-ui SQLite database and generated Xray config.
# No Xray reload, no DB mutations, no downtime. Keep backup OFF CHAT.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run this backup as root"; exit 2; }
if [[ -e /etc/default/x-ui ]] && grep -Eq '^XUI_DB_TYPE=(postgres|postgresql|pg)' /etc/default/x-ui; then
  echo "Configured PostgreSQL backend: use pg_dump for an authoritative backup; do NOT assume SQLite." >&2
  exit 2
fi
DB=/etc/x-ui/x-ui.db
[[ -r "$DB" ]] || { echo "SQLite DB is missing or unreadable at $DB (custom path or PostgreSQL?)"; exit 2; }
umask 077
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
folder="/root/dual-ha-xui-backup-$stamp"
if [[ -e "$folder" ]]; then
  echo "Backup destination already exists: $folder" >&2
  exit 2
fi
install -d -m 0700 "$folder"
python3 - "$DB" "$folder/x-ui.db" <<'PY'
import sqlite3,sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:])
src_uri="file:"+str(src)+"?mode=ro"
with sqlite3.connect(src_uri,uri=True,timeout=15) as db:
    with sqlite3.connect(dst,timeout=15) as output:
        db.backup(output,pages=256,sleep=0.1)
        result=output.execute("PRAGMA integrity_check").fetchone()[0]
        if result!="ok":
            raise SystemExit("Backup failed SQLite integrity check: "+result)
dst.chmod(0o600)
print("SQLite online backup complete; integrity_check=ok")
PY
for file in /usr/local/x-ui/bin/config.json /usr/local/x-ui/bin/xray-config.json; do
  if [[ -f "$file" ]]; then
    install -m 0600 "$file" "$folder/$(basename "$file")"
  fi
done
sha256sum "$folder/x-ui.db" | awk '{print "DB backup SHA256:",$1}'
echo "BACKUP_PATH=$folder"
echo "Keep this directory private. It contains live user identities and credentials."
echo "No systemd services or Xray config were changed."
