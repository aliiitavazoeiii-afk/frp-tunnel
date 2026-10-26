#!/usr/bin/env python3
"""Dual Trust/Mieru full-path health and conservative pool quarantine.

Default: observe only; no writes, restarts or controller changes.
Active mode: explicit --mode auto, guarded by healthy surviving route.
Requires Python 3 stdlib plus curl and the installed Mihomo binary.
"""
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CFG = Path('/etc/dual-trust-mieru/iran/dispatcher.yaml')
SECRET = Path('/etc/dual-trust-mieru/iran/controller.secret')
STATE_DIR = Path('/var/lib/dual-trust-mieru/pool-guard')
STATE_FILE = STATE_DIR / 'state.json'
LOCK = '/run/dual-pool-guard.lock'
MIHOMO = '/usr/local/lib/dual-trust-mieru/mihomo'
DATA = '/etc/dual-trust-mieru/iran/dispatcher-data'
API = 'http://127.0.0.1:19090'
ROLES = {'trust': ('XUDP-TRUST', 7991), 'mieru': ('XUDP-MIERU', 7992)}
MIN_DWELL = 600
RECOVERY_STREAK = 3

def now():
    return int(time.time())

def say(message):
    print('[pool-guard] ' + message, flush=True)

def http_probe(port, url, allowed):
    cmd = ['curl', '-4', '-sS', '--socks5-hostname', '127.0.0.1:' + str(port),
           '--connect-timeout', '4', '--max-time', '7', '-o', '/dev/null',
           '-w', '%{http_code} %{time_total}', url]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=9, check=False)
        fields = p.stdout.strip().split()
        if p.returncode != 0 or len(fields) != 2:
            return False, None
        code, seconds = fields
        return code in allowed and float(seconds) <= 7.0, round(float(seconds), 2)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False, None

def probe(role):
    _, port = ROLES[role]
    a, at = http_probe(port, 'https://www.gstatic.com/generate_204', {'204'})
    b, bt = http_probe(port, 'https://api.telegram.org/', {'200', '301', '302'})
    # Telegram Bot API HTTPS is a synthetic reachability signal, not MTProto.
    return {'ok': bool(a and b), 'web': a, 'telegram_https': b,
            'web_seconds': at, 'telegram_seconds': bt}

def full_probe(role):
    p = probe(role)
    if not p['ok']:
        time.sleep(2)
        q = probe(role)
        p['confirmed_bad'] = not q['ok']
        p['recheck'] = q
    else:
        p['confirmed_bad'] = False
    return p

def group_bounds(lines):
    starts = [i for i, v in enumerate(lines) if v.strip() == 'proxy-groups:']
    if len(starts) != 1:
        raise RuntimeError('expected a single proxy-groups section')
    start = next((i for i in range(starts[0]+1, len(lines))
                  if re.fullmatch(r'  - name:\s*DUAL\s*\n?', lines[i])), -1)
    if start < 0:
        raise RuntimeError('DUAL group not found')
    end = next((i for i in range(start+1, len(lines))
                if lines[i].startswith('  - name:') or
                (lines[i] and not lines[i][0].isspace() and lines[i].strip())), len(lines))
    block = ''.join(lines[start:end])
    if not re.search(r'(?m)^    type: load-balance\s*$', block):
        raise RuntimeError('DUAL is no longer a load-balance group')
    if not re.search(r'(?m)^    strategy: sticky-sessions\s*$', block):
        raise RuntimeError('refusing to alter a non-sticky routing policy')
    p = next((i for i in range(start+1, end) if lines[i].strip() == 'proxies:'), -1)
    if p < 0 or not lines[p].startswith('    '):
        raise RuntimeError('DUAL group proxies list missing')
    first = p + 1
    last = first
    while last < end and lines[last].startswith('      - '):
        last += 1
    old = [v.strip()[2:].strip() for v in lines[first:last]]
    if not old or len(set(old)) != len(old):
        raise RuntimeError('invalid or empty DUAL group')
    names = {node for node, _ in ROLES.values()}
    if not set(old) <= names:
        raise RuntimeError('this guard is Dual-only; refuse Triple/Naive config')
    return first, last, old

def change_members(text, members):
    lines = text.splitlines(keepends=True)
    a, b, old = group_bounds(lines)
    if not members or not set(members) <= {x for x, _ in ROLES.values()}:
        raise RuntimeError('invalid desired membership')
    result = lines[:a] + ['      - ' + x + '\n' for x in members] + lines[b:]
    return ''.join(result), old

def api(method, path, obj=None):
    if not SECRET.is_file():
        raise RuntimeError('controller secret not installed')
    secret = SECRET.read_text(encoding='utf-8').strip()
    if not secret:
        raise RuntimeError('empty controller secret')
    payload = None if obj is None else json.dumps(obj).encode()
    req = Request(API + path, data=payload, method=method,
                  headers={'Authorization': 'Bearer ' + secret,
                           'Content-Type': 'application/json'})
    try:
        with urlopen(req, timeout=8) as response:
            body = response.read(1048576)
            if response.status not in (200, 204):
                raise RuntimeError('controller returned unexpected HTTP status')
            return json.loads(body) if body else None
    except (HTTPError, URLError) as exc:
        raise RuntimeError('local Mihomo controller unavailable or rejected request') from exc

