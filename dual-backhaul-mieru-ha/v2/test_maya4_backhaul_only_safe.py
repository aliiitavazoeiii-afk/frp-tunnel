#!/usr/bin/env python3
"""Offline Maya4 single-backhaul maintenance and persistence regressions."""
import importlib.util
from pathlib import Path
import sys
import unittest

P=Path(__file__).with_name("maya4-backhaul-only-safe.py")
spec=importlib.util.spec_from_file_location("maya4_backhaul_only",P)
m=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=m
spec.loader.exec_module(m)

BASE="""global
  log stdout format raw local0
  stats socket /run/dual-ha-v2/haproxy.sock mode 600 level admin
defaults
  mode tcp
frontend iran_xray_local_outbound
  bind 127.0.0.1:18080
  default_backend dual_egress
backend dual_egress
  balance leastconn
  option tcp-check
  server backhaul 127.0.0.1:21001 check disabled
  server mieru 127.0.0.1:21002 check
"""

class Maya4Tests(unittest.TestCase):
    def test_persistent_backhaul_only(self):
        res=m.new_config(BASE)
        self.assertIn("server backhaul 127.0.0.1:21001 check\n",res)
        self.assertIn("server mieru 127.0.0.1:21002 check disabled\n",res)
        self.assertNotIn("server backhaul 127.0.0.1:21001 check disabled",res)
        self.assertEqual(m.new_config(res),res)
        self.assertEqual(res.count("server backhaul"),1)
        self.assertEqual(res.count("server mieru"),1)
        self.assertEqual(res.count("bind 127.0.0.1:18080"),1)

    def test_reject_non_maya4_topology_or_multiple_backend_entries(self):
        mutations=[
            BASE.replace(":21001",":21101"),
            BASE.replace(":21002",":21102"),
            BASE.replace("server mieru 127.0.0.1:21002 check",
                         "server mieru 127.0.0.1:21002 weight 2 check"),
            BASE.replace("server mieru 127.0.0.1:21002 check",""),
            BASE+BASE.split("  server mieru ")[1].join(("  server mieru ","")),
            BASE.replace("bind 127.0.0.1:18080","bind 0.0.0.0:18080"),
        ]
        for c in mutations:
            if c == BASE:
                continue
            with self.subTest(candidate=c[-90:]):
                with self.assertRaises(RuntimeError):
                    m.new_config(c)

    def test_never_shutdown_a_tunnel_or_xray(self):
        source=P.read_text()
        self.assertIn('haproxy("set server dual_egress/mieru state drain")',source)
        self.assertIn('system("disable","--now",CONTROLLER)',source)
        for forbidden in (
            "systemctl restart","systemctl reload","systemctl stop dual-ha-mieru",
            "systemctl stop x-ui","systemctl stop dual-ha-backhaul",
            "docker compose","iptables -F","set server dual_egress/backhaul state drain",
            "set server dual_egress/backhaul state maint",
            "killall","ss -K"):
            self.assertNotIn(forbidden,source)
        self.assertIn('MAYA4_BACKHAUL_ONLY_PREFLIGHT_PASS',source)
        self.assertIn('NO_CHANGES_MADE=TRUE',source)

if __name__=="__main__":
    unittest.main(verbosity=2)
