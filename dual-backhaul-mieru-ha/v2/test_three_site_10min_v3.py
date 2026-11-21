#!/usr/bin/env python3
"""OFFLINE: V3 three-site ten-minute safe routing tests on both Maya nodes."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent
def load(filename):
    spec=importlib.util.spec_from_file_location("site_"+filename.replace("-","_").replace(".","_"),
                                                 ROOT/filename)
    mod=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=mod
    spec.loader.exec_module(mod)
    return mod

class SiteChecks(unittest.TestCase):
    def test_constants_and_no_bulk_in_automatic_or_diagnostic_routing(self):
        for filename,ports in (
            ("maya1-next-controller.py",{"backhaul":21101,"mieru":21102}),
            ("dual-backhaul-controller.py",{"backhaul":21001,"mieru":21002}),
        ):
            with self.subTest(controller=filename):
                m=load(filename)
                self.assertEqual(m.PATHS,ports)
                self.assertEqual(m.CHECK_PERIOD,600)
                self.assertEqual(m.CONFIRM_DELAY,20)
                self.assertEqual(m.SHORT_FALL,2)
                self.assertEqual(m.RISE,2)
                self.assertEqual(m.POLICY,"two-backhaul-3site-10m-v3")
                self.assertEqual(len(m.TARGETS),3)
                self.assertEqual([x[0] for x in m.TARGETS],[
                    "https://www.gstatic.com/generate_204",
                    "https://www.cloudflare.com/cdn-cgi/trace",
                    "https://www.apple.com/library/test/success.html"])
                source=(ROOT/filename).read_text()
                main=source.split("def main():",1)[1].split("def diagnose():",1)[0]
                diagnose=source.split("def diagnose():",1)[1]
                for blocked in ("bulk_probe(", "bulk_sample(", "speed_download",
                                "MIN_BULK_BYTES_PER_SECOND", "BULK_FALL"):
                    self.assertNotIn(blocked,main)
                    self.assertNotIn(blocked,diagnose)
                self.assertIn("time.sleep(CONFIRM_DELAY)",main)
                self.assertIn("time.sleep(max(1,CHECK_PERIOD",main)
                self.assertIn("peer_enabled=is_enabled(before[peer])",main)

    def test_three_probes_validation_and_correct_exit(self):
        class Response:
            def __init__(self,code=0,output=""):
                self.returncode=code
                self.stdout=output
        for filename in ("maya1-next-controller.py","dual-backhaul-controller.py"):
            m=load(filename)
            def perfect(port,url,extra=(),timeout=12):
                if url.endswith("generate_204"):
                    return Response(0,"204")
                if url.endswith("cdn-cgi/trace"):
                    return Response(0,"fl=20\nip=82.152.132.159\n")
                return Response(0,"200")
            with patch.object(m,"curl",side_effect=perfect):
                count,ok,avg,details=m.three_site_probe(21101,"82.152.132.159")
                self.assertEqual(count,3)
                self.assertTrue(ok)
                self.assertEqual(set(details),{"google","cloudflare","apple"})
                self.assertTrue(all(v["ok"] for v in details.values()))
                count,ok,avg,details=m.three_site_probe(21101,"152.237.230.77")
                self.assertEqual(count,2)
                self.assertTrue(ok)
                self.assertFalse(details["cloudflare"]["ok"])
            def failure(port,url,extra=(),timeout=12):
                if url.endswith("generate_204"):
                    return Response(1,"")
                if url.endswith("cdn-cgi/trace"):
                    return Response(1,"")
                return Response(0,"200")
            with patch.object(m,"curl",side_effect=failure):
                count,ok,avg,details=m.three_site_probe(21101,"82.152.132.159")
                self.assertEqual(count,1)
                self.assertFalse(ok)

    def test_safe_disable_requires_two_failed_rounds_and_healthy_peer(self):
        for filename in ("maya1-next-controller.py","dual-backhaul-controller.py"):
            m=load(filename)
            self.assertTrue(m.is_enabled({"status":"UP 1/2","weight":"1"}))
            self.assertFalse(m.is_enabled({"status":"MAINT","weight":"1"}))
            self.assertFalse(m.is_enabled({"status":"UP","weight":"0"}))
            self.assertIsNone(m.decision(True,False,1,0,0,False,
                                         peer_enabled=True,peer_short_ok=True))
            self.assertEqual(m.decision(True,False,2,999,0,False,
                                         peer_enabled=True,peer_short_ok=True),"disable")
            self.assertIsNone(m.decision(True,False,2,999,0,False,
                                         peer_enabled=False,peer_short_ok=False))
            self.assertIsNone(m.decision(True,False,2,999,0,False,
                                         peer_enabled=True,peer_short_ok=False))
            self.assertIsNone(m.decision(True,True,0,999,99,False,
                                         peer_enabled=True,peer_short_ok=True))
            self.assertIsNone(m.decision(False,True,0,999,1,False))
            self.assertEqual(m.decision(False,True,0,999,2,False),"enable")
if __name__=="__main__":
    unittest.main(verbosity=2)
