#!/usr/bin/env python3
"""Offline regression tests: no networking, services or production state touched."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'dual-pool-guard.py'
spec = importlib.util.spec_from_file_location('dual_pool_guard', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

SAMPLE = """mode: rule
log-level: info
external-controller: "127.0.0.1:19090"
secret: "TEST-ONLY"
listeners:
  - name: dual-entry
    type: socks
    listen: 127.0.0.1
    port: 7990
    proxy: DUAL
proxies:
  - name: XUDP-TRUST
    type: socks5
    server: 127.0.0.1
    port: 7991
  - name: XUDP-MIERU
    type: socks5
    server: 127.0.0.1
    port: 7992
proxy-groups:
  - name: DUAL
    type: load-balance
    proxies:
      - XUDP-TRUST
      - XUDP-MIERU
    url: "https://www.gstatic.com/generate_204"
    interval: 120
    lazy: true
    strategy: sticky-sessions
rules:
  - MATCH,DUAL
"""

def result(ok):
    return {'ok': ok, 'confirmed_bad': not ok, 'web_seconds': 0.2,
            'telegram_seconds': 0.3}

class PoolGuardTests(unittest.TestCase):
    def test_remove_failed_mieru_preserves_all_other_config(self):
        out, old = guard.change_members(SAMPLE, ['XUDP-TRUST'])
        self.assertEqual(old, ['XUDP-TRUST', 'XUDP-MIERU'])
        self.assertIn('    strategy: sticky-sessions', out)
        self.assertIn('  - MATCH,DUAL', out)
        self.assertIn('  - name: XUDP-MIERU', out)
        self.assertIn('      - XUDP-TRUST\n', out)
        self.assertNotIn('      - XUDP-MIERU\n', out)

    def test_reject_remove_all(self):
        with self.assertRaises(RuntimeError):
            guard.change_members(SAMPLE, [])

    def test_reject_non_sticky_profile(self):
        with self.assertRaises(RuntimeError):
            guard.change_members(SAMPLE.replace('sticky-sessions', 'round-robin'),
                                 ['XUDP-TRUST'])

    def test_refuse_triple_pool(self):
        text = SAMPLE.replace('      - XUDP-MIERU\n', '      - XUDP-MIERU\n      - XUDP-NAIVE\n')
        with self.assertRaises(RuntimeError):
            guard.change_members(text, ['XUDP-TRUST'])

    def test_observe_mode_never_applies(self):
        with mock.patch.object(guard.CFG.__class__, 'read_text', return_value=SAMPLE), \
             mock.patch.object(guard, 'load_state', return_value={'quarantined': {}}), \
             mock.patch.object(guard, 'full_probe', return_value=result(False)), \
             mock.patch.object(guard, 'apply_members') as apply, \
             mock.patch.object(guard, 'atomic_write') as save:
            guard.execute('observe')
            apply.assert_not_called()
            save.assert_not_called()

    def test_quarantine_only_when_other_carrier_healthy(self):
        with mock.patch.object(guard.CFG.__class__, 'read_text', return_value=SAMPLE), \
             mock.patch.object(guard, 'load_state', return_value={'quarantined': {}}), \
             mock.patch.object(guard, 'full_probe',
                               side_effect=lambda role: result(role == 'trust')), \
             mock.patch.object(guard, 'apply_members') as apply, \
             mock.patch.object(guard, 'atomic_write'):
            guard.execute('auto')
            self.assertEqual(apply.call_args.args[1], ['XUDP-TRUST'])

    def test_never_quarantine_last_route_when_both_bad(self):
        with mock.patch.object(guard.CFG.__class__, 'read_text', return_value=SAMPLE), \
             mock.patch.object(guard, 'load_state', return_value={'quarantined': {}}), \
             mock.patch.object(guard, 'full_probe', return_value=result(False)), \
             mock.patch.object(guard, 'apply_members') as apply, \
             mock.patch.object(guard, 'atomic_write'):
            guard.execute('auto')
            self.assertEqual(apply.call_args.args[1],
                             ['XUDP-TRUST', 'XUDP-MIERU'])

    def test_controller_readback_is_required(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = Path(d) / 'dispatcher.yaml'
            cfg.write_text(SAMPLE)
            with mock.patch.object(guard, 'CFG', cfg), \
                 mock.patch.object(guard, 'STATE_DIR', Path(d)), \
                 mock.patch.object(guard, 'validate_config'), \
                 mock.patch.object(guard, 'api',
                     side_effect=[None, {'type': 'LoadBalance', 'all': ['XUDP-MIERU']}, None]):
                with self.assertRaises(RuntimeError):
                    guard.apply_members(SAMPLE, ['XUDP-TRUST'])
            self.assertEqual(cfg.read_text(), SAMPLE)

    def test_successful_controller_readback_persists_membership(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = Path(d) / 'dispatcher.yaml'
            cfg.write_text(SAMPLE)
            with mock.patch.object(guard, 'CFG', cfg), \
                 mock.patch.object(guard, 'STATE_DIR', Path(d)), \
                 mock.patch.object(guard, 'validate_config'), \
                 mock.patch.object(guard, 'api',
                     side_effect=[None, {'type': 'LoadBalance', 'all': ['XUDP-TRUST']}]):
                guard.apply_members(SAMPLE, ['XUDP-TRUST'])
            self.assertNotIn('      - XUDP-MIERU\n', cfg.read_text())

if __name__ == '__main__':
    unittest.main()
