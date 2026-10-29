#!/usr/bin/env python3
"""Small pure-protocol tests for read-only Mieru UDP diagnostics (no real sockets)."""
import importlib.util, pathlib, struct, unittest
spec=importlib.util.spec_from_file_location("mieru_udp",pathlib.Path(__file__).with_name("nm-mieru-udp-diagnose.py"))
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class UDPDiagnosticsTests(unittest.TestCase):
    def test_dns_validates_transaction_qr_and_answer(self):
        data=struct.pack("!HHHHHH",451,0x8180,1,1,0,0)
        self.assertTrue(m.dns_check_reply(data,451))
        with self.assertRaisesRegex(RuntimeError,"transaction"):
            m.dns_check_reply(data,452)
        with self.assertRaisesRegex(RuntimeError,"not a DNS"):
            m.dns_check_reply(struct.pack("!HHHHHH",451,0x0100,1,1,0,0),451)
        with self.assertRaisesRegex(RuntimeError,"no A answers"):
            m.dns_check_reply(struct.pack("!HHHHHH",451,0x8180,1,0,0,0),451)
    def test_socks_udp_ipv4_unpack(self):
        dns=struct.pack("!HHHHHH",451,0x8180,1,1,0,0)
        raw=b"\0\0\0\1"+bytes((1,1,1,1))+struct.pack("!H",53)+dns
        self.assertEqual(m.parse_udp_packet(raw),dns)
    def test_socks_udp_domain_unpack(self):
        dns=struct.pack("!HHHHHH",451,0x8180,1,1,0,0)
        raw=b"\0\0\0\3"+bytes((3,))+b"dns"+struct.pack("!H",53)+dns
        self.assertEqual(m.parse_udp_packet(raw),dns)
    def test_socks_udp_ipv6_unpack(self):
        dns=struct.pack("!HHHHHH",451,0x8180,1,1,0,0)
        raw=b"\0\0\0\4"+bytes(16)+struct.pack("!H",53)+dns
        self.assertEqual(m.parse_udp_packet(raw),dns)
    def test_udp_rejects_fragment(self):
        with self.assertRaisesRegex(RuntimeError,"fragmented"):
            m.parse_udp_packet(b"\0\0\1\1"+bytes(4)+b"\0\x35"+bytes(12))
if __name__=="__main__":
    unittest.main(verbosity=2)
