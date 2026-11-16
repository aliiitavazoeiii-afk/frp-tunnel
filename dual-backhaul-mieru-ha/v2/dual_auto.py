#!/usr/bin/env python3
"""One-password, survivable-path rotation for existing Dual HA v2 on Iran.

Uses the installed 'dual' runtime and foreign installer. Never modifies Xray.
The old foreign host is deliberately not required to be SSH-accessible.
"""
from __future__ import annotations

import base64
import datetime
import getpass
import hashlib
import ipaddress
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import time

import dual

GUARD = Path("/usr/local/sbin/dual-ha-rotation-guard.sh")
UNIT = Path("/etc/systemd/system/dual-ha-rotation-guard.service")
OLD_GUARD = Path("/usr/local/sbin/bh4-backhaul-guard.sh")


def sh(args, check=True, timeout=30):
    p = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and p.returncode:
        raise RuntimeError("%s failed (%s): %s" % (args[0], p.returncode, p.stderr[-250:]))
    return p


def ipaddr(value):
    addr = ipaddress.ip_address(value)
    if not isinstance(addr, ipaddress.IPv4Address) or not addr.is_global:
        raise ValueError("A public IPv4 is required")
    return str(addr)


def ensure_key():
    path = Path("/root/.ssh/id_ed25519")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists() and not path.with_suffix(".pub").exists():
        raise RuntimeError("Existing SSH private key has no public key; refusing to replace it")
    if not path.exists():
        sh(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)])
    return path.with_suffix(".pub").read_text().strip()


def authorize_new(ip):
    """Password used only to authorize a key on the NEW fresh foreign host."""
    try:
        import paramiko
    except ImportError:
        raise RuntimeError("Missing python3-paramiko; run the provided installer")

    # A previous failed attempt may already have installed our key securely.
    try:
        if dual.ssh(ip, "echo AUTO_SSH_OK", timeout=15).strip() == "AUTO_SSH_OK":
            print("Reusing existing verified SSH key; no password needed.")
            return
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        pass

    pub = ensure_key()
    password = getpass.getpass("NEW VPS root SSH password (not saved): ")
    if not password:
        raise RuntimeError("Empty SSH password")
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    known = Path("/root/.ssh/known_hosts")
    if known.exists():
        client.load_host_keys(str(known))

    class VerifyNew(paramiko.MissingHostKeyPolicy):
        def missing_host_key(self, ssh, host, key):
            fp = base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
            print("\nNew SSH host key for %s: %s SHA256:%s" % (host, key.get_name(), fp))
            print("Verify the fingerprint using your VPS provider console, not this output alone.")
            confirmation = input("After independent verification, type YES: ").strip()
            if confirmation != "YES":
                raise RuntimeError("New SSH host key was not verified")
            ssh.get_host_keys().add(host, key.get_name(), key)
            known.parent.mkdir(parents=True, exist_ok=True)
            ssh.save_host_keys(str(known))

    client.set_missing_host_key_policy(VerifyNew())
    try:
        client.connect(ip, username="root", password=password, look_for_keys=False,
                       allow_agent=False, timeout=15, auth_timeout=15, banner_timeout=15)
        cmd = (
            "umask 077; mkdir -p /root/.ssh; chmod 700 /root/.ssh; "
            "touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; "
            "grep -Fxq {key} /root/.ssh/authorized_keys || "
            "printf '%s\\n' {key} >>/root/.ssh/authorized_keys"
        ).format(key=shlex.quote(pub))
        stdin, stdout, stderr = client.exec_command(cmd, timeout=20)
        status = stdout.channel.recv_exit_status()
        err = stderr.read().decode()[-250:] if status else ""
        stdin.close()
        stdout.close()
        stderr.close()
        if status:
            raise RuntimeError("SSH key authorization failed: " + err)
    finally:
        password = None
        client.close()
    # The installed dual.py uses strict key-only SSH. Verify without password.
    print("Checking strict new-host SSH key login...", flush=True)
    print(dual.ssh(ip, "echo NEW_SSH_KEY_OK", timeout=20).strip())


