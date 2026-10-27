#!/usr/bin/env python3
"""Offline, fake-data-only tests for read-only live audit."""
import importlib.util
from pathlib import Path
import unittest

path=Path(__file__).with_name("nm-live-audit.py")
spec=importlib.util.spec_from_file_location("live_audit",path)
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def entry(key, role, up, down, start="t0"):
    chain={"NAIVE":"XUDP-TRUST","MIERU":"XUDP-MIERU","OTHER":"UNKNOWN"}[role]
    return {"id":key,"start":start,"chains":["DUAL",chain],
            "upload":up,"download":down}


class AuditTest(unittest.TestCase):
    def test_role_of(self):
        self.assertEqual(mod.role_of({"chains":["DUAL","XUDP-TRUST"]}),"NAIVE")
        self.assertEqual(mod.role_of({"chains":["DUAL","XUDP-NAIVE"]}),"NAIVE")
        self.assertEqual(mod.role_of({"chains":["DUAL","XUDP-MIERU"]}),"MIERU")
        self.assertEqual(mod.role_of({"chains":["XUDP-TRUST","XUDP-MIERU"]}),"OTHER")
        self.assertEqual(mod.role_of({"chains":None}),"OTHER")

    def test_new_counts_and_byte_deltas(self):
        meter=mod.DeltaMeter()
        meter.push([entry("old","NAIVE",1000,10000)])
        self.assertEqual(meter.new["NAIVE"],0)
        meter.push([entry("old","NAIVE",1200,10500),
                    entry("new","MIERU",8000,50000)])
        self.assertEqual(meter.new["MIERU"],1)
        self.assertEqual(meter.up["NAIVE"],200)
        self.assertEqual(meter.down["NAIVE"],500)
        self.assertEqual(meter.up["MIERU"],0)
        meter.push([entry("old","NAIVE",1400,10550),
                    entry("new","MIERU",8300,53000)])
        self.assertEqual(meter.new["MIERU"],1)
        self.assertEqual(meter.up["MIERU"],300)
        self.assertEqual(meter.down["MIERU"],3000)
        self.assertEqual(meter.up["NAIVE"],400)

    def test_no_reimport_after_gap_and_counter_reset(self):
        meter=mod.DeltaMeter()
        meter.push([entry("x","NAIVE",0,1000)])
        meter.push([])
        meter.push([entry("x","NAIVE",0,9000)])
        self.assertEqual(meter.new["NAIVE"],0)  # previously seen
        self.assertEqual(meter.down["NAIVE"],0) # gap not safely measured
        meter.push([entry("x","NAIVE",0,5)])
        self.assertEqual(meter.down["NAIVE"],0) # reset guarded

    def test_id_start_distinguishes_reuse(self):
        meter=mod.DeltaMeter()
        meter.push([entry("x","NAIVE",0,0,start="t0")])
        meter.push([entry("x","MIERU",0,0,start="t1")])
        self.assertEqual(meter.new["MIERU"],1)

    def test_uncertain_values(self):
        self.assertIsNone(mod.traffic_counter({"upload":-1,"download":10}))
        self.assertIsNone(mod.traffic_counter({"upload":False,"download":10}))
        self.assertEqual(mod.percent(0,0),"N/A")
        self.assertEqual(mod.percent(1,3),"25.0%")


if __name__=="__main__":
    unittest.main(verbosity=2)
