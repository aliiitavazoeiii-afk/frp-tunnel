#!/usr/bin/env python3
"""No live services: helper color health gates and NO_COLOR safety."""
import importlib
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
import dual_backhaul_menu as m
class Tests(unittest.TestCase):
    def test_fresh_success_is_green(self):
        info={"available":True,"passed_probes":3,"bulk_pass":True}
        self.assertEqual(m.lane_health("UP","1",info,2),("UP","green"))
    def test_speed_failure_stays_up_when_haproxy_up(self):
        slow={"available":True,"passed_probes":3,"bulk_pass":False}
        self.assertEqual(m.lane_health("UP",1,slow,6),("UP","green"))
        self.assertEqual(m.lane_health("UP",1,{"available":False,"passed_probes":3,"bulk_pass":False},6),("UP","green"))
        self.assertEqual(m.lane_health("UP",1,slow,None),("UP","yellow"))

    def test_down_is_red_but_not_claimed_filtered(self):
        self.assertEqual(m.lane_health("DOWN","0",{"available":False,"passed_probes":0},2),
                         ("DOWN","red"))
    def test_stale_and_manual_drained_not_false_green(self):
        valid={"available":True,"passed_probes":3,"bulk_pass":True}
        self.assertEqual(m.lane_health("UP",1,valid,45)[1],"yellow")
        self.assertEqual(m.lane_health("UP",0,valid,2),("DISABLED","yellow"))
        self.assertEqual(m.lane_health("UP",1,{},2)[1],"yellow")
    def test_terminal_only_color(self):
        old=m._COLOR
        try:
            m._COLOR=False
            self.assertEqual(m.paint("152.237.230.140","cyan"),"152.237.230.140")
            m._COLOR=True
            self.assertIn("\033[1;36m",m.paint("152.237.230.140","cyan"))
        finally:
            m._COLOR=old
if __name__=="__main__":
    unittest.main(verbosity=2)
