#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys,unittest
from unittest.mock import patch
source=Path(__file__).with_name("maya1-dual-helper.py")
spec=importlib.util.spec_from_file_location("maya1_helper",source)
h=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=h
spec.loader.exec_module(h)

class TestHelper(unittest.TestCase):
    def test_runtime_healthy_and_ip_coloring(self):
        info={"available":True,"passed_probes":3,"bulk_pass":True,
              "expected_foreign_ip":"82.152.132.159"}
        row={"addr":"127.0.0.1:21101","status":"UP","weight":"1"}
        self.assertEqual(h.status_label(row,info,2,"82.152.132.159",21101),
                         ("UP","green"))
        self.assertEqual(h.status_label(row,info,None,"82.152.132.159",21101),
                         ("UNKNOWN","amber"))
        self.assertEqual(h.status_label(row,info,2,"82.152.132.159",21001),
                         ("UNKNOWN","amber"))
    def test_down_and_disabled_not_claimed_filtered(self):
        info={"available":False,"passed_probes":0,"bulk_pass":False,
              "expected_foreign_ip":"152.237.230.77"}
        row={"addr":"127.0.0.1:21102","status":"DOWN","weight":"1"}
        self.assertEqual(h.status_label(row,info,4,"152.237.230.77",21102),
                         ("DOWN","red"))
        self.assertNotIn("filtered",str(h.status_label(row,info,4,"152.237.230.77",21102)))
        info["available"]=True;info["passed_probes"]=3;info["bulk_pass"]=True
        row.update({"status":"UP","weight":"0"})
        self.assertEqual(h.status_label(row,info,2,"152.237.230.77",21102),
                         ("DISABLED","amber"))
    def test_color_suppressed_without_tty(self):
        with patch.object(h,"_COLOR",False):
            self.assertEqual(h.paint("82.152.132.159","cyan"),"82.152.132.159")
        with patch.object(h,"_COLOR",True):
            self.assertIn("\033[1;36m",h.paint("82.152.132.159","cyan"))
    def test_no_legacy_replace(self):
        txt=source.read_text()
        self.assertIn("legacy dual replace would operate on the WRONG ports",txt)
        self.assertNotIn("rotate_primary(",txt)
        self.assertNotIn("dual_auto.authorize_new(",txt)
if __name__=="__main__":unittest.main(verbosity=2)
