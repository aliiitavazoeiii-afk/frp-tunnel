#!/usr/bin/env python3
"""Offline Maya1 Backhaul1-only DRAIN and persistent boot behavior tests."""
import importlib.util
import pathlib
import sys
import unittest
from unittest.mock import patch

SOURCE=pathlib.Path(__file__).with_name("maya1-backhaul1-only-safe.py")
spec=importlib.util.spec_from_file_location("maya1_single_lane",SOURCE)
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
  server backhaul 127.0.0.1:21101 check
  server mieru 127.0.0.1:21102 check
"""

class SafeMaya1(unittest.TestCase):
    def test_exact_migrated_maya1_identification(self):
        src=SOURCE.read_text()
        self.assertIn('IP="94.184.4.38"',src)
        self.assertIn('BH1_IP="82.152.132.159"',src)
        self.assertIn('BH2_IP="152.237.230.77"',src)
        self.assertEqual(m.LANE_META,{"backhaul":("bh1",21101,"82.152.132.159"),
                                      "mieru":("bh2",21102,"152.237.230.77")})
        self.assertEqual(m.CUTOVER,m.STAGE/"cutover-state.json")
        self.assertIn("MAYA1_NEXT_V1",src)
        self.assertIn("phase",src)
        self.assertIn("two-backhaul-3site-10m-v3",src)
        self.assertIn('health["paths"]["backhaul"].get("expected_foreign_ip")==BH1_IP',src)
        self.assertIn('state.get("staging_socks")==port',src)

    def test_one_active_route_in_persistent_configuration(self):
        patched=m.new_config(BASE)
        self.assertIn("server backhaul 127.0.0.1:21101 check\n",patched)
        self.assertIn("server mieru 127.0.0.1:21102 check disabled\n",patched)
        self.assertEqual(patched.count("server backhaul"),1)
        self.assertEqual(patched.count("server mieru"),1)
        self.assertEqual(m.new_config(patched),patched)
        self.assertIn("bind 127.0.0.1:18080",patched)

    def test_fails_closed_for_old_or_unexpected_ports(self):
        for changed in [
            BASE.replace("127.0.0.1:21101","127.0.0.1:21001"),
            BASE.replace("127.0.0.1:21102","127.0.0.1:21002"),
            BASE.replace("balance leastconn","balance roundrobin"),
            BASE.replace("server mieru 127.0.0.1:21102 check",
                         "server mieru 127.0.0.1:21102 check weight 10"),
            BASE.replace("  server backhaul 127.0.0.1:21101 check",""),
            BASE.replace("bind 127.0.0.1:18080","bind 0.0.0.0:18080"),
        ]:
            with self.subTest(candidate=changed[-100:]):
                with self.assertRaises(RuntimeError):
                    m.new_config(changed)

    def test_no_xray_or_tunnel_restart(self):
        s=SOURCE.read_text()
        self.assertIn('haproxy("set server dual_egress/mieru state drain")',s)
        self.assertIn('system("disable","--now",CONTROLLER)',s)
        self.assertIn('haproxy("set server dual_egress/mieru state ready")',s)
        self.assertIn('MAYA1_BACKHAUL_ONLY_PREFLIGHT_PASS',s)
        self.assertIn('MAYA1_BACKHAUL_ONLY_LIVE',s)
        self.assertIn('gateway_egress==expected_egress',s)
        for forbidden in (
           'systemctl restart','systemctl reload','systemctl stop maya1-next',
           'systemctl stop x-ui','systemctl stop dual-ha-v2-gateway',
           'set server dual_egress/backhaul state drain',
           'set server dual_egress/backhaul state maint',
           'docker compose','killall','ss -K'):
           self.assertNotIn(forbidden,s)

if __name__=="__main__":
    unittest.main(verbosity=2)
