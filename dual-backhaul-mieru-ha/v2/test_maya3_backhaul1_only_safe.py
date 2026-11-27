#!/usr/bin/env python3
"""Offline Maya3 Backhaul1-only DRAIN and persistent boot behavior tests."""
import importlib.util
import pathlib
import sys
import unittest
from unittest.mock import patch

SOURCE=pathlib.Path(__file__).with_name("maya3-backhaul1-only-safe.py")
spec=importlib.util.spec_from_file_location("maya3_single_lane",SOURCE)
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m
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

class SafeMaya3(unittest.TestCase):
    def test_explicit_maya3_identification(self):
        src=SOURCE.read_text()
        self.assertIn('IP="185.215.230.221"',src)
        self.assertIn('BH1_IP="152.237.230.140"',src)
        self.assertIn('BH2_IP="82.152.132.112"',src)
        self.assertIn("two-backhaul-3site-10m-v3",src)
        self.assertIn("BH_IRAN_IP='185",src)
        self.assertIn("BH_FOREIGN_IP='152",src)
        self.assertIn("state.get(\"primary_ip\")==BH1_IP",src)
        self.assertIn("state.get(\"foreign_ip\")==BH2_IP",src)
        self.assertIn('health["paths"]["backhaul"].get("passed_probes",0)>=2',src)

    def test_persistent_maya3_config_only_1_backend(self):
        patched=m.new_config(BASE)
        self.assertIn("server backhaul 127.0.0.1:21001 check\n",patched)
        self.assertIn("server mieru 127.0.0.1:21002 check disabled\n",patched)
        self.assertEqual(patched.count("server backhaul"),1)
        self.assertEqual(patched.count("server mieru"),1)
        self.assertEqual(m.new_config(patched),patched)
        self.assertIn("bind 127.0.0.1:18080",patched)

    def test_reject_unexpected_current_haproxy_config(self):
        for edit in [
            BASE.replace("127.0.0.1:21001","127.0.0.1:21101"),
            BASE.replace("127.0.0.1:21002","127.0.0.1:21102"),
            BASE.replace("balance leastconn","balance roundrobin"),
            BASE.replace("server mieru 127.0.0.1:21002 check",
                         "server mieru 127.0.0.1:21002 check weight 10"),
            BASE.replace("  server backhaul 127.0.0.1:21001 check disabled",""),
            BASE.replace("bind 127.0.0.1:18080","bind 0.0.0.0:18080"),
        ]:
            with self.subTest(edit=edit[-100:]):
                with self.assertRaises(RuntimeError):
                    m.new_config(edit)

    def test_action_scope_and_reversible_policy(self):
        src=SOURCE.read_text()
        self.assertIn('haproxy("set server dual_egress/mieru state drain")',src)
        self.assertIn('system("disable","--now",CONTROLLER)',src)
        self.assertIn('haproxy("set server dual_egress/mieru state ready")',src)
        self.assertIn('MAYA3_BACKHAUL_ONLY_PREFLIGHT_PASS',src)
        self.assertIn('MAYA3_BACKHAUL_ONLY_LIVE',src)
        self.assertIn('NEW_CONNECTIONS_VIA_BACKHAUL_ONLY=TRUE',src)
        self.assertIn('BACKUP_ROOT=',src)
        self.assertIn('gateway_egress==expected_egress',src)
        for forbidden in ("systemctl restart","systemctl reload",
                          "systemctl stop dual-ha-bh2","systemctl stop x-ui",
                          "systemctl stop dual-ha-backhaul","docker compose",
                          "set server dual_egress/backhaul state drain",
                          "set server dual_egress/backhaul state maint",
                          "killall","ss -K"):
            self.assertNotIn(forbidden,src)

if __name__=="__main__":
    unittest.main(verbosity=2)
