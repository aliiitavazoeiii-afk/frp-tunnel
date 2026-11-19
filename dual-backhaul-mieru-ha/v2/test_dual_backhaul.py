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

    def test_shared_download_probe_failure_does_not_drain_both_paths(self):
        result = {
            "backhaul": (3, True, 0.4, (False, {"reason":"timeout"})),
            "mieru": (3, True, 0.5, (False, {"reason":"timeout"})),
        }
        streak = {"backhaul": {"bulk_bad":1}, "mieru": {"bulk_bad":1}}
        self.assertTrue(controller.common_bulk_probe_outage(result, streak))
        result["mieru"] = (3, True, 0.5, (True, {"reason":"ok"}))
        self.assertFalse(controller.common_bulk_probe_outage(result, streak))
        result["mieru"] = (1, False, None, (False, {"reason":"timeout"}))
        self.assertFalse(controller.common_bulk_probe_outage(result, streak))

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

    def test_prepare_builds_independent_stage_and_preserves_live_files(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            live = d / "live"
            live.mkdir()
            work = d / "work"
            work.mkdir()
            oldtoken = "a" * 64
            ctrl = "/assets/" + "b" * 32
            tunnel = "/socket/" + "c" * 32
            oldbundle = (
                "BH_DOMAIN='bh3-new.biya2film.top'\\n"
                "BH_IRAN_IP='185.215.230.221'\\n"
                "BH_TOKEN='" + oldtoken + "'\\n"
                "BH_CONTROL_PATH='" + ctrl + "'\\n"
                "BH_TUNNEL_PATH='" + tunnel + "'\\n"
                "BH_FOREIGN_IP='82.152.132.112'\\n"
                "BH_TLS_PORT='18443'\\n"
            )
            oldcfg = (
                '[server]\\nbind_addr = "127.0.0.1:19085"\\n'
                'token = "' + oldtoken + '"\\n'
                'ws_control_path = "' + ctrl + '"\\n'
                'ws_tunnel_path = "' + tunnel + '"\\n'
                'ports = [ "127.0.0.1:21002=127.0.0.1:11080" ]\\n'
            )
            oldrouter = (
                "frontend ingress\\n  bind 127.0.0.1:19086\\n"
                "  acl control_path path -i " + ctrl + "\\n"
                "  acl tunnel_path path_beg " + tunnel + "/\\n"
                "backend wsmux\\n  server backhaul2 127.0.0.1:19085\\n"
            )
            oldtls = ("accept = 0.0.0.0:18445\\n"
                      "connect = 127.0.0.1:19086\\n")
            inputs = {
                "BUNDLE": (live / "foreign-bundle.env", oldbundle),
                "BH": (live / "iran.toml", oldcfg),
                "ROUTER": (live / "router.cfg", oldrouter),
                "TLS": (live / "tls.conf", oldtls),
                "META": (live / "state.json", '{"mode":"active"}\\n')
            }
            for _, (file, text) in inputs.items():
                file.write_text(text.replace("\\n", "\n"))
            patches = [patch.object(rotator, key, path) for key,(path,_) in inputs.items()]
            for item in patches: item.start()
            try:
                with patch.object(rotator, "command", return_value=SimpleNamespace(returncode=0,stdout="",stderr="")):
                    rotator.prepare_local("82.152.132.112","89.89.89.89",work)
                self.assertEqual((live / "iran.toml").read_text(), oldcfg.replace("\\n", "\n"))
                self.assertIn("127.0.0.1:21103=127.0.0.1:11080",(work / "stage.toml").read_text())
                self.assertIn("127.0.0.1:19089",(work / "stage.toml").read_text())
                self.assertIn("bind 127.0.0.1:19088",(work / "stage-router.cfg").read_text())
                self.assertIn("accept = 0.0.0.0:18446",(work / "stage-tls.conf").read_text())
                self.assertIn("connect = 127.0.0.1:19088",(work / "stage-tls.conf").read_text())
                self.assertIn("BH_FOREIGN_IP='89.89.89.89'",(work / "candidate.env").read_text())
                self.assertNotIn(oldtoken, (work / "candidate.env").read_text())
                self.assertIn(oldtoken, (work / "iran.toml.prior").read_text())
            finally:
                for item in reversed(patches): item.stop()

    def test_wrapper_uses_existing_v3_for_first_backhaul(self):
        source = (ROOT / "dual_backhaul_menu.py").read_text()
        self.assertIn('rotate_primary("backhaul", new_ip)', source)
        self.assertIn('bh2().replace(new_ip)', source)

if __name__ == "__main__":
    unittest.main()
