#!/usr/bin/env python3
"""Propose or apply Naive/Mieru per-connection round-robin. NEVER reload with active users."""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen

BASE = pathlib.Path('/etc/dual-trust-mieru/iran')
CFG = BASE / 'dispatcher.yaml'
SECRET = BASE / 'controller.secret'
BIN = '/usr/local/lib/dual-trust-mieru/mihomo'
DATA = str(BASE / 'dispatcher-data')
SAVE = pathlib.Path('/var/lib/dual-trust-mieru/naive-mieru/dispatcher-before-round-robin.yaml')
URL = 'http://127.0.0.1:19090'

def api(method, path, body=None):
    secret = SECRET.read_text().strip()
    req = Request(URL+path, method=method,
                  data=json.dumps(body).encode() if body is not None else None,
                  headers={'Authorization':'Bearer '+secret,
                           'Content-Type':'application/json'})
    with urlopen(req, timeout=8) as reply:
        blob = reply.read()
        return json.loads(blob) if blob else {}

def build(old):
    expected = [
        ('  - name: XUDP-TRUST\n', '  - name: XUDP-NAIVE\n'),
        ('      - XUDP-TRUST\n', '      - XUDP-NAIVE\n'),
        ('    strategy: sticky-sessions\n', '    strategy: round-robin\n'),
        ('    interval: 120\n', '    interval: 60\n'),
        ('    lazy: true\n', '    lazy: false\n'),
    ]
    changed = old
    for a, b in expected:
        if changed.count(a) != 1:
            raise RuntimeError('refusing unfamiliar dispatcher layout: '+a.strip())
        changed=changed.replace(a,b,1)
    if changed.count('      - XUDP-MIERU\n') != 1:
        raise RuntimeError('Mieru membership mismatch')
    if changed.count('    type: load-balance\n') != 1:
        raise RuntimeError('expected one load-balance pool')
    return changed

def probe(port):
    p = subprocess.run(['curl','-4','-sS','--socks5-hostname',
        '127.0.0.1:'+str(port),'--connect-timeout','4','--max-time','9',
        '-o','/dev/null','-w','%{http_code}',
        'https://www.gstatic.com/generate_204'],
        capture_output=True, text=True, timeout=11)
    return p.returncode==0 and p.stdout.strip()=='204'

def write_atomic(p, text):
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd,name=tempfile.mkstemp(prefix='.nm-',dir=str(p.parent))
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w') as f:
            f.write(text);f.flush();os.fsync(f.fileno())
        os.replace(name,p)
    finally:
        if os.path.exists(name): os.unlink(name)

def active_sessions():
    data=api('GET','/connections')
    if not isinstance(data.get('connections'),list):
        raise RuntimeError('cannot prove zero active users; refuse configuration reload')
    return len(data['connections'])

def validate(text):
    with tempfile.TemporaryDirectory(prefix='nm-yaml-') as d:
        f=pathlib.Path(d)/'dispatcher.yaml'
        f.write_text(text)
        os.chmod(f,0o600)
        p=subprocess.run([BIN,'-t','-d',DATA,'-f',str(f)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,timeout=15)
        if p.returncode: raise RuntimeError('Mihomo rejected candidate config')

def main():
    parser=argparse.ArgumentParser()
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--plan',action='store_true')
    mode.add_argument('--apply',action='store_true')
    mode.add_argument('--rollback',action='store_true')
    args=parser.parse_args()
    if os.geteuid()!=0: raise RuntimeError('run as root')
    if args.rollback:
        if not SAVE.is_file(): raise RuntimeError('no saved configuration')
        candidate=SAVE.read_text()
    else:
        candidate=build(CFG.read_text())
    if args.plan:
        print('PLAN: route Naive/Mieru ~50/50 by NEW CONNECTION COUNT, round-robin')
        print('Changes: XUDP-TRUST internal alias -> XUDP-NAIVE, 120s lazy sticky -> 60s eager round-robin')
        print('DRY RUN ONLY: no live reload, no service restarts, no credential output')
        return
    if not pathlib.Path('/var/lib/dual-trust-mieru/naive-mieru/live-cutover.timestamp').is_file():
        raise RuntimeError('Naive live cutover not confirmed')
    if not probe(7991) or not probe(7992):
        raise RuntimeError('a carrier is currently unhealthy; refuse reload')
    if subprocess.run(['systemctl','is-active','--quiet','nm-naive-client.service']).returncode:
        raise RuntimeError('Naive not active')
    count=active_sessions()
    if count!=0:
        raise RuntimeError('SAFETY BLOCK: '+str(count)+' active connections; reload could interrupt Mieru users. Keep STICKY until maintenance window with zero sessions.')
    validate(candidate)
    old=CFG.read_text()
    if old==candidate:
        print('Already configured');return
    if args.apply and SAVE.exists():
        raise RuntimeError('immutable rollback backup already exists; inspect before proceeding')
    if args.apply: write_atomic(SAVE,old)
    applied=False
    try:
        api('PUT','/configs',{'payload':candidate})
        applied=True
        info=api('GET','/proxies/DUAL')
        desired=['XUDP-MIERU','XUDP-NAIVE'] if args.apply else ['XUDP-MIERU','XUDP-TRUST']
        if set(info.get('all',[]))!=set(desired):
            raise RuntimeError('pool API readback differs from intended membership')
        write_atomic(CFG,candidate)
    except Exception:
        if applied:
            try: api('PUT','/configs',{'payload':old})
            except Exception: print('CRITICAL: in-memory rollback rejected; operator intervention required',file=sys.stderr)
        raise
    print('SUCCESS: pool updated via localhost API, no systemd restarts. Check current connections and real user experience.')

if __name__=='__main__':
    try:main()
    except (Exception) as exc:
        print('ERROR:',exc,file=sys.stderr);sys.exit(1)
