#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
path=Path(__file__).with_name("maya1-quality-readonly-audit.py")
spec=importlib.util.spec_from_file_location("maya1_quality",path)
m=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=m
spec.loader.exec_module(m)

class TestMaya1Quality(unittest.TestCase):
    def test_exact_expected_hosts_and_repeat_count(self):
        self.assertEqual(m.EXPECTED["NEW_BH1"],(21101,"82.152.132.159",3))
        self.assertEqual(m.EXPECTED["NEW_BH2"],(21102,"152.237.230.77",3))
        self.assertEqual(m.REQUIRED_SPEED_BPS,96*1024)
        self.assertEqual(m.REQUIRED_BYTES,1048576)

    def test_gate_rejects_cold_or_sluggish_one_mib(self):
        good={"ok":True,"http":"200","bytes":1048576,
              "speed_kib_s":110.0,"time_s":9.3,"ttfb_s":1.0}
        self.assertTrue(m.quality_ok(good))
        self.assertFalse(m.quality_ok(dict(good,speed_kib_s=89.1)))
        self.assertFalse(m.quality_ok(dict(good,time_s=13.0)))
        self.assertFalse(m.quality_ok(dict(good,ttfb_s=9.0)))
        self.assertFalse(m.quality_ok(dict(good,bytes=262144)))

    def test_curl_readonly_and_bounded(self):
        class Stub:
            returncode=0
            stdout="200 262144 89131 2.941 2.500 0.030 0.100"
            stderr=""
        with patch.object(m.subprocess,"run",return_value=Stub()) as call:
            res=m.bulk(21101,262144)
            self.assertTrue(res["ok"])
            self.assertEqual(res["bytes"],262144)
            self.assertEqual(res["ttfb_s"],2.5)
            self.assertGreater(res["transfer_kib_s"],500)
            args=call.call_args.args[0]
            self.assertEqual(args[args.index("--socks5-hostname")+1],"127.0.0.1:21101")
            self.assertIn("--max-time",args)
            self.assertNotIn("--insecure",args)

    def test_no_mutations(self):
        source=path.read_text()
        for term in ("systemctl","iptables","haproxy.sock",
                     "set server","shutil.copy","os.replace","subprocess.Popen"):
            self.assertNotIn(term,source)

if __name__=="__main__":
    unittest.main(verbosity=2)