def atomic_write(path, content):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.guard-', dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)

def state_from_config(members):
    q = {}
    for role, (node, _) in ROLES.items():
        if node not in members:
            q[role] = {'since': now(), 'recoveries': 0}
    return {'quarantined': q}

def load_state(members):
    if not STATE_FILE.is_file():
        return state_from_config(members)
    data = json.loads(STATE_FILE.read_text(encoding='utf-8'))
    if not isinstance(data, dict) or not isinstance(data.get('quarantined'), dict):
        raise RuntimeError('invalid saved quarantine state')
    for role, (node, _) in ROLES.items():
        if (role in data['quarantined']) != (node not in members):
            raise RuntimeError('live pool differs from state; manual reconciliation required')
    return data

def validate_config(candidate):
    with tempfile.TemporaryDirectory(prefix='guard-', dir='/tmp') as tmpdir:
        test = Path(tmpdir) / 'dispatcher.yaml'
        test.write_text(candidate, encoding='utf-8')
        result = subprocess.run([MIHOMO, '-t', '-d', DATA, '-f', str(test)],
                                capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            raise RuntimeError('candidate failed Mihomo config validation')

def apply_members(original, desired):
    candidate, old = change_members(original, desired)
    if old == desired:
        return
    validate_config(candidate)
    # Controller reload without force=true; never restart x-ui or dispatcher.
    # Roll back in-memory state on any mismatch, then retain disk backup.
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = STATE_DIR / ('dispatcher-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '.yaml')
    atomic_write(backup, original)
    reloaded = False
    try:
        api('PUT', '/configs', {'payload': candidate})
        reloaded = True
        info = api('GET', '/proxies/DUAL')
        if not isinstance(info, dict) or info.get('type', '').lower() not in ('loadbalance', 'load-balance'):
            raise RuntimeError('Mihomo DUAL group type mismatch after reload')
        if info.get('all') != desired:
            raise RuntimeError('Mihomo actual pool membership mismatch after reload')
        if CFG.read_text(encoding='utf-8') != original:
            raise RuntimeError('dispatcher file changed during guard transaction')
        atomic_write(CFG, candidate)
        say('applied: DUAL=' + ','.join(desired) + '; backup=' + str(backup))
    except Exception:
        if reloaded:
            try:
                api('PUT', '/configs', {'payload': original})
            except Exception:
                say('CRITICAL: API rollback failed; inspect the live dispatcher before proceeding')
        raise

def execute(mode):
    original = CFG.read_text(encoding='utf-8')
    _, old = change_members(original, ['XUDP-TRUST', 'XUDP-MIERU'])
    state = load_state(old)
    tests = {role: full_probe(role) for role in ROLES}
    say('mode=' + mode + ' live_pool=' + ','.join(old))
    for role in ROLES:
        v = tests[role]
        say(role + ': ' + ('OK' if v['ok'] else 'DEGRADED') +
            ' web=' + str(v['web_seconds']) + 's telegram=' +
            str(v['telegram_seconds']) + 's confirmed_bad=' + str(v['confirmed_bad']))
    if mode == 'observe':
        say('observe-only: no config, service, or state changes')
        return

    desired = list(old)
    q = state['quarantined']
    t = now()
    for role, (node, _) in ROLES.items():
        result = tests[role]
        other = 'mieru' if role == 'trust' else 'trust'
        if role not in q:
            if result['confirmed_bad'] and tests[other]['ok'] and node in desired:
                desired.remove(node)
                q[role] = {'since': t, 'recoveries': 0}
                say('quarantine ' + role + ' (confirmed failure; peer passed)')
        else:
            if result['ok']:
                q[role]['recoveries'] = int(q[role].get('recoveries', 0)) + 1
            else:
                q[role]['recoveries'] = 0
            if (result['ok'] and t - int(q[role]['since']) >= MIN_DWELL
                    and q[role]['recoveries'] >= RECOVERY_STREAK):
                desired.append(node)
                del q[role]
                say('recover ' + role + ' after dwell and consecutive checks')
    if not desired:
        raise RuntimeError('refuse to remove all foreign carriers')
    # No two simultaneous contradictory modifications; state only committed
    # after the controller verifies live membership.
    apply_members(original, desired)
    atomic_write(STATE_FILE, json.dumps(state, sort_keys=True, indent=2) + '\n')

def main():
    parser = argparse.ArgumentParser(description='Dual Trust/Mieru pool guard')
    parser.add_argument('--mode', choices=['observe', 'auto'], default='observe')
    a = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('run as root (controller credentials must remain private)')
    with open(LOCK, 'w', encoding='utf-8') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            say('already running; skipping overlapping check')
            return
        execute(a.mode)

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, json.JSONDecodeError, ValueError) as exc:
        print('[pool-guard] ERROR: ' + str(exc), file=sys.stderr)
        sys.exit(1)