def run_guard(iran):
    """Always reconstruct the guarded allowlist from the currently active bundle."""
    if iran != ipaddr(dual.iran_ip()):
        raise RuntimeError("Configured Iran public IPv4 changed during rotation; refusing guard update")
    guard_code = r'''#!/usr/bin/env bash
set -Eeuo pipefail
B=/etc/dual-ha/backhaul-bundle.env
IP="$(sed -n "s/^BH_FOREIGN_IP='\([0-9.]*\)'$/\1/p" "$B")"
IRAN="$(sed -n "s/^BH_IRAN_IP='\([0-9.]*\)'$/\1/p" "$B")"
[[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
[[ "$IRAN" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
CHAIN=DUAL_HA_ROTATION
iptables -w -N "$CHAIN" 2>/dev/null || true
iptables -w -F "$CHAIN"
iptables -w -A "$CHAIN" -i lo -j ACCEPT
iptables -w -A "$CHAIN" -s "$IP" -j ACCEPT
iptables -w -A "$CHAIN" -j REJECT --reject-with tcp-reset
iptables -w -C INPUT -d "$IRAN" -p tcp --dport 18443 -j "$CHAIN" 2>/dev/null ||
  iptables -w -I INPUT 1 -d "$IRAN" -p tcp --dport 18443 -j "$CHAIN"
echo "Backhaul source allowlist: $IP"
'''
    dual.atomic_write(GUARD, guard_code.encode())
    GUARD.chmod(0o700)
    # If a legacy Maya4 guard remains enabled, delegate it to the dynamic rule.
    if OLD_GUARD.exists():
        dual.atomic_write(OLD_GUARD, b'#!/usr/bin/env bash\nexec /usr/local/sbin/dual-ha-rotation-guard.sh\n')
        OLD_GUARD.chmod(0o700)
    if not UNIT.exists():
        UNIT.write_text(
            "[Unit]\nDescription=Dual HA dynamic backhaul source guard\n"
            "Before=dual-ha-backhaul-tls.service\n"
            "After=maya3-backhaul-guard.service\n"
            "[Service]\nType=oneshot\n"
            "ExecStart=/usr/local/sbin/dual-ha-rotation-guard.sh\n"
            "RemainAfterExit=yes\n"
            "[Install]\nWantedBy=multi-user.target\n"
        )
    drop = Path("/etc/systemd/system/dual-ha-backhaul-tls.service.d")
    drop.mkdir(parents=True, exist_ok=True)
    (drop / "rotation-guard.conf").write_text(
        "[Unit]\nRequires=dual-ha-rotation-guard.service\n"
        "After=dual-ha-rotation-guard.service\n"
    )
    sh(["systemctl", "daemon-reload"])
    sh(["systemctl", "enable", "dual-ha-rotation-guard.service"])
    sh([str(GUARD)])


def add_rule(rule):
    sh(["iptables", "-w", "-I", "INPUT", "1", *rule])


def del_rule(rule):
    sh(["iptables", "-w", "-D", "INPUT", *rule], check=False)


