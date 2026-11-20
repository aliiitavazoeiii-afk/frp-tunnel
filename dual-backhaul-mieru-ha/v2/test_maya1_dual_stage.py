#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch
FILE=Path(__file__).with_name("maya1-stage-dual-backhaul.py")
spec=importlib.util.spec_from_file_location("maya1_stage",FILE)
m=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=m
spec.loader.exec_module(m)
class TestStage(unittest.TestCase):
    def test_specified_host_identity_and_stage_ports(self):
        self.assertEqual(m.IRAN,"94.184.4.38")
        self.assertEqual(m.DOMAIN,"bh-new.biya2film.top")
        self.assertEqual(m.TARGETS["bh1"],("82.152.132.159",18447,19090,19091,21101))
        self.assertEqual(m.TARGETS["bh2"],("152.237.230.77",18448,19092,19093,21102))
        busy={18443,21001,21002,18080,443}
        self.assertFalse(busy.intersection(p for r in m.TARGETS.values() for p in r[1:]))
    def test_listener_bind_gate_rejects_real_conflict(self):
        import socket
        with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1",0))
            port=listener.getsockname()[1]
            with patch.object(m,"TARGETS",{"bh1":("8.8.8.8",port,0,0,0)}):
                self.assertEqual(m.stage_bind_conflicts(),{port})
        with patch.object(m,"TARGETS",{"bh1":("8.8.8.8",port,0,0,0)}):
            self.assertEqual(m.stage_bind_conflicts(),set())

    def test_stage_secrets_independent_and_no_production_override(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            with patch.object(m,"BASE",p),patch.object(m,"cmd",return_value=None),patch.object(m,"atomic",wraps=m.atomic):
                # Avoid writing to real systemd by mocking Path class only for
                # targeted output path: replace the two Path('/etc/...') inputs.
                old_path=m.Path
                def safe_path(arg):
                    arg=str(arg)
                    if arg=="/etc/systemd/system":
                        return p/"units"
                    return old_path(arg)
                (p/"units").mkdir()
                with patch.object(m,"Path",side_effect=safe_path):
                    m.make_configs("bh1",p/"cert.pem",p/"privkey.pem")
                    m.make_configs("bh2",p/"cert.pem",p/"privkey.pem")
            first=(p/"bh1"/"foreign-bundle.env").read_text()
            second=(p/"bh2"/"foreign-bundle.env").read_text()
            self.assertIn("BH_TLS_PORT='18447'",first)
            self.assertIn("BH_TLS_PORT='18448'",second)
            token=lambda x:re.search(r"(?m)^BH_TOKEN='([a-f0-9]{64})'$",x).group(1)
            self.assertNotEqual(token(first),token(second))
            self.assertNotEqual(re.search(r"BH_CONTROL_PATH='([^']+)'",first).group(1),
                                re.search(r"BH_CONTROL_PATH='([^']+)'",second).group(1))
            for role,port in (("bh1",21101),("bh2",21102)):
                data=(p/role/"iran.toml").read_text()
                self.assertIn(f"127.0.0.1:{port}=127.0.0.1:11080",data)
                self.assertIn("mux_con = 16",data)
                self.assertIn("heartbeat = 40",data)
                self.assertEqual(os.stat(p/role/"foreign-bundle.env").st_mode&0o777,0o600)
            source=FILE.read_text()
            for forbidden in ("systemctl restart dual-ha", "systemctl stop dual-ha",
                              "iptables -F", "docker compose","ExecStart=/usr/bin/xray"):
                self.assertNotIn(forbidden,source)
if __name__=="__main__":
    unittest.main(verbosity=2)
