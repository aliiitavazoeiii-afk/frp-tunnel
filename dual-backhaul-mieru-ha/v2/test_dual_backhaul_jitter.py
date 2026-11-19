#!/usr/bin/env python3
"""Offline audit checks: percentile and output correctness, no live sockets."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("dbj_audit",ROOT/"dual-backhaul-jitter-audit.py")
a=importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)

class TestJitter(unittest.TestCase):
    def test_percentile_handles_empty_and_real_spikes(self):
        self.assertIsNone(a.percentile([],95))
        values=[100]*18+[1500,2000]
        self.assertEqual(a.percentile(values,50),100)
        self.assertGreater(a.percentile(values,95),1499)
        self.assertEqual(a.percentile(values,100),2000)
    def test_summary_counts_spikes_errors_and_denials(self):
        samples=[
            {"ok":True,"ttfb_ms":100,"http":200,"reason":"ok"},
            {"ok":True,"ttfb_ms":1550,"http":403,"reason":"ok"},
            {"ok":False,"ttfb_ms":None,"http":0,"reason":"curl_exit_28"}
        ]
        res=a.summary(samples)
        self.assertEqual(res["ok"],2)
        self.assertEqual(res["fail"],1)
        self.assertEqual(res["ttfb_over_1400ms"],1)
        self.assertEqual(res["http_codes"],{"0":1,"200":1,"403":1})
    def test_sample_read_only_and_no_http_fail_requirement(self):
        fake=SimpleNamespace(returncode=0,stdout="403 0.002 0.2 1.5 1.7 300 176",stderr="")
        with patch.object(a,"run",return_value=fake) as r:
            out=a.sample(21001,"https://www.instagram.com/robots.txt")
        self.assertTrue(out["ok"])
        self.assertEqual(out["ttfb_ms"],1500)
        cmd=r.call_args.args[0]
        self.assertIn("--socks5-hostname",cmd)
        self.assertEqual(cmd[cmd.index("--socks5-hostname")+1],"127.0.0.1:21001")
        self.assertNotIn("-X",cmd)
    def test_verify_flag_has_no_tunnel_interaction(self):
        with patch("sys.argv",["audit","--verify"]),patch.object(a,"audit") as do:
            self.assertEqual(a.main(),0)
            do.assert_not_called()
if __name__=="__main__":
    unittest.main()
