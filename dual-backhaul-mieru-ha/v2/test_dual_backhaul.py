#!/usr/bin/env python3
"""Offline regression tests for independent Maya3 Dual Backhaul infrastructure."""
from importlib.util import spec_from_file_location, module_from_spec
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent

def load(name, filename):
    spec = spec_from_file_location(name, ROOT / filename)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

controller = load("bh_controller", "dual-backhaul-controller.py")
rotator = load("bh_rotate", "dual-backhaul2-rotate.py")
menu = load("bh_menu", "dual_backhaul_menu.py")

class ControllerChecks(unittest.TestCase):
    def test_fail_closed_on_two_https_failures(self):
        self.assertEqual(controller.decision(True, False, 2, 0, 0, True), "disable")

    def test_fail_closed_on_two_bulk_failures_despite_good_https(self):
        self.assertEqual(controller.decision(True, True, 0, 2, 0, True), "disable")

    def test_do_not_disable_on_single_bulk_failure(self):
        self.assertIsNone(controller.decision(True, True, 0, 1, 0, True))

    def test_no_premature_reenable_without_bulk_verification(self):
        self.assertIsNone(controller.decision(False, True, 0, 0, 10, False))
        self.assertIsNone(controller.decision(False, True, 0, 0, 2, True))
        self.assertEqual(controller.decision(False, True, 0, 0, 3, True), "enable")

    def test_validate_complete_bulk_transfer(self):
        good = SimpleNamespace(returncode=0, stdout="200 262144 1000000 0.5")
        with patch.object(controller, "curl", return_value=good):
            ok, details = controller.bulk_probe(21002)
        self.assertTrue(ok)
        self.assertEqual(details["bytes"], 262144)

        short = SimpleNamespace(returncode=0, stdout="200 28000 1000000 0.5")
        with patch.object(controller, "curl", return_value=short):
            ok, details = controller.bulk_probe(21002)
        self.assertFalse(ok)
        self.assertEqual(details["reason"], "slow_or_short_download")

        slow = SimpleNamespace(returncode=0, stdout="200 262144 1000 17.5")
        with patch.object(controller, "curl", return_value=slow):
            ok, _ = controller.bulk_probe(21002)
        self.assertFalse(ok)

    def test_roles_preserve_legacy_haproxy_identifier(self):
        self.assertEqual(controller.PATHS, {"backhaul": 21001, "mieru": 21002})
        self.assertEqual(menu.BACKEND["backhaul2"], "mieru")

class RotationChecks(unittest.TestCase):
    def test_parse_private_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/"candidate.env"
            p.write_text("BH_FOREIGN_IP='82.152.132.112'\nBH_TOKEN='deadbeef'\n")
            with patch.object(rotator, "BUNDLE", p):
                self.assertEqual(rotator.bundle()["BH_FOREIGN_IP"], "82.152.132.112")

    def test_unique_and_separate_staging_ports(self):
        self.assertNotEqual(rotator.STAGE_SOCKS, 21002)
        self.assertNotEqual(rotator.STAGE_TLS_PORT, 18445)
        self.assertNotEqual(rotator.STAGE_ROUTER, 19085)
        self.assertEqual(rotator.IRAN, "185.215.230.221")

    def test_no_production_haproxy_config_overwrite(self):
        source = (ROOT / "dual-backhaul2-rotate.py").read_text()
        for forbidden in ("/etc/dual-ha/v2/haproxy.cfg", "/etc/haproxy/haproxy.cfg",
                          "systemctl\", \"restart\", \"x-ui",
                          "systemctl\", \"restart\", \"dual-ha-backhaul"):
            self.assertNotIn(forbidden, source)

    def test_wrapper_uses_existing_v3_for_first_backhaul(self):
        source = (ROOT / "dual_backhaul_menu.py").read_text()
        self.assertIn('rotate_primary("backhaul", new_ip)', source)
        self.assertIn('bh2().replace(new_ip)', source)

if __name__ == "__main__":
    unittest.main()
