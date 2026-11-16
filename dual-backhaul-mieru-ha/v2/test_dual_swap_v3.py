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

auto_spec=importlib.util.spec_from_file_location('dual_auto_actual',p.with_name('dual_auto.py'))
real_auto=importlib.util.module_from_spec(auto_spec)
auto_spec.loader.exec_module(real_auto)

class V3Tests(unittest.TestCase):
 def test_rejects_reserved_and_loopback_ips(self):
  for ip in ('203.0.113.10','127.0.0.1','192.168.0.1','bad','0.0.0.0'):
   with self.assertRaises(Exception):v3.host_ip(ip)
  self.assertEqual(v3.host_ip('82.152.132.220'),'82.152.132.220')
 def test_egress_mismatch_never_tests_download(self):
  import subprocess
  response=subprocess.CompletedProcess([],0,'ip=1.1.1.1\n',b'')
  with patch.object(v3,'cmd',return_value=response) as c:
   self.assertFalse(v3.probe(21102,'82.152.132.220',label='TEST'))
   self.assertEqual(c.call_count,1)
 def test_partial_download_rejected(self):
  import subprocess
  trace=subprocess.CompletedProcess([],0,'ip=82.152.132.220\n',b'')
  bad=subprocess.CompletedProcess([],28,'200 1024 16.0 1.0','')
  with patch.object(v3,'cmd',side_effect=[trace,bad,bad,bad]):
   self.assertFalse(v3.probe(21102,'82.152.132.220',label='TEST'))
 def test_two_complete_downloads_accepted(self):
  import subprocess
  trace=subprocess.CompletedProcess([],0,'ip=82.152.132.220\n',b'')
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
        patch.object(v3,'wait_backhaul_candidate',return_value=True),\
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
        patch.object(v3,'wait_backhaul_candidate',return_value=True),\
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


