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


class V3TransactionTests(unittest.TestCase):
 def test_mieru_canary_fail_preserves_live_config(self):
  from tempfile import TemporaryDirectory
  with TemporaryDirectory() as d:
   with patch.object(v3,'saved',return_value=b'OLD'),\
        patch.object(v3,'get_weight',return_value=1),\
        patch.object(v3,'stage_mieru',return_value=None),\
        patch.object(v3,'probe',return_value=False),\
        patch.object(v3,'journal'),\
        patch.object(v3,'maybe_stop_candidate'),\
        patch.object(v3,'stop_process'),\
        patch.object(sys.modules['dual'],'atomic_write',create=True) as write:
    with self.assertRaises(v3.SwapError):
     v3.swap_mieru('185.190.52.164','82.152.132.220',pathlib.Path(d))
    write.assert_not_called()

 def test_mieru_live_failure_restores_old_bytes(self):
  from tempfile import TemporaryDirectory
  with TemporaryDirectory() as d:
   work=pathlib.Path(d)
   (work/'mieru.production.json').write_text('{"test":"candidate"}')
   with patch.object(v3,'saved',return_value=b'OLD'),\
        patch.object(v3,'get_weight',return_value=1),\
        patch.object(v3,'stage_mieru',return_value=None),\
        patch.object(v3,'probe',side_effect=[True,False]),\
        patch.object(v3,'journal'),\
        patch.object(v3,'cmd'),\
        patch.object(v3,'maybe_stop_candidate'),\
        patch.object(v3,'stop_process'),\
        patch.object(v3,'JOURNAL',work/'not-created.json'),\
        patch.object(sys.modules['dual'],'atomic_write',create=True) as write,\
        patch.object(sys.modules['dual'],'active_ips',return_value={'mieru':'185.190.52.164'},create=True):
    with self.assertRaises(v3.SwapError):
     v3.swap_mieru('185.190.52.164','82.152.132.220',work)
    self.assertEqual(write.call_count,2)
    self.assertEqual(write.call_args.args[1],b'OLD')

 def test_backhaul_bad_canary_does_not_write_live_config(self):
  from tempfile import TemporaryDirectory
  with TemporaryDirectory() as d:
   with patch.object(v3,'saved',return_value=b'OLD'),\
        patch.object(v3,'get_weight',return_value=1),\
        patch.object(v3,'guard_exists',return_value=False),\
        patch.object(v3,'stage_backhaul',return_value={}),\
        patch.object(v3,'stage_firewall',return_value=['new']),\
        patch.object(v3,'_start_stage',return_value=[]),\
        patch.object(v3,'probe',return_value=False),\
        patch.object(v3,'journal'),\
        patch.object(v3,'undo_stage_firewall'),\
        patch.object(v3,'maybe_stop_candidate'),\
        patch.object(v3,'stop_process'),\
        patch.object(sys.modules['dual'],'ssh',return_value='',create=True),\
        patch.object(sys.modules['dual'],'atomic_write',create=True) as write:
    with self.assertRaises(v3.SwapError):
     v3.swap_backhaul('152.237.230.159','82.152.132.220','94.184.4.38',pathlib.Path(d))
    write.assert_not_called()

 def test_guard_uses_source_restricted_tcp_rules(self):
  with patch.object(v3,'guard_exists',return_value=False),patch.object(v3,'ipt') as ipt:
   v3.begin_production_guard('82.152.132.220','94.184.4.38')
   commands=[c.args for c in ipt.call_args_list]
   self.assertTrue(any('REJECT' in call and 'tcp' in call for call in commands))
   self.assertTrue(any(call[:3]==('-I','INPUT','1') for call in commands))

 def test_wait_gateway_requires_nonzero_weight(self):
  with patch.object(sys.modules['dual'],'haproxy_metrics',return_value={'mieru':{'state':'UP'}},create=True),\
       patch.object(v3,'get_weight',return_value=0),\
       patch.object(v3.time,'monotonic',side_effect=[0,3]),\
       patch.object(v3.time,'sleep'):
   self.assertFalse(v3.wait_gateway('mieru',timeout=1))

if __name__=='__main__':unittest.main()