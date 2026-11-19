#!/usr/bin/env python3
"""End-to-end tests without network access and without any live tunnel changes."""
import asyncio
import importlib.util
from pathlib import Path
import unittest

SRC=Path(__file__).resolve().parent/"warm-socks-canary.py"
spec=importlib.util.spec_from_file_location("warmcanary",SRC)
m=importlib.util.module_from_spec(spec)
import sys
sys.modules["warmcanary"]=m
spec.loader.exec_module(m)

class Tests(unittest.IsolatedAsyncioTestCase):
    async def test_parse_destination_domain_ipv4_ipv6(self):
        for request in (
            b"\x05\x01\x00\x03\x03abc\x01\xbb",
            b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x50",
            b"\x05\x01\x00\x04"+b"\x00"*16+b"\x01\xbb",
        ):
            r=asyncio.StreamReader()
            r.feed_data(request)
            r.feed_eof()
            self.assertEqual(await m.parse_destination(r),request)

    async def test_upstream_connect_reply_all_types(self):
        for response in (
            b"\x05\x00\x00\x03\x03abc\x01\xbb",
            b"\x05\x00\x00\x01\x7f\x00\x00\x01\x01\xbb",
            b"\x05\x00\x00\x04"+b"\x00"*16+b"\x00\x00",
        ):
            r=asyncio.StreamReader()
            r.feed_data(response); r.feed_eof()
            self.assertEqual(await m.read_connect_reply(r),response)

    async def test_local_greeting_prewarms_and_data_roundtrip(self):
        accepted=[]
        async def fake_upstream(reader,writer):
            try:
                self.assertEqual(await reader.readexactly(3),m.GREET)
                writer.write(m.OK)
                await writer.drain()
                hdr=await reader.readexactly(4)
                self.assertEqual(hdr,b"\x05\x01\x00\x03")
                n=(await reader.readexactly(1))[0]
                target=await reader.readexactly(n+2)
                self.assertEqual(target,b"example.com\x01\xbb")
                accepted.append(True)
                writer.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                await writer.drain()
                self.assertEqual(await reader.readexactly(4),b"PING")
                writer.write(b"PONG");await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()
        upstream=await asyncio.start_server(fake_upstream,"127.0.0.1",0)
        port=upstream.sockets[0].getsockname()[1]
        canary=m.Canary(upstream=port,listen=21111,warm=1)
        prepared=await canary.prepare()
        canary.pool.put_nowait(prepared)
        downstream=await asyncio.start_server(canary.handle,"127.0.0.1",0)
        dport=downstream.sockets[0].getsockname()[1]
        reader,writer=await asyncio.open_connection("127.0.0.1",dport)
        try:
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            self.assertEqual(await reader.readexactly(2),m.OK)
            req=b"\x05\x01\x00\x03\x0bexample.com\x01\xbb"
            writer.write(req); await writer.drain()
            self.assertEqual(await reader.readexactly(10),
                             b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            writer.write(b"PING"); await writer.drain()
            self.assertEqual(await reader.readexactly(4),b"PONG")
            self.assertEqual(canary.hits,1)
            self.assertEqual(len(accepted),1)
        finally:
            writer.close();await writer.wait_closed()
            downstream.close();await downstream.wait_closed()
            upstream.close();await upstream.wait_closed()

    async def test_invalid_address_rejected(self):
        reader=asyncio.StreamReader()
        reader.feed_data(b"\x05\x01\x00\xff")
        reader.feed_eof()
        with self.assertRaises(ValueError):
            await m.parse_destination(reader)

if __name__=="__main__":
    unittest.main()
