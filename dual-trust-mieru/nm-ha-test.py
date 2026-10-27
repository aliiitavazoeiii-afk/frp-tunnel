#!/usr/bin/env python3
"""Deterministic, filesystem-isolated HA transition tests. Never open real Controller."""
import importlib.util, pathlib, subprocess, tempfile, unittest
from unittest import mock
spec=importlib.util.spec_from_file_location("nm_ha",pathlib.Path(__file__).with_name("nm-ha-agent.py"))
ha=importlib.util.module_from_spec(spec)
spec.loader.exec_module(ha)

def outcome(n,m):
    def record(state):
        ok=state=="HEALTHY"
        bad=state=="DOWN"
        return {"health":state,"probes":{a:{"ok":ok and not bad,"ms":250 if ok else None,
                                           "code":204 if ok else None} for a in ("direct","split","telegram")}}
    return {"naive":record(n),"mieru":record(m)}
class HATests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir=pathlib.Path(self.tmp.name)
        p=mock.patch.multiple(ha,STATE=self.dir/"state",LOCK=str(self.dir/"lock"))
        p.start();self.addCleanup(p.stop)
        self.role_restart=[]
        self.selected="DUAL-AUTO"
        def fakegroup():
            return {"type":"Selector","all":["DUAL-AUTO","XUDP-TRUST","XUDP-MIERU"],
                    "now":self.selected}
        def fake_select(target,current):
            self.assertEqual(current,self.selected)
            self.selected=target
            return target
        def fake_run(cmd,**kwargs):
            self.role_restart.append(cmd)
            return subprocess.CompletedProcess(cmd,0)
        for attr,value in [("group",fakegroup),("select",fake_select),
                           ("validate_services",lambda:None)]:
            x=mock.patch.object(ha,attr,value);x.start();self.addCleanup(x.stop)
        y=mock.patch.object(ha.subprocess,"run",fake_run);y.start();self.addCleanup(y.stop)
        z=mock.patch.object(ha.time,"sleep",lambda x:None);z.start();self.addCleanup(z.stop)
    def cycle(self,n,m):
        x=mock.patch.object(ha,"probe_all",lambda:outcome(n,m))
        x.start()
        try:ha.live_once()
        finally:x.stop()
        return ha.load()
    def test_healthy_never_restarts_or_selects(self):
        for i in range(4): s=self.cycle("HEALTHY","HEALTHY")
        self.assertEqual(self.selected,"DUAL-AUTO")
        self.assertEqual(self.role_restart,[])
        self.assertEqual(s["roles"]["naive"]["status"],"HEALTHY")
    def test_one_down_one_restart_then_quarantine_and_restore(self):
        self.cycle("DOWN","HEALTHY")
        self.assertEqual(self.role_restart,[])
        s=self.cycle("DOWN","HEALTHY")
        self.assertEqual(self.selected,"XUDP-MIERU")
        self.assertEqual(s["roles"]["naive"]["status"],"QUARANTINED")
        self.assertEqual(len(self.role_restart),1)
        self.cycle("DOWN","HEALTHY")
        self.assertEqual(len(self.role_restart),1,"never restart twice in same incident")
        for i in range(3):s=self.cycle("HEALTHY","HEALTHY")
        self.assertEqual(self.selected,"DUAL-AUTO")
        self.assertFalse(s["roles"]["naive"]["restart_attempted"])
        self.assertEqual(len(self.role_restart),1)
    def test_both_down_no_restart_or_flip(self):
        self.cycle("DOWN","DOWN")
        s=self.cycle("DOWN","DOWN")
        self.assertEqual(len(self.role_restart),0)
        self.assertEqual(self.selected,"DUAL-AUTO")
        self.assertEqual(s["roles"]["naive"]["status"],"SUSPECT")
    def test_partial_failure_does_not_cut_over(self):
        for i in range(3):
            s=self.cycle("DEGRADED","HEALTHY")
        self.assertEqual(self.selected,"DUAL-AUTO")
        self.assertEqual(len(self.role_restart),0)
        self.assertEqual(s["roles"]["naive"]["status"],"DEGRADED")
if __name__=="__main__":
    unittest.main(verbosity=2)
