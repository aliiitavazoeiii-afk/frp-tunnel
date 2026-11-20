#!/usr/bin/env python3
"""Offline-only safe gateway persistence and live-status helper tests."""
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parent

def load(name,filename):
    spec=importlib.util.spec_from_file_location(name,ROOT/filename)
    obj=importlib.util.module_from_spec(spec)
    sys.modules[name]=obj
    spec.loader.exec_module(obj)
    return obj

g=load("maya1_emergency_persistence","maya1-emergency-persist-gateway.py")
h=load("maya1_recovery_helper","maya1-dual-helper.py")

class TestEmergency(unittest.TestCase):
    def test_minimum_persistent_change(self):
        original="""global
  stats socket /run/dual-ha-v2/haproxy.sock mode 600 level admin
frontend iran_xray_local_outbound
  bind 127.0.0.1:18080
backend dual_egress
  balance leastconn
  server backhaul 127.0.0.1:21101 check disabled
  server mieru 127.0.0.1:21102 check disabled
"""
        revised=g.offline_preview(original)
        self.assertEqual(revised,original.replace("check disabled","check"))
        self.assertNotIn(":21001",revised)
        self.assertNotIn(":21002",revised)
        self.assertEqual(revised.count("server backhaul"),1)
        self.assertEqual(revised.count("server mieru"),1)

    def test_refuse_old_ports_or_partial_config(self):
        for invalid in (
          "balance leastconn\nbind 127.0.0.1:18080\nserver backhaul 127.0.0.1:21001 check disabled\nserver mieru 127.0.0.1:21002 check disabled",
          "balance leastconn\nbind 127.0.0.1:18080\nserver backhaul 127.0.0.1:21101 check\nserver mieru 127.0.0.1:21102 check disabled",
          "balance leastconn\nbind 127.0.0.1:18080\nserver backhaul 127.0.0.1:21101 check disabled\nserver backhaul 127.0.0.1:21101 check disabled\nserver mieru 127.0.0.1:21102 check disabled"):
            with self.assertRaises(RuntimeError):
                g.offline_preview(invalid)

    def test_helper_live_up_beats_stale_bulk(self):
        row={"addr":"127.0.0.1:21101","status":"UP","weight":"1"}
        old={"available":False,"bulk_pass":False,"expected_foreign_ip":"82.152.132.159",
             "passed_probes":3}
        self.assertEqual(h.status_label(row,old,3,"82.152.132.159",21101,False),
                         ("UP","amber"))
        self.assertEqual(h.status_label(row,old,3,"82.152.132.159",21101,True),
                         ("UP","green"))
        self.assertEqual(h.status_label(dict(row,status="MAINT"),old,3,
                                        "82.152.132.159",21101,False),
                         ("DOWN","red"))
        self.assertEqual(h.status_label(dict(row,addr="127.0.0.1:21001"),old,3,
                                        "82.152.132.159",21101,False),
                         ("UNKNOWN","amber"))
        self.assertEqual(h.status_label(dict(row,weight="0"),old,3,
                                        "82.152.132.159",21101,False),
                         ("DISABLED","amber"))

    def test_emergency_never_mutates_live_services(self):
        code=(ROOT/"maya1-emergency-persist-gateway.py").read_text()
        for forbidden in ("systemctl restart","systemctl stop","systemctl reload",
                          "set server ","enable server","disable server",
                          "socket.SOCK_DGRAM","iptables -F","killall",
                          "docker compose"):
            self.assertNotIn(forbidden,code)
        self.assertIn('sk.sendall(b"show stat\\n")',code)
        self.assertIn('"/usr/sbin/haproxy","-c","-f"',code)

if __name__=="__main__":
    unittest.main(verbosity=2)
