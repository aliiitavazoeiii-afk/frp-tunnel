#!/usr/bin/env python3
import os, re, shutil, subprocess, sys, tempfile, time
from datetime import datetime, timezone

CFG = '/etc/dual-trust-mieru/iran/dispatcher.yaml'
DATA = '/etc/dual-trust-mieru/iran/dispatcher-data'
MIHOMO = '/usr/local/lib/dual-trust-mieru/mihomo'
BACKUPS = '/var/lib/dual-trust-mieru/lane3/backups'

def run(cmd, check=True, quiet=False):
    kw = {}
    if quiet:
        kw.update(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return subprocess.run(cmd, check=check, **kw)

def active(unit):
    return subprocess.run(['systemctl','is-active','--quiet',unit]).returncode == 0

def read_cfg():
    if not os.path.isfile(CFG):
        raise RuntimeError('dispatcher config missing')
    return open(CFG, encoding='utf-8').read()

def has_naive(text=None):
    text = text if text is not None else read_cfg()
    proxy = re.search(r'(?m)^  - name:\s*XUDP-NAIVE\s*$', text) is not None
    member = re.search(r'(?m)^      - XUDP-NAIVE\s*$', text) is not None
    return proxy and member

def validate_profile(text):
    required = [
        (r'(?m)^\s*strategy:\s*sticky-sessions\s*$', 'strategy=sticky-sessions'),
        (r'(?m)^\s*interval:\s*120\s*$', 'interval=120'),
        (r'(?m)^\s*lazy:\s*true\s*$', 'lazy=true'),
        (r'(?m)^\s*max-failed-times:\s*2\s*$', 'max-failed-times=2'),
    ]
    for pat, label in required:
        if not re.search(pat, text):
            raise RuntimeError(f'refusing change: dispatcher must keep {label}')

def strip_naive(lines):
    try:
        pg = next(i for i,x in enumerate(lines) if x == 'proxy-groups:')
    except StopIteration:
        raise RuntimeError('proxy-groups section missing')
    out=[]; i=0
    while i < len(lines):
        if i < pg and re.fullmatch(r'  - name:\s*XUDP-NAIVE\s*', lines[i]):
            i += 1
            while i < pg and not re.match(r'^  - name:', lines[i]):
                i += 1
            continue
        if re.fullmatch(r'\s*-\s*XUDP-NAIVE\s*', lines[i]):
            i += 1
            continue
        out.append(lines[i]); i += 1
    return out

def patch(text, enable):
    lines = strip_naive(text.splitlines())
    if not enable:
        out='\n'.join(lines)+'\n'
        if 'XUDP-NAIVE' in out:
            raise RuntimeError('Naive references survived disable')
        return out
    try:
        pg = next(i for i,x in enumerate(lines) if x == 'proxy-groups:')
    except StopIteration:
        raise RuntimeError('proxy-groups section missing')
    block=[
        '  - name: XUDP-NAIVE',
        '    type: socks5',
        '    server: 127.0.0.1',
        '    port: 7996',
        '    udp: true',
    ]
    lines[pg:pg]=block
    pg = next(i for i,x in enumerate(lines) if x == 'proxy-groups:')
    dual = next((i for i in range(pg+1,len(lines)) if re.fullmatch(r'  - name:\s*DUAL\s*', lines[i])), None)
    if dual is None:
        raise RuntimeError('DUAL proxy-group missing')
    plist = next((i for i in range(dual+1,len(lines)) if re.fullmatch(r'    proxies:\s*', lines[i])), None)
    if plist is None:
        raise RuntimeError('DUAL proxies list missing')
    pos = plist + 1
    while pos < len(lines) and re.match(r'^      - ', lines[pos]):
        pos += 1
    lines.insert(pos, '      - XUDP-NAIVE')
    out='\n'.join(lines)+'\n'
    if out.count('name: XUDP-NAIVE') != 1 or out.count('- XUDP-NAIVE') < 1:
        raise RuntimeError('Naive pool insertion failed')
    return out

def quick_naive_health():
    if not active('lane3-naive-client.service') or not active('lane3-xudp-router.service'):
        return False
    return subprocess.run(['/usr/local/sbin/dual-health','--quick','naive'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def unified_http_ok():
    cmd=['curl','-4','-sS','--socks5-hostname','127.0.0.1:7990','--connect-timeout','5','--max-time','10','-o','/dev/null','-w','%{http_code}','https://www.gstatic.com/generate_204']
    p=subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return p.returncode == 0 and p.stdout.strip() == '204'

def apply(enable):
    old = read_cfg()
    validate_profile(old)
    if enable:
        if has_naive(old):
            print('Naive is already ENABLED in unified :7990 pool')
            return
        if not quick_naive_health():
            raise RuntimeError('Naive path unhealthy; dispatcher unchanged')
    else:
        if not has_naive(old):
            print('Naive is already DISABLED from unified :7990 pool')
            return
    new = patch(old, enable)
    validate_profile(new)
    os.makedirs(BACKUPS, exist_ok=True)
    os.chmod(BACKUPS, 0o700)
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup=os.path.join(BACKUPS, f'dispatcher-{stamp}.yaml')
    shutil.copy2(CFG, backup)
    os.chmod(backup, 0o600)
    fd,tmp=tempfile.mkstemp(prefix='.dispatcher.', suffix='.yaml', dir=BACKUPS)
    os.close(fd)
    try:
        open(tmp,'w',encoding='utf-8').write(new)
        os.chmod(tmp,0o600)
        run([MIHOMO,'-t','-d',DATA,'-f',tmp], quiet=True)
        shutil.copy2(tmp,CFG); os.chmod(CFG,0o600)
        run(['systemctl','restart','dual-dispatcher.service'])
        time.sleep(2)
        if not active('dual-dispatcher.service') or not unified_http_ok():
            raise RuntimeError('dispatcher post-check failed')
        live=read_cfg()
        if has_naive(live) != enable:
            raise RuntimeError('dispatcher membership post-check failed')
    except Exception:
        print('ROLLBACK: restoring previous dispatcher config', file=sys.stderr)
        shutil.copy2(backup,CFG)
        subprocess.run(['systemctl','restart','dual-dispatcher.service'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
        raise
    finally:
        try: os.remove(tmp)
        except OSError: pass
    print(f'SUCCESS: Naive {"ENABLED" if enable else "DISABLED"} in unified :7990 pool')
    print(f'Only dual-dispatcher.service restarted. Backup: {backup}')

def main():
    if os.geteuid() != 0:
        raise SystemExit('run as root')
    action=sys.argv[1] if len(sys.argv)>1 else 'status'
    if action=='status':
        print('ENABLED' if has_naive() else 'DISABLED')
    elif action=='enable':
        apply(True)
    elif action=='disable':
        apply(False)
    else:
        raise SystemExit('usage: lane3-pool [status|enable|disable]')

if __name__=='__main__':
    try:
        main()
    except Exception as e:
        print(f'ERROR: {e}', file=sys.stderr)
        raise SystemExit(1)
