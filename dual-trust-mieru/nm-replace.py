#!/usr/bin/env python3
"""Naive/Mieru FOREIGN swap via isolated preflight. Never restarts shared bridge/x-ui/dispatcher."""
import argparse
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

os.umask(0o077)
D = pathlib.Path("/etc/dual-trust-mieru/iran")
N = pathlib.Path("/etc/dual-trust-mieru/naive-mieru")
STATE = pathlib.Path("/var/lib/dual-trust-mieru/naive-mieru/replacements")
BIN = pathlib.Path("/usr/local/lib/dual-trust-mieru")

def run(*args, check=True, **kwargs):
    return subprocess.run(args, check=check, **kwargs)

def error(message):
    raise RuntimeError(message)

def active(svc):
    return run("systemctl", "is-active", "--quiet", svc + ".service", check=False).returncode == 0

def pid(svc):
    return run("systemctl", "show", "-p", "MainPID", "--value", svc + ".service",
               capture_output=True, text=True).stdout.strip()

def expect_active(svcs):
    for svc in svcs:
        if not active(svc):
            error("required service inactive: " + svc)

def save(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".new")
    tmp.write_text(content)
    tmp.chmod(0o600)
    os.replace(tmp, path)

def test(port, url="https://www.gstatic.com/generate_204", accepted=(204,)):
    p = run("curl", "-4", "-sS", "--socks5-hostname", "127.0.0.1:" + str(port),
            "--connect-timeout", "5", "--max-time", "12", "-o", "/dev/null",
            "-w", "%{http_code}", url, check=False, capture_output=True, text=True)
    return p.returncode == 0 and p.stdout.strip() in {str(x) for x in accepted}

def udp(port):
    # Reuse the verified existing role-based SOCKS UDP/XUDP diagnostic. Only supplied code from repo.
    import struct
    import random
    h = "127.0.0.1"
    with socket.create_connection((h, port), timeout=5) as s:
        s.settimeout(5)
        def read(n):
            out = b""
            while len(out) < n:
                part = s.recv(n-len(out))
                if not part: raise RuntimeError("SOCKS closed")
                out += part
            return out
        s.sendall(b"\x05\x01\x00")
        if read(2) != b"\x05\x00": error("SOCKS auth failed")
        s.sendall(b"\x05\x03\x00\x01" + b"\x00" * 6)
        _, code, _, atyp = read(4)
        if code: error("UDP associate error " + str(code))
        if atyp == 1: addr = socket.inet_ntoa(read(4))
        elif atyp == 3: addr = read(read(1)[0]).decode()
        elif atyp == 4: addr = socket.inet_ntop(socket.AF_INET6, read(16))
        else: error("bad SOCKS address")
        relayport = struct.unpack("!H", read(2))[0]
        if addr in ("0.0.0.0", "::"): addr = h
        qid = random.randrange(65536)
        query = struct.pack("!HHHHHH", qid, 0x100, 1, 0, 0, 0) + b"\x07youtube\x03com\x00" + struct.pack("!HH", 1, 1)
        msg = b"\0\0\0\1" + socket.inet_aton("1.1.1.1") + struct.pack("!H", 53) + query
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as u:
            u.settimeout(6)
            u.sendto(msg, (addr, relayport))
            resp, _ = u.recvfrom(4096)
            if len(resp) < 14: error("short UDP response")

