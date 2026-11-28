#!/usr/bin/env python3
"""Offline regression tests; do not require root, network, systemd or VPS."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent
def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

monitor = load("solo_monitor", "solo_monitor.py")
preflight = load("maya1_preflight", "maya1_preflight.py")

class MonitorTests(unittest.TestCase):
    def test_first_failure_no_switch(self):
        state, trigger = monitor.transition({}, False, now="2026-11-28T20:00:00+00:00")
        self.assertEqual(1, state["failures"])
        self.assertFalse(trigger)
        self.assertEqual("primary", state["route"])

    def test_second_failure_60_seconds_later_triggers(self):
        state, _ = monitor.transition({}, False, now="2026-11-28T20:00:00+00:00")
        state, trigger = monitor.transition(state, False, now="2026-11-28T20:01:00+00:00")
        self.assertTrue(trigger)
        self.assertEqual("switch_requested", state["route"])

    def test_second_failure_too_fast_does_not_trigger(self):
        state, _ = monitor.transition({}, False, now="2026-11-28T20:00:00+00:00")
        state, trigger = monitor.transition(state, False, now="2026-11-28T20:00:01+00:00")
        self.assertFalse(trigger)
        self.assertEqual(1, state["failures"])

    def test_success_resets_failures(self):
        state, _ = monitor.transition({}, False, now="2026-11-28T20:00:00+00:00")
        state, _ = monitor.transition(state, True, now="2026-11-28T20:01:00+00:00")
        state, trigger = monitor.transition(state, False, now="2026-11-28T20:02:00+00:00")
        self.assertFalse(trigger)
        self.assertEqual(1, state["failures"])

    def test_does_not_auto_fail_back_from_standby(self):
        state, trigger = monitor.transition({"route": "standby", "failures": 1},
                                            False, now="2026-11-28T20:01:00+00:00")
        self.assertFalse(trigger)
        self.assertEqual("standby", state["route"])

    def test_actions_disabled_by_default(self):
        node = {"id": "maya1", "primary_egress_ip": "82.152.132.159",
                "standby_egress_ip": "1.1.1.1",
                "switch_command": ["/bin/false"]}
        first = monitor.perform(node, {}, None, False, "2026-11-28T20:00:00+00:00")
        second = monitor.perform(node, first, None, False, "2026-11-28T20:01:00+00:00")
        self.assertEqual("primary", second["route"])
        self.assertEqual("OBSERVE_ONLY_TWO_FAILURES", second["last_action"])

    def test_armed_requires_durable_latch_callback(self):
        node = {"id": "maya1", "primary_egress_ip": "82.152.132.159",
                "standby_egress_ip": "1.1.1.1",
                "switch_command": ["/bin/false"]}
        prev, _ = monitor.transition({}, False, now="2026-11-28T20:00:00+00:00")
        with self.assertRaises(monitor.Guard):
            monitor.perform(node, prev, None, True, "2026-11-28T20:01:00+00:00")

    def test_armed_persists_before_action(self):
        node = {"id": "maya1", "primary_egress_ip": "82.152.132.159",
                "standby_egress_ip": "1.1.1.1",
                "switch_command": ["/bin/true"]}
        prev, _ = monitor.transition({}, False, now="2026-11-28T20:00:00+00:00")
        saved = []
        after = monitor.perform(node, prev, None, True,
                                "2026-11-28T20:01:00+00:00",
                                persist=lambda current: saved.append(dict(current)))
        self.assertEqual("switch_requested", saved[0]["route"])
        self.assertEqual("COMMAND_ACCEPTED_UNVERIFIED", after["last_action"])

    def test_accepted_unverified_action_not_repeated(self):
        state, _ = monitor.transition({"route": "switch_requested", "failures": 2},
                                      False, now="2026-11-28T20:02:00+00:00")
        self.assertEqual("switch_requested", state["route"])

class PreflightTests(unittest.TestCase):
    def test_allowlist_has_known_maya1_ports(self):
        self.assertEqual({21001, 21101}, preflight.PORT_ALLOWLIST)
    def test_no_hidden_apply_operation(self):
        # The audit/snapshot tool must not gain a production switch operation.
        self.assertFalse(hasattr(preflight, "apply"))

if __name__ == "__main__":
    unittest.main()
