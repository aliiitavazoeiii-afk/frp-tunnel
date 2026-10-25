#!/usr/bin/env bash
# Adds 'maya4 replace /root/new-bundle.json' to installed Maya4 CLI.
# Does not touch systemd, x-ui, subscriptions, firewall or transport configs.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
CLI=/usr/local/bin/maya4
SCRIPT=/opt/frp-tunnel/maya4-naive-lite/replace-foreign.sh
[[ -x "$CLI" && -s "$SCRIPT" ]] || { echo "Maya4 CLI or replacement script missing" >&2; exit 1; }
grep -Fq 'status|health) exec /usr/local/sbin/maya4-health ;;' "$CLI" ||
 { echo "Unknown Maya4 CLI layout; refusing to overwrite" >&2; exit 1; }
grep -Fq 'attach) exec /usr/local/sbin/maya4-attach ;;' "$CLI" ||
 { echo "Maya4 attach action missing; refusing to overwrite" >&2; exit 1; }
if grep -Fq 'replace) shift;' "$CLI"; then
 echo "Maya4 CLI already supports replace"
 exit 0
fi
python3 - "$CLI" <<'PY'
from pathlib import Path
import os,sys,tempfile
p=Path(sys.argv[1])
s=p.read_text()
anchor='  restart)\n'
if s.count(anchor)!=1:
    raise SystemExit("Unknown Maya4 CLI syntax; unchanged")
new=s.replace(anchor, '  replace) shift; exec /bin/bash /opt/frp-tunnel/maya4-naive-lite/replace-foreign.sh "$@" ;;\n'+anchor)
fd,tmp=tempfile.mkstemp(prefix='.maya4-cli-',dir=str(p.parent))
os.chmod(tmp,0o755)
try:
    with os.fdopen(fd,'w') as out: out.write(new)
    import subprocess
    result=subprocess.run(['/bin/bash','-n',tmp],check=False)
    if result.returncode:
        raise RuntimeError("CLI syntax validation failed")
    import shutil
    backup=p.with_name(p.name+'.before-replace')
    if not backup.exists():
        shutil.copy2(p,backup)
    os.replace(tmp,p)
except BaseException:
    if os.path.exists(tmp): os.unlink(tmp)
    raise
PY
echo 'SUCCESS: Maya4 manager now supports: sudo maya4 replace /root/new-maya4-naive-client.json'
