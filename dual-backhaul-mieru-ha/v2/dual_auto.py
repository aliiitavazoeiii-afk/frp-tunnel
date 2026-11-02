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
        _, stdout, stderr = client.exec_command(cmd, timeout=20)
        if stdout.channel.recv_exit_status():
            raise RuntimeError("SSH key authorization failed: " + stderr.read().decode()[-250:])
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
        dual.prepped_remote_install("backhaul", new, candidate)
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
