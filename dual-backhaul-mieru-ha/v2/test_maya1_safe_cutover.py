#!/usr/bin/env python3
"""Unit tests of Maya1 HAProxy cutover guards; no live service mutations."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    obj=importlib.util.module_from_spec(spec)
    sys.modules[name]=obj
    spec.loader.exec_module(obj)
    return obj
m=load("maya1_cutover","maya1-safe-cutover.py")
ctrl=load("maya1_controller","maya1-next-controller.py")

class TestCutover(unittest.TestCase):
    def test_expected_identity_and_mutation_scope(self):
        self.assertEqual(m.IRAN,"94.184.4.38")
        self.assertEqual(m.NEW,{"backhaul":(21101,"82.152.132.159","bh1"),
                                "mieru":(21102,"152.237.230.77","bh2")})
        self.assertEqual(ctrl.PATHS,{"backhaul":21101,"mieru":21102})
        self.assertEqual(set(m.OLD),set(m.NEW))
        source=(ROOT/"maya1-safe-cutover.py").read_text()
        for forbidden in ("systemctl restart dual-ha-backhaul",
                          "systemctl restart x-ui",
                          "systemctl restart dual-ha-v2-gateway",
                          "systemctl stop dual-ha-mieru",
                          "systemctl disable dual-ha-mieru",
                          "iptables -F", "reboot", "docker compose"):
            self.assertNotIn(forbidden,source)

    def test_persistent_config_only_changes_two_local_ports(self):
        before="""global
  stats socket /run/dual-ha-v2/haproxy.sock mode 600 level admin
frontend iran_xray_local_outbound
  bind 127.0.0.1:18080
backend dual_egress
  balance leastconn
  server backhaul 127.0.0.1:21001 check disabled
  server mieru 127.0.0.1:21002 check disabled
"""
        new=m.persistent_text(before,m.OLD,{r:m.NEW[r][0] for r in m.NEW})
        self.assertEqual(new,before.replace(":21001",":21101").replace(":21002",":21102"))
        self.assertEqual(m.persistent_text(new,{r:m.NEW[r][0] for r in m.NEW},m.OLD),before)
        with self.assertRaises(RuntimeError):
            m.persistent_text("unexpected",m.OLD,{r:m.NEW[r][0] for r in m.NEW})

    def test_strict_live_addr_matching_and_controller_guard(self):
        rows={"backhaul":{"addr":"127.0.0.1:21101"},
              "mieru":{"addr":"127.0.0.1:21102"}}
        self.assertTrue(ctrl.runtime_targets_match(rows))
        self.assertFalse(ctrl.runtime_targets_match({
            "backhaul":{"addr":"127.0.0.1:21001"},
            "mieru":{"addr":"127.0.0.1:21002"}}))
        self.assertTrue(m.match_addr(rows["backhaul"],21101))
        self.assertFalse(m.match_addr(rows["backhaul"],21001))

    def test_staged_ip_and_roles_read_from_meta_not_old_bundle(self):
        with tempfile.TemporaryDirectory() as d:
            stage=Path(d)
            for role, (directory,ip) in ctrl.EXPECTED.items():
                (stage/directory).mkdir()
                (stage/directory/"state.json").write_text(
                    __import__("json").dumps({
                        "iran_ip":"94.184.4.38","role":directory,
                        "foreign_ip":ip,"staging_socks":ctrl.PATHS[role],
                        "mode":"staged"}))
            with patch.object(ctrl,"MAYA1_STAGE",stage):
                self.assertEqual(ctrl.expected_ip("backhaul"),"82.152.132.159")
                self.assertEqual(ctrl.expected_ip("mieru"),"152.237.230.77")
                (stage/"bh2"/"state.json").write_text("{}")
                self.assertEqual(ctrl.expected_ip("mieru"),"")

    def test_atomic_marker_and_restore_has_expected_backup_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage=Path(tmp)/"state";stage.mkdir()
            bkp=Path(tmp)/"backups";bkp.mkdir()
            save=bkp/"install-123";save.mkdir()
            with patch.object(m,"ROOT",stage),patch.object(m,"MARK",stage/"cutover-state.json"):
                m.save_marker(save,"prepared")
                value=__import__("json").loads((stage/"cutover-state.json").read_text())
                self.assertEqual(value["phase"],"prepared")
                self.assertEqual(value["iran"],"94.184.4.38")

if __name__=="__main__":
    unittest.main(verbosity=2)
