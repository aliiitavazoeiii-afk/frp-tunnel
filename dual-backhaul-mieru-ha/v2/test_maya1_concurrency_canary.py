#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
path=Path(__file__).with_name("maya1-concurrency-canary.py")
spec=importlib.util.spec_from_file_location("maya1_concurrency",path)
m=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=m
spec.loader.exec_module(m)

class TestCanary(unittest.TestCase):
    def test_fixed_scope(self):
        self.assertEqual(m.LANES,{"BACKHAUL1":(21101,"82.152.132.159"),
                                 "BACKHAUL2":(21102,"152.237.230.77")})
        self.assertEqual(m.BYTES,1048576)
        self.assertEqual(m.FLOWS_PER_LANE,4)
        self.assertEqual(m.LIMIT_SECONDS,45)
        t=path.read_text()
        for forbidden in ("systemctl", "haproxy.sock","set server","iptables","/etc/dual-ha/v2/"):
            self.assertNotIn(forbidden,t)

    def test_exact_bytes_200_and_timeout(self):
        class R:
            returncode=0
            stdout="200 1048576 7.31 0.62"
            stderr=""
        with patch.object(m,"command",return_value=R()) as call:
            row=m.sample(21101)
            self.assertTrue(row["ok"])
            self.assertEqual(row["bytes"],1048576)
            self.assertEqual(call.call_args.kwargs["timeout"],45)
        with patch.object(m,"command",return_value=type("F",(),{"returncode":0,"stdout":"200 524288 7.31 0.62","stderr":""})()):
            self.assertFalse(m.sample(21102)["ok"])

    def test_partial_run_rejected(self):
        ok={"ok":True,"bytes":1048576}
        bad={"ok":False,"bytes":0}
        self.assertTrue(m.summarize([ok]*4,8)["ok"])
        self.assertFalse(m.summarize([ok]*3+[bad],8)["ok"])
        self.assertEqual(m.summarize([ok]*4,8)["aggregate_kib_s"],512)

    def test_egress_gate(self):
        class R:
            returncode=0
            stdout="ip=82.152.132.159\n"
            stderr=""
        with patch.object(m,"command",return_value=R()):
            self.assertTrue(m.identity(21101,"82.152.132.159"))
            self.assertFalse(m.identity(21101,"152.237.230.77"))

if __name__=="__main__":
    unittest.main(verbosity=2)
