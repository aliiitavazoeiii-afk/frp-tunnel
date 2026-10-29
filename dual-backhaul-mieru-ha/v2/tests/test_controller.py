import importlib.util
import pathlib
import subprocess
import unittest
from unittest.mock import patch

BASE = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("controller", BASE / "controller.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class ControllerTests(unittest.TestCase):
    def test_real_https_requires_two_of_three(self):
        with patch.object(mod, "probe_one", side_effect=[
            (True, 0.2), (False, 99.0), (True, 0.6)
        ]):
            ok, passed, latency = mod.probe_path(21001)
        self.assertTrue(ok)
        self.assertEqual(passed, 2)
        self.assertAlmostEqual(latency, 0.4)

    def test_fail_closed_on_one_working_target(self):
        with patch.object(mod, "probe_one", side_effect=[
            (False, 99.0), (False, 99.0), (True, 0.6)
        ]):
            ok, passed, _ = mod.probe_path(21002)
        self.assertFalse(ok)
        self.assertEqual(passed, 1)

    def test_reject_ordinary_tcp_listener_without_socks(self):
        fake = subprocess.CompletedProcess(args=[], returncode=97, stdout="000 0.2", stderr="invalid SOCKS")
        with patch.object(mod.subprocess, "run", return_value=fake):
            ok, _ = mod.probe_one(21001, "https://www.gstatic.com/generate_204", 204)
        self.assertFalse(ok)

    def test_stat_status_parsing(self):
        result = "# pxname,svname,status,check_status,\n" + \
                 "dual_egress,backhaul,MAINT,,\n" + \
                 "dual_egress,mieru,UP,L7OK,\n"
        with patch.object(mod, "api", return_value=result):
            self.assertEqual(mod.states(), {"backhaul":"MAINT","mieru":"UP"})

if __name__ == "__main__":
    unittest.main()
