#!/usr/bin/env python3
"""Offline structural checks for Trust fresh read-only shadow."""
import importlib.util
import pathlib
import unittest
from unittest import mock

p=pathlib.Path(__file__).with_name("trust-fresh-client-diagnose.py")
s=importlib.util.spec_from_file_location("trust_fresh",p)
m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
class ShadowTests(unittest.TestCase):
    SAMPLE='''loglevel = "info"
vpn_mode = "general"
[endpoint]
hostname = "example.invalid"
addresses = ["192.0.2.1:443"]
username = "secret-test"
password = "not-a-real-password"
upstream_protocol = "http2"
skip_verification = false
[listener.socks]
address = "127.0.0.1:7993"
'''
    def test_only_local_listener_changes(self):
        new=m.candidate_config(self.SAMPLE)
        self.assertEqual(new,self.SAMPLE.replace(m.ORIG_LINE,m.NEW_LINE))
        self.assertEqual(new.count("username = "),1)
        self.assertEqual(new.count("password = "),1)
    def test_rejects_missing_listener(self):
        with self.assertRaises(ValueError):
            m.candidate_config(self.SAMPLE.replace(m.ORIG_LINE,"address = \"0.0.0.0:7993\""))
    def test_rejects_duplicate_listener(self):
        with self.assertRaises(ValueError):
            m.candidate_config(self.SAMPLE+m.ORIG_LINE)
    def test_rejects_disabled_certificate_verification(self):
        with self.assertRaises(ValueError):
            m.candidate_config(self.SAMPLE.replace("skip_verification = false","skip_verification = true"))
    def test_rejects_different_transport(self):
        with self.assertRaises(ValueError):
            m.candidate_config(self.SAMPLE.replace("upstream_protocol = \"http2\"","upstream_protocol = \"http3\""))

if __name__=="__main__":unittest.main(verbosity=2)
