#!/usr/bin/env python3
"""Offline safety checks for Xray Mieru native UDP shadow candidate."""
import importlib.util,pathlib,unittest
spec=importlib.util.spec_from_file_location("canary",pathlib.Path(__file__).with_name("nm-mieru-native-udp-canary.py"))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.data={"log":{"loglevel":"warning"},"inbounds":[
            {"tag":"trust-in","listen":"127.0.0.1","port":7991,"protocol":"socks",
             "settings":{"auth":"noauth","udp":True}},
            {"tag":"mieru-in","listen":"127.0.0.1","port":7992,"protocol":"socks",
             "settings":{"auth":"noauth","udp":True}}],
            "outbounds":[
                {"tag":"xudp-trust","protocol":"vless","settings":{"id":"dummy"}},
                {"tag":"xudp-mieru","protocol":"vless","settings":{"id":"dummy"}},
                {"tag":"carrier-mieru","protocol":"socks","settings":{"address":"127.0.0.1","port":7994}}],
            "routing":{"rules":[{"inboundTag":["mieru-in"],"outboundTag":"xudp-mieru"}]}}
    def test_isolates_only_mieru_inbound_and_native_outbound(self):
        out=m.candidate_configuration(self.data)
        self.assertEqual(len(out["inbounds"]),1)
        self.assertEqual(out["inbounds"][0]["port"],17992)
        self.assertEqual(len(out["outbounds"]),1)
        self.assertEqual(out["outbounds"][0]["tag"],"carrier-mieru")
        self.assertEqual(out["routing"]["rules"][0]["network"],"tcp,udp")
        self.assertNotIn("xudp-mieru",str(out))
        self.assertEqual(self.data["inbounds"][1]["port"],7992,"never alter live structure")
    def test_rejects_unexpected_live_proxy(self):
        self.data["outbounds"][-1]["settings"]["port"]=8000
        with self.assertRaisesRegex(ValueError,"differs"):
            m.candidate_configuration(self.data)
    def test_rejects_missing_udp(self):
        self.data["inbounds"][1]["settings"]["udp"]=False
        with self.assertRaisesRegex(ValueError,"differs"):
            m.candidate_configuration(self.data)
if __name__=="__main__":
    unittest.main(verbosity=2)