def prepared_backhaul_install(ip, iran, candidate):
    """Stage into a unique file: never clobber or reject a stale bundle from a prior attempt."""
    preflight = r"""set -eu
if systemctl is-active --quiet dual-ha-mita 2>/dev/null; then
  echo 'ACTIVE_MIERU_REFUSED' >&2; exit 21
fi
if systemctl is-active --quiet dual-ha-backhaul-client 2>/dev/null; then
  if [ -f /etc/dual-ha/backhaul-foreign.toml ] &&
     [ -x /opt/dual-ha/bin/backhaul ] &&
     systemctl is-active --quiet danted &&
     systemctl cat dual-ha-backhaul-client.service 2>/dev/null |
       grep -Fq 'ExecStart=/opt/dual-ha/bin/backhaul -c /etc/dual-ha/backhaul-foreign.toml'; then
    echo 'REUSE_ACTIVE_OWNED_BACKHAUL'
  else
    echo 'UNKNOWN_ACTIVE_INSTALL' >&2; exit 22
  fi
elif [ -e /etc/dual-ha/backhaul-foreign.toml ] ||
     [ -d /opt/dual-ha-src/frp-tunnel ]; then
  if [ -f /etc/dual-ha/backhaul-foreign.toml ] &&
     [ -x /opt/dual-ha/bin/backhaul ] &&
     systemctl is-active --quiet danted &&
     systemctl cat dual-ha-backhaul-client.service 2>/dev/null |
       grep -Fq 'ExecStart=/opt/dual-ha/bin/backhaul -c /etc/dual-ha/backhaul-foreign.toml'; then
    echo 'REUSE_FAILED_V3_CANDIDATE'
  else
    echo 'UNKNOWN_PARTIAL_INSTALL' >&2; exit 22
  fi
else
  if ss -Hlnpt '( sport = :11080 )' | grep -q LISTEN; then
    echo 'FOREIGN_SOCKS_PORT_BUSY' >&2; exit 23
  fi
  echo 'FRESH'
fi
"""
    state = dual.ssh(ip, preflight, timeout=20).strip()
    if state not in ("FRESH", "REUSE_FAILED_V3_CANDIDATE", "REUSE_ACTIVE_OWNED_BACKHAUL"):
        raise RuntimeError("Unrecognized foreign installer preflight state")
    if state == "REUSE_ACTIVE_OWNED_BACKHAUL":
        print("  Selected VPS has an ACTIVE existing Backhaul client.", flush=True)
        approval = input("  Type REUSE %s to stop/rekey only this VPS: " % ip).strip()
        if approval != "REUSE " + ip:
            raise RuntimeError("Active foreign Backhaul reuse was not approved")
    # The old helper used "test ! -e /root/dual-ha-backhaul-bundle.env".
    # This rejected hosts with harmless leftover bundle files and hid the reason.
    suffix = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    stage = "/root/.dual-ha-backhaul-candidate-%s-%s.env" % (suffix, os.getpid())
    print("Uploading private candidate bundle to a unique location...", flush=True)
    dual.scp(str(candidate), "root@" + ip + ":" + stage, timeout=50)
    expected = hashlib.sha256(candidate.read_bytes()).hexdigest()
    actual = dual.ssh(ip, "chmod 600 " + shlex.quote(stage) +
                      "; sha256sum " + shlex.quote(stage) + " | cut -d' ' -f1", timeout=15).strip()
    if actual != expected:
        raise RuntimeError("Candidate bundle transfer hash mismatch; no switch performed")
    if state == "REUSE_FAILED_V3_CANDIDATE":
        # This node belongs to a previous failed V3 attempt. Never wipe or
        # reinstall an unknown VPS: require an *old local V3 secret bundle*
        # that matches the current inactive foreign config and host identity.
        py = r'''
import os, pathlib, re, sys, tempfile
candidate_path, new, iran = sys.argv[1:]
config = pathlib.Path('/etc/dual-ha/backhaul-foreign.toml')
def values(path):
    out = {}
    for line in path.read_text().splitlines():
        match = re.fullmatch(r"([A-Z_]+)='([^']*)'", line)
        if match: out[match.group(1)] = match.group(2)
    return out
candidate = values(pathlib.Path(candidate_path))
if candidate.get('BH_IRAN_IP') != iran or candidate.get('BH_FOREIGN_IP') != new:
    raise SystemExit('CANDIDATE_HOST_MISMATCH')
original = config.read_text()
def field(name):
    matches = re.findall(r'(?m)^'+re.escape(name)+r' = "([^"]+)"$', original)
    if len(matches) != 1: raise SystemExit('UNKNOWN_FOREIGN_CONFIG_'+name)
    return matches[0]
domain = candidate.get('BH_DOMAIN','')
if not domain or field('tls_server_name') != domain or field('remote_addr') not in (domain+':18443', domain+':18444'):
    raise SystemExit('CANDIDATE_DOMAIN_MISMATCH')
verified = False
for path in pathlib.Path('/root').glob('.dual-ha-backhaul-candidate-*.env'):
    if str(path) == candidate_path: continue
    try:
        previous = values(path)
        if (previous.get('BH_IRAN_IP') == iran and
            previous.get('BH_FOREIGN_IP') == new and
            previous.get('BH_DOMAIN') == domain and
            previous.get('BH_TOKEN') == field('token') and
            previous.get('BH_CONTROL_PATH') == field('ws_control_path') and
            previous.get('BH_TUNNEL_PATH') == field('ws_tunnel_path')):
            verified = True
            break
    except (OSError, ValueError): pass
if not verified: raise SystemExit('PREVIOUS_V3_OWNER_PROOF_FAILED')
if not re.fullmatch('[a-f0-9]{64}',candidate.get('BH_TOKEN','')):
    raise SystemExit('INVALID_NEW_TOKEN')
for source, fieldname in [('BH_TOKEN','token'),('BH_CONTROL_PATH','ws_control_path'),('BH_TUNNEL_PATH','ws_tunnel_path')]:
    value = candidate.get(source,'')
    if not value or not re.fullmatch(r'/[a-z0-9/]+|[a-f0-9]{64}',value):
        raise SystemExit('INVALID_NEW_PATH_OR_TOKEN')
    original = re.sub(r'(?m)^'+re.escape(fieldname)+r' = "[^"]+"$',
                      lambda m, v=value, k=fieldname: k+' = "'+v+'"', original)
fd, temporary = tempfile.mkstemp(prefix='.dual-v3-',dir=str(config.parent))
try:
    os.fchmod(fd,0o600)
    with os.fdopen(fd,'w') as stream:
        stream.write(original)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary,config)
finally:
    if os.path.exists(temporary): os.unlink(temporary)
print('VERIFIED_PREVIOUS_V3_CANDIDATE_REUSED')
'''
        result = dual.ssh(ip, "python3 -c " + shlex.quote(py) + " " +
                          " ".join(shlex.quote(v) for v in (stage, ip, iran)),
                          timeout=25).strip()
        if result != "VERIFIED_PREVIOUS_V3_CANDIDATE_REUSED":
            raise RuntimeError("Could not safely reuse previous V3 candidate")
        print("Verified inactive foreign V3 candidate reused; no reinstall needed.", flush=True)
        return
    if state == "REUSE_ACTIVE_OWNED_BACKHAUL":
        # Never reinstall or overwrite transport options on a former VPS.
        # The candidate is operator-selected and never the current live egress.
        digest = hashlib.sha256(Path("/opt/dual-ha/bin/backhaul").read_bytes()).hexdigest()
        rekey = r'''
import hashlib,os,pathlib,re,subprocess,sys,tempfile,time
path,ip,iran,expected_sha=sys.argv[1:]
config=pathlib.Path('/etc/dual-ha/backhaul-foreign.toml')
binary=pathlib.Path('/opt/dual-ha/bin/backhaul')
def fail(message): raise SystemExit(message)
def one(text,key):
    found=re.findall(r'(?m)^'+re.escape(key)+r' = "([^"\r\n]*)"$',text)
    if len(found)!=1: fail('INVALID_OLD_CONFIG_'+key)
    return found[0]
bundle={}
for line in pathlib.Path(path).read_text().splitlines():
    m=re.fullmatch(r"([A-Z_]+)='([^']*)'",line)
    if m: bundle[m.group(1)]=m.group(2)
if bundle.get('BH_FOREIGN_IP')!=ip or bundle.get('BH_IRAN_IP')!=iran:
    fail('CANDIDATE_HOST_MISMATCH')
domain=bundle.get('BH_DOMAIN','')
if not re.fullmatch(r'([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}',domain):
    fail('INVALID_CANDIDATE_DOMAIN')
if config.is_symlink() or not config.is_file() or not binary.is_file():
    fail('UNKNOWN_BACKHAUL_INSTALL')
if hashlib.sha256(binary.read_bytes()).hexdigest()!=expected_sha:
    fail('BINARY_NOT_IDENTICAL_TO_IRAN')
def system(*args): return subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
if system('systemctl','is-active','--quiet','dual-ha-backhaul-client').returncode:
    fail('OLD_CLIENT_NOT_ACTIVE')
if system('systemctl','is-active','--quiet','danted').returncode:
    fail('DANTE_NOT_ACTIVE')
if system('systemctl','is-active','--quiet','dual-ha-mita').returncode==0:
    fail('MIERU_CONFLICT')
unit=system('systemctl','cat','dual-ha-backhaul-client.service')
if unit.returncode or 'ExecStart=/opt/dual-ha/bin/backhaul -c /etc/dual-ha/backhaul-foreign.toml' not in unit.stdout:
    fail('BACKHAUL_SERVICE_OWNERSHIP_NOT_VERIFIED')
listener=system('ss','-Hlnpt','( sport = :11080 )')
if listener.returncode or '127.0.0.1:11080' not in listener.stdout:
    fail('DANTE_LOOPBACK_NOT_VERIFIED')
original=config.read_text()
if (one(original,'transport')!='wssmux' or
    one(original,'tls_server_name')!=domain or
    one(original,'remote_addr')!=domain+':18443' or
    'tls_skip_verify = false' not in original):
    fail('OLD_BACKHAUL_DOMAIN_OR_TLS_MISMATCH')
if not re.fullmatch('[a-f0-9]{64}',one(original,'token')):
    fail('INVALID_OLD_TOKEN')
if not re.fullmatch('[a-f0-9]{64}',bundle.get('BH_TOKEN','')):
    fail('INVALID_CANDIDATE_TOKEN')
for field in ('ws_control_path','ws_tunnel_path'):
    if not re.fullmatch(r'/[a-z0-9/]+',one(original,field)):
        fail('INVALID_OLD_PATH_'+field)
for field in ('BH_CONTROL_PATH','BH_TUNNEL_PATH'):
    if not re.fullmatch(r'/[a-z0-9/]+',bundle.get(field,'')):
        fail('INVALID_NEW_PATH_'+field)
revised=original
for field,source in [('token','BH_TOKEN'),('ws_control_path','BH_CONTROL_PATH'),('ws_tunnel_path','BH_TUNNEL_PATH')]:
    revised=revised.replace(field+' = "'+one(original,field)+'"',
                            field+' = "'+bundle[source]+'"',1)
if revised==original: fail('NEW_CREDENTIALS_NOT_DIFFERENT')
# Preserve the existing config byte-for-byte with root-only permissions.
backup=config.with_name('backhaul-foreign.v3-prior-'+str(int(time.time()))+'.toml')
fd=os.open(str(backup),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as out:
    out.write(original);out.flush();os.fsync(out.fileno())
stopped=system('systemctl','disable','--now','dual-ha-backhaul-client.service')
if stopped.returncode: fail('FAILED_TO_STOP_PRIOR_CANDIDATE_CLIENT')
fd,tmp=tempfile.mkstemp(prefix='.v3-rekey-',dir=str(config.parent),text=True)
try:
    os.fchmod(fd,0o600)
    with os.fdopen(fd,'w') as out:
        out.write(revised);out.flush();os.fsync(out.fileno())
    os.replace(tmp,config)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print('VERIFIED_PRIOR_BACKHAUL_REKEYED')
'''
        call = "python3 -c " + shlex.quote(rekey) + " " + " ".join(
            shlex.quote(v) for v in (stage, ip, iran, digest))
        result = dual.ssh(ip, call, timeout=40).strip()
        if result != "VERIFIED_PRIOR_BACKHAUL_REKEYED":
            raise RuntimeError("Former VPS failed strict verification/rekeying")
        print("  Previously installed Backhaul reused; original foreign config backed up. "
              "Binary, TLS, WSSMux and performance settings unchanged.", flush=True)
        return
    args = ("bash -s -- --role backhaul --iran-ip %s --foreign-ip %s"
            " --bundle %s --prepare" %
            (shlex.quote(iran), shlex.quote(ip), shlex.quote(stage)))
    print("Installing fresh foreign Backhaul in PREPARE mode (no reverse connection yet)...", flush=True)
    p = subprocess.run(["ssh", *dual.SSH_OPTS, "root@" + ip, args],
                       input=dual.FOREIGN_INSTALL.read_bytes(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=420)
    log = (p.stdout + b"\n" + p.stderr).decode(errors="replace")
    if p.returncode:
        # Do not display private bundle values even if a future installer changes.
        for line in candidate.read_text().splitlines():
            if "=" in line:
                name, value = line.split("=", 1)
                if name in ("BH_TOKEN", "BH_CONTROL_PATH", "BH_TUNNEL_PATH"):
                    log = log.replace(value.strip().strip("'"), "[REDACTED]")
        print("FOREIGN INSTALL FAILURE (sanitized last output):\n" + log[-3500:],
              file=sys.stderr, flush=True)
        raise RuntimeError("Foreign PREPARE installer exited %d; no production switch performed" %
                           p.returncode)
    print("Foreign PREPARE complete; old Backhaul still serving.", flush=True)


def rotate_backhaul(old, new, iran, work):
    candidate = dual.backhaul_candidate_bundle(old, new, work)
    previous = dual.ETC / "backhaul-bundle.env"
    backup = previous.read_bytes()
    old_guard_contents = OLD_GUARD.read_bytes() if OLD_GUARD.exists() else None
    old_dynamic_contents = GUARD.read_bytes() if GUARD.exists() else None
    allow_new = ["-s", new, "-d", iran, "-p", "tcp", "--dport", "18443", "-j", "ACCEPT"]
    block_old = ["-s", old, "-d", iran, "-p", "tcp", "--dport", "18443",
                 "-j", "REJECT", "--reject-with", "tcp-reset"]
    allow_added = block_added = new_started = bundle_changed = False
    try:
        print("Preparing Backhaul on new foreign VPS without starting reverse connection...")
        prepared_backhaul_install(new, iran, candidate)
        # Ensure surviving Mieru still passes HTTPS before cutover.
        mieru_ip = dual.active_ips()["mieru"]
        if not dual.confirm_egress("mieru", mieru_ip, seconds=18):
            raise RuntimeError("Mieru survivor became unhealthy")
        add_rule(allow_new)
        allow_added = True
        # Existing Backhaul sessions may break; surviving Mieru stays serving.
        dual.run(["systemctl", "is-active", "dual-ha-v2-health"], timeout=10)
        dual.run(["systemctl", "is-active", "dual-ha-v2-gateway"], timeout=10)
        print("Switching Backhaul. Existing Backhaul TCP sessions may reconnect via Mieru.")
        add_rule(block_old)
        block_added = True
        new_started = True
        dual.ssh(new, "systemctl start dual-ha-backhaul-client", timeout=35)
        if not dual.confirm_egress("backhaul", new, seconds=60):
            raise RuntimeError("New Backhaul HTTPS egress or IP verification failed")
        dual.atomic_write(previous, candidate.read_bytes())
        bundle_changed = True
        run_guard(iran)
        dual.ssh(new, "systemctl enable dual-ha-backhaul-client", timeout=20)
        print("SUCCESS: Backhaul moved to " + new)
    except Exception:
        print("Backhaul switch failed: attempting rollback to previous host.")
        if new_started:
            try:
                dual.ssh(new, "systemctl disable --now dual-ha-backhaul-client", timeout=25)
            except Exception:
                # Prevent a surviving new client from competing with the old control channel.
                add_rule(["-s", new, "-d", iran, "-p", "tcp", "--dport", "18443",
                          "-j", "REJECT", "--reject-with", "tcp-reset"])
                print("WARNING: Could not stop candidate; its incoming connection is blocked.")
        if bundle_changed:
            dual.atomic_write(previous, backup)
        if old_guard_contents is not None:
            dual.atomic_write(OLD_GUARD, old_guard_contents)
            OLD_GUARD.chmod(0o700)
        if old_dynamic_contents is not None:
            dual.atomic_write(GUARD, old_dynamic_contents)
            GUARD.chmod(0o700)
        if block_added:
            del_rule(block_old)
        if GUARD.exists() and bundle_changed:
            sh([str(GUARD)], check=False)
        raise
    finally:
        if allow_added:
            del_rule(allow_new)
        if block_added and previous.read_bytes() != backup:
            del_rule(block_old)
        candidate.unlink(missing_ok=True)


def main():
    if os.geteuid() != 0:
        raise RuntimeError("Run with sudo/root on the Iran Dual HA host")
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("role", choices=["backhaul", "mieru"])
    p.add_argument("ip", nargs="?")
    a = p.parse_args()
    new = ipaddr(a.ip or input("New foreign VPS IP: ").strip())
    old = dual.safety_checks(a.role, new, check_ssh=False)
    iran = dual.iran_ip()
    if iran != ipaddr(iran):
        raise RuntimeError("Configured Iran IP must be a public IPv4; no changes made")
    print("Current %s: %s -> %s" % (a.role, old, new))
    print("Old host is NOT required for SSH. Existing connections on changed path may drop.")
    if input("Type REPLACE %s to proceed: " % a.role.upper()).strip() != "REPLACE " + a.role.upper():
        print("Cancelled. Nothing changed.")
        return 0
    authorize_new(new)
    folder = dual.workdir()
    try:
        if a.role == "backhaul":
            rotate_backhaul(old, new, iran, folder)
        else:
            print("Installing and validating new Mieru while Backhaul continues serving.")
            dual.replace_mieru(old, new, folder)
    except Exception:
        print("Check sudo dual health; only the surviving path may be active.")
        raise
    print("=== FINAL HEALTH ===")
    dual.print_status(deep=True)
    print("Old foreign VPS retained for manual rollback. Do not delete immediately.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, TimeoutError,
            subprocess.TimeoutExpired) as exc:
        print("AUTO ROTATE ERROR:", exc, file=sys.stderr)
        sys.exit(1)
