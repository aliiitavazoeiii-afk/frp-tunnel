"""Offline unit tests; no SSH, packets, iptables, or systemctl effects."""
import importlib.util
import pathlib
import sys
import types
import unittest
from unittest.mock import patch

sys.modules.setdefault('dual', types.ModuleType('dual'))
sys.modules.setdefault('dual_auto', types.ModuleType('dual_auto'))
p=pathlib.Path(__file__).with_name('dual_swap_v3.py')
spec=importlib.util.spec_from_file_location('dual_swap_v3',p)
v3=importlib.util.module_from_spec(spec)
spec.loader.exec_module(v3)

class V3Tests(unittest.TestCase):
 def test_rejects_reserved_and_loopback_ips(self):
  for ip in ('203.0.113.10','127.0.0.1','192.168.0.1','bad','0.0.0.0'):
   with self.assertRaises(Exception):v3.host_ip(ip)
  self.assertEqual(v3.host_ip('82.152.132.220'),'82.152.132.220')
 def test_egress_mismatch_never_tests_download(self):
  import subprocess
  response=subprocess.CompletedProcess([],0,b'ip=1.1.1.1\n',b'')
  with patch.object(v3,'cmd',return_value=response) as c:
   self.assertFalse(v3.probe(21102,'82.152.132.220',label='TEST'))
   self.assertEqual(c.call_count,1)
 def test_partial_download_rejected(self):
  import subprocess
  trace=subprocess.CompletedProcess([],0,b'ip=82.152.132.220\n',b'')
  bad=subprocess.CompletedProcess([],28,'200 1024 16.0 1.0','')
  with patch.object(v3,'cmd',side_effect=[trace,bad,bad,bad]):
   self.assertFalse(v3.probe(21102,'82.152.132.220',label='TEST'))
 def test_two_complete_downloads_accepted(self):
  import subprocess
  trace=subprocess.CompletedProcess([],0,b'ip=82.152.132.220\n',b'')
  good=subprocess.CompletedProcess([],0,'200 1048576 1.4 0.2','')
  bad=subprocess.CompletedProcess([],28,'200 1000 16.0 1.0','')
  with patch.object(v3,'cmd',side_effect=[trace,good,bad,good]):
   self.assertTrue(v3.probe(21102,'82.152.132.220',label='TEST'))
 def test_critical_legacy_survivor_check_not_used(self):
  import inspect
  s=inspect.getsource(v3.rotate)
  self.assertNotIn('safety_checks',s)
  self.assertNotIn('confirm_egress',s)
 def test_stage_backhaul_uses_a_disjoint_port(self):
  self.assertNotIn(v3.STAGE_BACKHAUL_TCP,(18443,443))
  self.assertNotIn(v3.STAGE['backhaul'],v3.LIVE.values())
 def test_mieru_staging_and_live_ports_differ(self):
  self.assertEqual(v3.STAGE['mieru'],21102)
  self.assertEqual(v3.LIVE['mieru'],21002)

if __name__=='__main__':unittest.main()