class V3Maya4RegressionTests(unittest.TestCase):
 def test_old_vps_ssh_is_unconditionally_forbidden(self):
  import inspect
  source=inspect.getsource(v3)
  self.assertNotIn('dual.ssh(old,',source)
  self.assertFalse(hasattr(v3,'cleanup_old_remote'))
  with patch.object(sys.modules['dual'],'ssh',side_effect=AssertionError('OLD SSH'),create=True):
   self.assertEqual(v3.finalize_old_host('185.190.52.166','82.152.141.33','backhaul'),
                    'old_vps_not_contacted')

 def test_delayed_reverse_canary_retries_before_cutover(self):
  import subprocess
  fail=subprocess.CompletedProcess([],7,'','curl: (7) Could not connect')
  good=subprocess.CompletedProcess([],0,'ip=82.152.141.33\n','')
  with patch.object(v3,'cmd',side_effect=[fail,fail,good]) as command, \
       patch.object(v3.time,'sleep') as sleep:
   self.assertTrue(v3.wait_backhaul_candidate(21101,'82.152.141.33',attempts=4))
   self.assertEqual(command.call_count,3)
   self.assertEqual(sleep.call_count,2)

 def test_intentionally_drained_backhaul_weight_stays_zero(self):
  import inspect
  source=inspect.getsource(v3.swap_backhaul)
  self.assertIn('if old_weight == 0:',source)
  self.assertIn('if get_weight("backhaul") != 0:',source)
  self.assertIn('set_weight("backhaul", 0)',source)
  self.assertIn('if not wait_gateway("backhaul"):',source)
  self.assertNotIn('set_weight("backhaul", 1)',source)

 def test_production_reverse_readiness_precedes_live_downloads(self):
  import inspect
  src=inspect.getsource(v3.swap_backhaul)
  start=src.index('dual.ssh(new, "systemctl enable --now dual-ha-backhaul-client"')
  readiness=src.index('wait_backhaul_candidate(LIVE["backhaul"], new, attempts=12)')
  download=src.index('probe(LIVE["backhaul"], new, label="LIVE BACKHAUL")')
  self.assertLess(start,readiness)
  self.assertLess(readiness,download)

 def test_live_not_ready_rolls_back_without_old_ssh(self):
  from tempfile import TemporaryDirectory
  from unittest.mock import MagicMock
  with TemporaryDirectory() as d:
   work=pathlib.Path(d)
   for name in ('backhaul.foreign-bundle.env','backhaul.production.toml','router.production.cfg'):
    (work/name).write_text('candidate')
   ready=MagicMock(side_effect=[True,False])
   ssh=MagicMock(return_value='')
   write=MagicMock()
   patches={
    'saved':MagicMock(return_value=b'old'),
    'get_weight':MagicMock(return_value=1),
    'guard_exists':MagicMock(return_value=False),
    'stage_backhaul':MagicMock(return_value={}),
    'stage_firewall':MagicMock(return_value=['allow']),
    '_start_stage':MagicMock(return_value=[]),
    'wait_backhaul_candidate':ready,
    'probe':MagicMock(return_value=True),
    'set_foreign_port':MagicMock(),
    'begin_production_guard':MagicMock(),
    'remove_production_guard':MagicMock(),
    'set_weight':MagicMock(),
    'journal':MagicMock(),
    'undo_stage_firewall':MagicMock(),
    'maybe_stop_candidate':MagicMock(),
    'cmd':MagicMock(),
    'is_listening':MagicMock(return_value=False),
    'committed_phase':MagicMock(return_value=False),
    'stop_process':MagicMock()
   }
   with patch.multiple(v3,**patches), \
        patch.multiple(sys.modules['dual'],ssh=ssh,atomic_write=write,create=True):
    with self.assertRaises(v3.SwapError):
     v3.swap_backhaul('185.190.52.166','82.152.141.33','5.10.249.206',work)
    self.assertEqual(ready.call_count,2)
    self.assertEqual(write.call_count,6)
    self.assertEqual([c.args[1] for c in write.call_args_list[-3:]], [b'old']*3)
    self.assertTrue(all(call.args[0]=='82.152.141.33' for call in ssh.call_args_list))

 def test_unreachable_reverse_canary_fails_closed(self):
  import subprocess
  fail=subprocess.CompletedProcess([],28,'','operation timed out')
  with patch.object(v3,'cmd',return_value=fail),patch.object(v3.time,'sleep'):
   self.assertFalse(v3.wait_backhaul_candidate(21101,'82.152.141.33',attempts=2))


 def test_verified_previous_new_host_install_is_retryable(self):
  import hashlib
  from tempfile import TemporaryDirectory
  with TemporaryDirectory() as directory:
   bundle=pathlib.Path(directory)/'candidate.env'
   bundle.write_text("BH_TOKEN='not-a-real-secret'\n")
   expected=hashlib.sha256(bundle.read_bytes()).hexdigest()
   with patch.object(sys.modules['dual'],'ssh',
                     side_effect=['REUSE_FAILED_V3_CANDIDATE',expected,'VERIFIED_PREVIOUS_V3_CANDIDATE_REUSED'],
                     create=True) as ssh, \
        patch.object(sys.modules['dual'],'scp',create=True) as scp:
    real_auto.prepared_backhaul_install('82.152.141.33','5.10.249.206',bundle)
    self.assertEqual(ssh.call_count,3)
    self.assertTrue(all(call.args[0]=='82.152.141.33' for call in ssh.call_args_list))
    scp.assert_called_once()

 def test_active_foreign_reuse_requires_exact_operator_approval(self):
  from tempfile import TemporaryDirectory
  with TemporaryDirectory() as d:
   candidate=pathlib.Path(d)/'new.env'
   candidate.write_text("BH_TOKEN='fake'\n")
   with patch.object(sys.modules['dual'],'ssh',
                     return_value='REUSE_ACTIVE_OWNED_BACKHAUL',create=True) as ssh, \
        patch('builtins.input',return_value='NO'), \
        patch.object(sys.modules['dual'],'scp',create=True) as scp:
    with self.assertRaisesRegex(RuntimeError,'not approved'):
     real_auto.prepared_backhaul_install('185.190.52.166','5.10.249.206',candidate)
    self.assertEqual(ssh.call_count,1)
    scp.assert_not_called()

 def test_explicit_approved_previous_foreign_rekeys_only_selected_vps(self):
  import hashlib
  from tempfile import TemporaryDirectory
  with TemporaryDirectory() as d:
   candidate=pathlib.Path(d)/'new.env'
   candidate.write_text("BH_TOKEN='not-a-secret'\n")
   expected=hashlib.sha256(b'fake-binary').hexdigest()
   with patch.object(real_auto.Path,'read_bytes',return_value=b'fake-binary'), \
        patch.object(sys.modules['dual'],'ssh',
                     side_effect=['REUSE_ACTIVE_OWNED_BACKHAUL',expected,
                                  'VERIFIED_PRIOR_BACKHAUL_REKEYED'],
                     create=True) as ssh, \
        patch('builtins.input',return_value='REUSE 185.190.52.166'), \
        patch.object(sys.modules['dual'],'scp',create=True) as scp:
    real_auto.prepared_backhaul_install('185.190.52.166','5.10.249.206',candidate)
    self.assertEqual(ssh.call_count,3)
    self.assertTrue(all(call.args[0]=='185.190.52.166' for call in ssh.call_args_list))
    code=ssh.call_args_list[-1].args[1]
    for required in ('BINARY_NOT_IDENTICAL_TO_IRAN','OLD_BACKHAUL_DOMAIN_OR_TLS_MISMATCH',
                     'DANTE_LOOPBACK_NOT_VERIFIED','BACKHAUL_SERVICE_OWNERSHIP_NOT_VERIFIED',
                     'os.replace(tmp,config)','disable'):
     self.assertIn(required,code)
    scp.assert_called_once()

 def test_unknown_foreign_install_is_never_reused(self):
  with patch.object(sys.modules['dual'],'ssh',side_effect=RuntimeError('UNKNOWN_PARTIAL_INSTALL'),
                    create=True), patch.object(sys.modules['dual'],'scp',create=True) as scp:
   with self.assertRaises(RuntimeError):
    real_auto.prepared_backhaul_install('82.152.141.33','5.10.249.206',
                                       pathlib.Path('/nonexistent'))
   scp.assert_not_called()


if __name__=='__main__':unittest.main()