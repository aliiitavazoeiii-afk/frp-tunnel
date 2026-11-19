#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("phases",ROOT/"dual-backhaul-latency-phases.py")
p=importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
class FakeSocket:
    def __init__(self,data,chunk=2):
        self.data=bytearray(data)
        self.chunk=chunk
    def recv(self,n):
        if not self.data:return b""
        k=min(self.chunk,n,len(self.data))
        chunk=bytes(self.data[:k])
        del self.data[:k]
        return chunk
class Tests(unittest.TestCase):
    def test_socks5_ipv4_connect_reply(self):
        s=FakeSocket(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x04\x50",chunk=1)
        p.connect_reply(s)
        self.assertEqual(s.data,bytearray())
    def test_socks5_domain_connect_reply(self):
        s=FakeSocket(b"\x05\x00\x00\x03\x03abc\x00\x50",chunk=1)
        p.connect_reply(s)
        self.assertEqual(s.data,bytearray())
    def test_socks5_ipv6_connect_reply(self):
        s=FakeSocket(b"\x05\x00\x00\x04"+b"\x00"*16+b"\x00\x50",chunk=1)
        p.connect_reply(s)
        self.assertEqual(s.data,bytearray())
    def test_socks5_error_rejected(self):
        with self.assertRaises(ValueError):
            p.connect_reply(FakeSocket(b"\x05\x05\x00\x01",chunk=1))
    def test_exact_read_fails_closed(self):
        with self.assertRaises(EOFError):
            p.recv_exact(FakeSocket(b"ab",chunk=1),4)
    def test_p95_nearest_rank(self):
        self.assertEqual(p.percentile([1,2,3,4,500],95),500)
        self.assertEqual(p.percentile([1,2,3,4,500],50),3)
if __name__=="__main__":
    unittest.main()
