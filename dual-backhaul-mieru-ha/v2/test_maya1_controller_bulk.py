#!/usr/bin/env python3
"""Offline-only Maya1 verified transfer quality tests. No live VPS probes."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
path=Path(__file__).with_name("maya1-next-controller.py")
spec=importlib.util.spec_from_file_location("maya1_bulk_controller",path)
c=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=c
spec.loader.exec_module(c)

def response(size=1048576,speed=200000,total=5.2,ttfb=.6,code=200,returncode=0):
    class Result:
        def __init__(self):
            self.returncode=returncode
            self.stdout=f"{code} {size} {speed} {total} {ttfb}"
            self.stderr=""
    return Result()

class TestMaya1Bulk(unittest.TestCase):
    def test_policy_exact_bytes_96_kib_rate_and_cost_cap(self):
        self.assertEqual(c.BULK_BYTES,1048576)
        self.assertEqual(c.BULK_URL,"https://speed.cloudflare.com/__down?bytes=1048576")
        self.assertEqual(c.MIN_BULK_BYTES_PER_SECOND,96*1024)
        self.assertEqual(c.BULK_ATTEMPTS,3)
        self.assertEqual(c.BULK_REQUIRED_PASSES,2)
        self.assertEqual(c.BULK_PERIOD,300)
        self.assertEqual(c.BULK_MAX_SECONDS,12)
        self.assertEqual(c.BULK_MAX_TTFB,8)

    def test_three_good_log_samples_all_pass(self):
        with patch.object(c,"curl",side_effect=[
            response(speed=201.7*1024,total=5.078,ttfb=.691),
            response(speed=189.2*1024,total=5.412,ttfb=.54)]):
            ok,info=c.bulk_probe(21101)
        self.assertTrue(ok)
        self.assertEqual(info["sample_pass"],2)
        self.assertEqual(info["sample_count"],2)
        self.assertEqual(info["bytes"],1048576)
        self.assertEqual(info["reason"],"ok")

    def test_one_failure_followed_by_two_passes(self):
        with patch.object(c,"curl",side_effect=[
            response(speed=69100,total=3.78),
            response(speed=160000,total=6.7),
            response(speed=220000,total=4.5)]):
            ok,info=c.bulk_probe(21102)
        self.assertTrue(ok)
        self.assertEqual(info["sample_pass"],2)
        self.assertEqual(info["sample_count"],3)
        self.assertEqual([x["reason"] for x in info["samples"]],
                         ["slow_or_short_download","ok","ok"])

    def test_slow_or_incomplete_rejected_without_weakening_threshold(self):
        with patch.object(c,"curl",side_effect=[
            response(speed=89131,total=2.94),response(size=262144,speed=200000,total=2)]):
            ok,info=c.bulk_probe(21101)
        self.assertFalse(ok)
        self.assertEqual(info["sample_pass"],0)
        self.assertEqual(info["sample_count"],2)
        self.assertEqual(info["reason"],"insufficient_1m_quality")
        for bad in (response(speed=200000,total=13),
                    response(speed=200000,total=11,ttfb=9),
                    response(size=262144,speed=200000,total=5),
                    response(speed=200000,total=4,code=502),
                    response(returncode=7)):
            with patch.object(c,"curl",return_value=bad):
                sample,_=c.bulk_sample(21102)
            self.assertFalse(sample)

    def test_both_shared_download_outages_protected_if_https_good(self):
        result={role:(3,True,.4,(False,{"reason":"slow_or_short_download"}))
                for role in c.PATHS}
        streaks={role:{"bulk_bad":1} for role in c.PATHS}
        self.assertTrue(c.common_bulk_probe_outage(result,streaks))
        # A speed-only failure must NEVER administratively drain HAProxy.
        self.assertIsNone(c.decision(True,True,0,999,0,True,
                                     peer_enabled=True,peer_short_ok=True))
        # A real dead lane can fail over only with a verified working peer.
        self.assertEqual(c.decision(True,False,4,0,0,True,
                                    peer_enabled=True,peer_short_ok=True),"disable")
        self.assertIsNone(c.decision(True,False,4,0,0,True,
                                     peer_enabled=False,peer_short_ok=False))
        self.assertIsNone(c.decision(True,False,4,0,0,True,
                                     peer_enabled=True,peer_short_ok=False))
        # Repair previously disabled lanes based on fresh HTTPS alone.
        self.assertEqual(c.decision(False,True,0,3,3,False),
                         "enable")
        result["mieru"]=(1,False,.4,(False,{"reason":"timeout_or_transport_error"}))
        self.assertFalse(c.common_bulk_probe_outage(result,streaks))
if __name__=="__main__":unittest.main(verbosity=2)
