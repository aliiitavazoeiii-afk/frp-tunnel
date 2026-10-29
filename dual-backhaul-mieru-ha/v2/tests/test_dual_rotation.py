"""Simulated cutover/rollback tests; NO network, root, UFW, SSH, or systemctl writes."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dual_rotation_helper", ROOT / "dual.py")
dual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dual)


class ReplacementTransactions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.etc = self.path / "etc"
        self.w = self.path / "backups"
        self.etc.mkdir()
        self.w.mkdir()
        (self.etc / "backhaul-bundle.env").write_text(
            "BH_IRAN_IP='94.184.4.38'\n"
            "BH_FOREIGN_IP='152.237.230.159'\n"
            "BH_TOKEN='" + "a"*64 + "'\n")
        (self.etc / "mieru.json").write_text(json.dumps({
            "profiles": [{
                "profileName": "dualha",
                "user": {"name": "dualha", "password": "b"*64},
                "servers": [{
                    "ipAddress": "152.237.230.248",
                    "portBindings": [{"port": 28443, "protocol": "TCP"}],
                }],
            }]
        }))

    def test_backhaul_failed_https_restores_old_service_and_bundle(self):
        commands = []
        def fake_ssh(ip, command, **kw):
            commands.append((ip, command))
            return ""
        with patch.object(dual, "ETC", self.etc), \
             patch.object(dual, "prepped_remote_install"), \
             patch.object(dual, "ufw_allow_new", return_value=False), \
             patch.object(dual, "ufw_rollback"), \
             patch.object(dual, "outbound_probe", return_value={"ok": True, "ip": "152.237.230.248"}), \
             patch.object(dual, "ssh", side_effect=fake_ssh), \
             patch.object(dual, "confirm_egress", side_effect=lambda role, ip, **k: ip == "152.237.230.159"), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "could not prove"):
                dual.replace_backhaul("152.237.230.159", "8.8.8.8", self.w)
        self.assertIn(("152.237.230.159", "systemctl stop dual-ha-backhaul-client"), commands)
        self.assertIn(("8.8.8.8", "systemctl start dual-ha-backhaul-client"), commands)
        self.assertIn(("8.8.8.8", "systemctl disable --now dual-ha-backhaul-client"), commands)
        self.assertIn(("152.237.230.159", "systemctl enable --now dual-ha-backhaul-client"), commands)
        self.assertIn("BH_FOREIGN_IP='152.237.230.159'",
                      (self.etc / "backhaul-bundle.env").read_text())
        self.assertFalse((self.w / "backhaul.candidate-bundle.env").exists())

    def test_backhaul_success_commits_new_ip_and_stops_old(self):
        commands = []
        def fake_ssh(ip, command, **kw):
            commands.append((ip, command))
            return ""
        with patch.object(dual, "ETC", self.etc), \
             patch.object(dual, "prepped_remote_install"), \
             patch.object(dual, "ufw_allow_new", return_value=False), \
             patch.object(dual, "outbound_probe", return_value={"ok": True, "ip": "152.237.230.248"}), \
             patch.object(dual, "ssh", side_effect=fake_ssh), \
             patch.object(dual, "confirm_egress", return_value=True), \
             contextlib.redirect_stdout(io.StringIO()):
            dual.replace_backhaul("152.237.230.159", "8.8.8.8", self.w)
        self.assertIn("BH_FOREIGN_IP='8.8.8.8'",
                      (self.etc / "backhaul-bundle.env").read_text())
        self.assertIn(("8.8.8.8", "systemctl enable dual-ha-backhaul-client"), commands)
        self.assertIn(("152.237.230.159", "systemctl disable dual-ha-backhaul-client"), commands)

    def test_mieru_failed_https_restores_old_credentials_ip_and_service(self):
        old = (self.etc / "mieru.json").read_bytes()
        calls = []
        def fake_scp(src, dst, **kw):
            Path(dst).write_text("MIERU_REMOTE_IP='8.8.8.8'\nMIERU_TCP_PORT='28443'\n"
                                 "MIERU_USER='dualha'\nMIERU_PASSWORD='" + "c"*64 + "'\n")
        def fake_run(cmd, **kw):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")
        with patch.object(dual, "ETC", self.etc), \
             patch.object(dual, "prepped_remote_install"), \
             patch.object(dual, "scp", side_effect=fake_scp), \
             patch.object(dual, "tcp_probe", return_value=True), \
             patch.object(dual, "outbound_probe", return_value={"ok": True, "ip": "152.237.230.159"}), \
             patch.object(dual, "run", side_effect=fake_run), \
             patch.object(dual, "confirm_egress", side_effect=lambda role, ip, **kw: ip == "152.237.230.248"), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "did not confirm"):
                dual.replace_mieru("152.237.230.248", "8.8.8.8", self.w)
        restored = json.loads((self.etc / "mieru.json").read_bytes())
        original = json.loads(old)
        self.assertEqual(restored, original)
        self.assertEqual(calls.count(["systemctl", "restart", "dual-ha-mieru"]), 2)
        self.assertFalse((self.w / "mieru.candidate-bundle.env").exists())

    def test_ufw_preserves_existing_candidate_specific_rule(self):
        def fake_run(cmd, **kw):
            return subprocess.CompletedProcess(
                cmd, 0, b"Status: active\n18443/tcp ALLOW 8.8.8.8\n", b"")
        with patch.object(dual.shutil, "which", return_value="/usr/sbin/ufw"), \
             patch.object(dual, "run", side_effect=fake_run), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(dual.ufw_allow_new("8.8.8.8"))


if __name__ == "__main__":
    unittest.main()
