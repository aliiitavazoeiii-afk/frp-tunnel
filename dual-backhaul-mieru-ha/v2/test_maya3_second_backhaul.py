#!/usr/bin/env python3
"""Offline safety checks: Maya3 Backhaul2 experiment never alters the gateway."""
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("bh2", HERE/"maya3-second-backhaul-experiment.py")
bh2=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bh2)

class TestMaya3Backhaul2(unittest.TestCase):
    def test_ipv4_guards(self):
        self.assertEqual(bh2.ssh_safe_ipv4("8.8.8.8"), "8.8.8.8")
        for ip in ("127.0.0.1", "10.0.0.1", "bad", "::1"):
            with self.assertRaises(RuntimeError):
                bh2.ssh_safe_ipv4(ip)

    def test_same_config_can_stage_switch_restore(self):
        with tempfile.TemporaryDirectory() as d:
            testfile=Path(d)/"backhaul.toml"
            testfile.write_text('token="x"\nports=["127.0.0.1:21102=127.0.0.1:11080"]\n')
            with patch.object(bh2, "BH", testfile):
                bh2.configure(bh2.PORT_LIVE)
                self.assertIn("127.0.0.1:21002=127.0.0.1:11080",testfile.read_text())
                bh2.configure(bh2.PORT_STAGE)
                self.assertIn("127.0.0.1:21102=127.0.0.1:11080",testfile.read_text())

    def test_refuse_unknown_toml(self):
        with tempfile.TemporaryDirectory() as d:
            testfile=Path(d)/"backhaul.toml"
            testfile.write_text('ports=["wrong"]')
            with patch.object(bh2, "BH", testfile):
                with self.assertRaises(RuntimeError):
                    bh2.configure(bh2.PORT_LIVE)

    def test_probe_checks_real_download_size(self):
        calls=[]
        def fake_run(*argv,**kwargs):
            url=argv[-1]
            calls.append(url)
            if "trace" in url:
                return SimpleNamespace(returncode=0,stdout="ip=8.8.8.8\n")
            if "generate_204" in url:
                return SimpleNamespace(returncode=0,stdout="204")
            return SimpleNamespace(returncode=0,stdout="200 1048576")
        with patch.object(bh2, "run",fake_run):
            bh2.probe(21102,"8.8.8.8",thorough=True)
            self.assertEqual(sum("__down?" in x for x in calls),2)

    def test_probe_rejects_short_download(self):
        def fake_run(*argv,**kwargs):
            url=argv[-1]
            if "trace" in url:
                return SimpleNamespace(returncode=0,stdout="ip=8.8.8.8\n")
            if "generate_204" in url:
                return SimpleNamespace(returncode=0,stdout="204")
            return SimpleNamespace(returncode=0,stdout="200 100")
        with patch.object(bh2, "run",fake_run):
            with self.assertRaisesRegex(RuntimeError,"failed 1-MiB"):
                bh2.probe(21102,"8.8.8.8",thorough=True)

    def test_no_gateway_mutations(self):
        source=(HERE/"maya3-second-backhaul-experiment.py").read_text()
        for protected in ("systemctl\", \"restart\", \"dual-ha-v2-gateway",
                          "systemctl\", \"restart\", \"dual-ha-v2-health",
                          "systemctl\", \"restart\", \"dual-ha-backhaul",
                          "systemctl\", \"restart\", \"x-ui"):
            self.assertNotIn(protected,source)
        self.assertNotIn("/etc/dual-ha/v2/haproxy.cfg",source)
        self.assertNotIn("/etc/haproxy/haproxy.cfg",source)

if __name__=="__main__":
    unittest.main()