class Swap:
    def __init__(self, role):
        self.role = role
        self.p = STATE / role
        self.csvc = "nm-replace-" + role + "-candidate"
        self.xsvc = "nm-replace-" + role + "-xudp"
        self.live = "nm-naive-client" if role == "naive" else "dual-mieru-carrier"
        self.other = "dual-mieru-carrier" if role == "naive" else "nm-naive-client"
        self.live_cfg = N/"naive-live.json" if role == "naive" else D/"mieru-carrier.yaml"
        self.live_bundle = N/"bundle.json" if role == "naive" else D/"mieru-bundle.json"
        self.mainport = 7993 if role == "naive" else 7994
        self.splitport = 7991 if role == "naive" else 7992
        self.cport = 17993 if role == "naive" else 17994
        self.xport = 17991 if role == "naive" else 17992
        self.otherport = 7992 if role == "naive" else 7991
        self.xudp_tag = "xudp-trust" if role == "naive" else "xudp-mieru"
        self.bfile = self.p/"new-bundle.json"
        self.marker = self.p/"prepared.json"
        self.new_cfg = self.p/("new-live.json" if role == "naive" else "new-live.yaml")
        self.candidate = self.p/("candidate.json" if role == "naive" else "candidate.yaml")
        self.other_protected = ("x-ui", "dual-dispatcher", "dual-xudp-bridge", self.other)

    def live_preflight(self):
        expect_active((*self.other_protected, self.live))
        if not (STATE.parent/"live-cutover.timestamp").is_file():
            error("Naive production cutover marker missing")

    def check_bundle(self, file):
        b = json.loads(pathlib.Path(file).read_text())
        old = json.loads(self.live_bundle.read_text())
        live = json.loads((D/"xudp.json").read_text())
        leg = [i for i in live["outbounds"] if i.get("tag") == self.xudp_tag]
        if len(leg) != 1: error("unexpected live XUDP layout")
        target = leg[0]["settings"]["address"]
        if target not in ("127.0.0.1", "xudp-trust.internal", "xudp-mieru.internal"):
            error("unexpected live XUDP backend address")
        if b.get("xudp_uuid") != leg[0]["settings"]["id"]:
            error("new foreign UUID differs from live shared XUDP bridge")
        if b.get("public_ip") == old.get("public_ip"): error("new foreign IP equals old")
        try:
            socket.inet_aton(b["public_ip"])
        except (KeyError, OSError, TypeError): error("new foreign IPv4 invalid")
        if self.role == "naive":
            if b.get("kind") != "lane3-naive" or b.get("port") != 443:
                error("invalid Naive bundle")
            if b.get("domain") == old.get("domain"):
                error("new Naive domain must differ from currently used domain")
            if b["public_ip"] not in socket.gethostbyname_ex(b["domain"])[2]:
                error("Naive new domain DNS does not match new IP")
            if not all(isinstance(b.get(k),str) and b[k] for k in ("domain","username","password")):
                error("missing Naive credentials")
        else:
            if b.get("kind") != "mieru" or not all(
                isinstance(b.get(k),str) and b[k] for k in ("port_range","username","password")):
                error("invalid Mieru bundle")
        return b, target

    def make_config(self, b, target):
        if self.role == "naive":
            common = {"proxy":f"https://{b['username']}:{b['password']}@{b['domain']}",
                      "host-resolver-rules":f"MAP {b['domain']} {b['public_ip']}"}
            save(self.candidate, json.dumps({"listen":f"socks://127.0.0.1:{self.cport}", **common},indent=2))
            save(self.new_cfg, json.dumps({"listen":f"socks://127.0.0.1:{self.mainport}", **common},indent=2))
        else:
            old = json.loads(self.live_bundle.read_text())
            text = self.live_cfg.read_text()
            tokens = [("    port: 7994", "    port: 17994"),
                      ('    server: "' + old["public_ip"] + '"', '    server: "' + b["public_ip"] + '"')]
            for before, after in tokens:
                if text.count(before) != 1: error("unexpected Mieru YAML field " + before)
                text = text.replace(before, after, 1)
            for src, field in (("port_range","port-range"),("username","username"),("password","password")):
                pattern = r"(?m)^    " + re.escape(field) + r": (.+)$"
                if len(re.findall(pattern, text)) != 1: error("unexpected Mieru " + field)
                text = re.sub(pattern, lambda _: "    " + field + ": " + json.dumps(b[src]), text, count=1)
            save(self.candidate, text)
            save(self.new_cfg, text.replace("    port: 17994", "    port: 7994", 1))
        x = {"log":{"loglevel":"warning"},
             "inbounds":[{"tag":"swap-in","listen":"127.0.0.1","port":self.xport,"protocol":"socks",
                          "settings":{"auth":"noauth","udp":True}}],
             "outbounds":[{"tag":"swap-xudp","protocol":"vless",
                           "settings":{"address":target,"port":2443,"id":b["xudp_uuid"],"encryption":"none"},
                           "streamSettings":{"network":"raw","sockopt":{"dialerProxy":"swap-carrier"}},
                           "mux":{"enabled":True,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
                          {"tag":"swap-carrier","protocol":"socks",
                           "settings":{"address":"127.0.0.1","port":self.cport}}],
             "routing":{"domainStrategy":"AsIs","rules":[
                  {"type":"field","inboundTag":["swap-in"],"network":"tcp","outboundTag":"swap-carrier"},
                  {"type":"field","inboundTag":["swap-in"],"network":"udp","outboundTag":"swap-xudp"}]}}
        save(self.p/"candidate-xudp.json", json.dumps(x,indent=2))
        run(str(BIN/"xray"),"run","-test","-c",str(self.p/"candidate-xudp.json"),stdout=subprocess.DEVNULL)
        if self.role == "mieru":
            self.p.joinpath("mihomo-data").mkdir(mode=0o700,exist_ok=True)
            run(str(BIN/"mihomo"),"-t","-d",str(self.p/"mihomo-data"),"-f",str(self.candidate),stdout=subprocess.DEVNULL)
            run(str(BIN/"mihomo"),"-t","-d",str(D/"mieru-data"),"-f",str(self.new_cfg),stdout=subprocess.DEVNULL)

    def units(self):
        if self.role == "naive":
            cmd = str(BIN/"naive") + " " + str(self.candidate)
        else:
            cmd = str(BIN/"mihomo") + " -d " + str(self.p/"mihomo-data") + " -f " + str(self.candidate)
        carrier = f"""[Unit]
Description=Naive/Mieru isolated {self.role} foreign candidate
After=network-online.target
[Service]
Type=simple
ExecStart={cmd}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
"""
        xray = f"""[Unit]
Description=Naive/Mieru isolated {self.role} XUDP validation
After={self.csvc}.service
Requires={self.csvc}.service
[Service]
Type=simple
ExecStart={BIN/'xray'} run -c {self.p/'candidate-xudp.json'}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
"""
        cpath = pathlib.Path("/etc/systemd/system")/(self.csvc+".service")
        xpath = pathlib.Path("/etc/systemd/system")/(self.xsvc+".service")
        save(cpath, carrier);save(xpath,xray)
        run("systemd-analyze","verify",str(cpath),str(xpath),stdout=subprocess.DEVNULL)
        run("systemctl","daemon-reload")
        run("systemctl","start",self.csvc+".service",self.xsvc+".service")
        time.sleep(3)
        expect_active((self.csvc,self.xsvc))

    def soak(self):
        if not test(self.cport): error("new carrier direct HTTP failed")
        if not test(self.xport): error("new foreign candidate split TCP failed")
        failures = 0
        for _ in range(20):
            if not test(self.xport,"https://api.telegram.org/",(200,301,302)):
                failures += 1
            time.sleep(0.3)
        print(f"[SWAP] {self.role} Telegram test: {20-failures}/20")
        if failures: error("new foreign is unstable. Existing production is unchanged")
        for _ in range(3): udp(self.xport)
        if not test(self.otherport): error("other live carrier has degraded")
        print("[SWAP] CANDIDATE PASS: HTTP, Telegram and XUDP; other carrier healthy")

    def prepare(self, bundle):
        self.live_preflight()
        if self.marker.exists():error("candidate already prepared; cutover or abort before new preparation")
        for port in (self.cport, self.xport):
            with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as s:
                if s.connect_ex(("127.0.0.1",port)) == 0:
                    error("candidate port already occupied: " + str(port))
        b,target=self.check_bundle(bundle)
        self.p.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.p.chmod(0o700)
        shutil.copyfile(bundle,self.bfile);self.bfile.chmod(0o600)
        self.make_config(b,target)
        self.units()
        self.soak()
        save(self.marker,json.dumps({"at":time.time(),"carrier_pid":pid(self.csvc),"xudp_pid":pid(self.xsvc)}))
        print("[SWAP] PREPARED. No production config or service was changed.")

    def abort(self):
        run("systemctl","stop",self.xsvc+".service",self.csvc+".service",check=False)
        self.marker.unlink(missing_ok=True)
        print("[SWAP] Stopped isolated replacement candidates; production untouched")

    def cutover(self, approval):
        self.live_preflight()
        if approval != "REPLACE-"+self.role.upper():error("required explicit approval: REPLACE-"+self.role.upper())
        if not self.marker.exists():error("candidate has not passed prepare")
        mark=json.loads(self.marker.read_text())
        if time.time()-mark["at"] > 3600:error("candidate approval expired (1h); redo stage")
        expect_active((self.csvc,self.xsvc))
        if mark["carrier_pid"] != pid(self.csvc) or mark["xudp_pid"] != pid(self.xsvc):
            error("candidate processes restarted since preparation")
        self.check_bundle(self.bfile)
        self.soak()
        # Hold old installed autoheal lock through role replacement.
        import fcntl
        with open("/run/dual-trust-mieru-autoheal.lock","a+") as lk:
            fcntl.flock(lk,fcntl.LOCK_EX)
            before={svc:pid(svc) for svc in self.other_protected}
            backup = STATE/"backups"/(self.role+"-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
            backup.mkdir(parents=True,exist_ok=False,mode=0o700)
            shutil.copy2(self.live_cfg,backup/self.live_cfg.name)
            shutil.copy2(self.live_bundle,backup/self.live_bundle.name)
            modified=False
            def interrupted(*_):
                raise RuntimeError("interrupted, rolling back changed role")
            previous_int=signal.signal(signal.SIGINT,interrupted)
            previous_term=signal.signal(signal.SIGTERM,interrupted)
            try:
                # Atomic replacement so a concurrent service restart cannot read
                # a partially copied credential/configuration file.
                stage_file=self.live_cfg.with_name("."+self.live_cfg.name+".nm-stage")
                shutil.copyfile(self.new_cfg,stage_file)
                stage_file.chmod(0o600)
                os.replace(stage_file,self.live_cfg)
                modified=True
                print("[SWAP] Restarting ONLY "+self.live+"; existing "+self.role+" sessions will reconnect.")
                run("systemctl","restart",self.live+".service")
                time.sleep(3)
                expect_active((self.live,))
                if not test(self.mainport) or not test(self.splitport): error("new live TCP health failed")
                for _ in range(3):
                    if not test(self.splitport,"https://api.telegram.org/",(200,301,302)):
                        error("new live Telegram health failed")
                for _ in range(2):udp(self.splitport)
                if not test(self.otherport):error("other carrier health failed")
                if any(pid(svc)!=before[svc] for svc in self.other_protected):
                    error("unexpected protected service PID change")
                shutil.copyfile(self.bfile,self.live_bundle);self.live_bundle.chmod(0o600)
                modified=False
            except BaseException:
                if modified:
                    print("[SWAP] ROLLBACK previous "+self.role+" config",file=sys.stderr)
                    stage_file=self.live_cfg.with_name("."+self.live_cfg.name+".nm-restore")
                    shutil.copyfile(backup/self.live_cfg.name,stage_file)
                    stage_file.chmod(0o600)
                    os.replace(stage_file,self.live_cfg)
                    shutil.copyfile(backup/self.live_bundle.name,self.live_bundle)
                    try:run("systemctl","restart",self.live+".service")
                    except Exception:print("[SWAP] CRITICAL: rollback restart failed!",file=sys.stderr)
                raise
            finally:
                signal.signal(signal.SIGINT,previous_int)
                signal.signal(signal.SIGTERM,previous_term)
        self.abort()
        print("[SWAP] SUCCESS: foreign swapped for "+self.role)
        print("[SWAP] No shared bridge / dispatcher / x-ui / other carrier restarts.")
        print("[SWAP] Old foreign retained; backup: "+str(backup))

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("action",choices=("status","prepare","cutover","abort"))
    ap.add_argument("role",choices=("naive","mieru"))
    ap.add_argument("bundle",nargs="?")
    ap.add_argument("--confirm",default="")
    a=ap.parse_args()
    if os.geteuid()!=0:error("run as root")
    sw=Swap(a.role)
    STATE.mkdir(parents=True,exist_ok=True,mode=0o700)
    if a.action=="status":
        print("Role:",a.role,"Prepared:",sw.marker.exists())
        print("candidate services:",active(sw.csvc),active(sw.xsvc))
    elif a.action=="prepare":
        if not a.bundle:error("new Foreign JSON bundle path is required")
        sw.prepare(a.bundle)
    elif a.action=="cutover":sw.cutover(a.confirm)
    elif a.action=="abort":sw.abort()

if __name__=="__main__":
    try:main()
    except Exception as exc:
        print("[SWAP] ERROR:",exc,file=sys.stderr)
        sys.exit(1)
