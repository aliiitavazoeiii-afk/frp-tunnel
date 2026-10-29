"""Pure local tests for Dual HA console safety gates; never access live VPSs."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dual_helper", ROOT / "dual.py")
dual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dual)


class DualHelperTests(unittest.TestCase):
    def test_only_public_ipv4_candidates(self):
        self.assertEqual(dual.ensure_ip("152.237.230.248"), "152.237.230.248")
        for bad in ("127.0.0.1", "192.168.1.1", "10.0.0.1", "1.2.3.4;reboot",
                    "::1", "999.8.8.8", "0.0.0.0"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                dual.ensure_ip(bad)

    def test_real_bundle_and_mieru_remote_ip_parsing(self):
        with tempfile.TemporaryDirectory() as td:
            etc = Path(td)
            (etc / "backhaul-bundle.env").write_text(
                "BH_IRAN_IP='94.184.4.38'\nBH_FOREIGN_IP='152.237.230.159'\n"
                "BH_TOKEN='" + "f"*64 + "'\n"
            )
            (etc / "mieru.json").write_text(json.dumps({
                "profiles": [{"servers": [{"ipAddress": "152.237.230.248"}]}]}))
            with patch.object(dual, "ETC", etc):
                self.assertEqual(dual.active_ips(),
                                 {"backhaul": "152.237.230.159", "mieru": "152.237.230.248"})
                self.assertEqual(dual.iran_ip(), "94.184.4.38")
                w = etc / "backups"
                w.mkdir()
                candidate = dual.backhaul_candidate_bundle("152.237.230.159",
                                                           "8.8.8.8", w)
                self.assertIn("BH_FOREIGN_IP='8.8.8.8'", candidate.read_text())
                self.assertIn("BH_FOREIGN_IP='152.237.230.159'",
                              (etc / "backhaul-bundle.env").read_text())
                self.assertEqual(stat.S_IMODE(candidate.stat().st_mode), 0o600)

    def test_candidate_mieru_secrets_no_print(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bundle"
            p.write_text("MIERU_REMOTE_IP='8.8.8.8'\nMIERU_TCP_PORT='28443'\n"
                         "MIERU_USER='dualha'\nMIERU_PASSWORD='" + "a"*64 + "'\n")
            with contextlib.redirect_stdout(io.StringIO()) as output:
                user, secret = dual.candidate_mieru_bundle(p, "8.8.8.8")
            self.assertEqual(user, "dualha")
            self.assertEqual(len(secret), 64)
            self.assertEqual(output.getvalue(), "")
            with self.assertRaises(RuntimeError):
                dual.candidate_mieru_bundle(p, "1.1.1.1")

    def test_atomic_write_preserves_permissions(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "config.json"
            p.write_text("old")
            dual.atomic_write(p, b"new")
            self.assertEqual(p.read_bytes(), b"new")
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)

    def test_safety_checks_require_secondary_healthy_path(self):
        with tempfile.TemporaryDirectory() as td:
            etc = Path(td)
            (etc / "mieru.json").write_text(json.dumps({
                "profiles": [{"servers": [{"ipAddress": "152.237.230.248"}]}]}))
            (etc / "backhaul-bundle.env").write_text(
                "BH_FOREIGN_IP='152.237.230.159'\nBH_IRAN_IP='94.184.4.38'\n")
            with patch.object(dual, "ETC", etc), patch.object(dual, "FOREIGN_INSTALL",
                ROOT / "foreign-install.sh"), patch.object(dual, "health_cache",
                return_value=({"backhaul": {"available": False},
                               "mieru": {"available": False}}, 1)), patch.object(dual.os,
                "geteuid", return_value=0):
                with self.assertRaisesRegex(RuntimeError, "Other HA path"):
                    dual.safety_checks("backhaul", "8.8.8.8", check_ssh=False)

    def test_ssh_requires_pretrusted_server_identity(self):
        self.assertIn("StrictHostKeyChecking=yes", dual.SSH_OPTS)
        self.assertIn("BatchMode=yes", dual.SSH_OPTS)

    def test_installers_do_not_restart_xray(self):
        for filename in ("install-dual-helper.sh", "foreign-install.sh"):
            s = (ROOT / filename).read_text()
            self.assertNotIn("systemctl restart x-ui", s)
            self.assertNotIn("systemctl restart xray", s)

    def test_cli_subcommands(self):
        self.assertEqual(dual.main.__name__, "main")
        self.assertEqual(dual.PORTS["backhaul"], 21001)
        self.assertEqual(dual.PORTS["mieru"], 21002)
        self.assertEqual(dual.PORTS["gateway"], 18080)


if __name__ == "__main__":
    unittest.main()
