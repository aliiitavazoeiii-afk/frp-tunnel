#!/usr/bin/env python3
"""Tests for read-only adaptive model and isolated TCP/UDP SOCKS canary."""
import asyncio
import importlib.util
import json
import pathlib
import socket
import struct
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent


def load(file, name):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

model = load("nm-adaptive-core.py", "nm_adaptive_core_test")
canary = load("nm-adaptive-canary.py", "nm_adaptive_canary_test")


class ModelTest(unittest.TestCase):
    def test_roles(self):
        self.assertEqual(model.roles_from_chain(["DUAL", "XUDP-TRUST"]), "NAIVE")
        self.assertEqual(model.roles_from_chain(["XUDP-MIERU"]), "MIERU")
        self.assertEqual(model.roles_from_chain(["DIRECT"]), "OTHER")
        self.assertEqual(model.roles_from_chain(["XUDP-TRUST", "XUDP-MIERU"]), "OTHER")

    def test_sample_baseline_and_deltas(self):
        s = model.CounterSampler()
        a = {"id": "a", "start": "t", "chains": ["XUDP-TRUST"], "upload": 20, "download": 30}
        self.assertEqual(s.sample([a])[0]["NAIVE"], 0)
        b = dict(a, download=70)
        self.assertEqual(s.sample([b])[0]["NAIVE"], 40)
        self.assertEqual(s.sample([b])[0]["NAIVE"], 0)
        self.assertEqual(s.sample([])[0]["NAIVE"], 0)
        self.assertEqual(s.sample([b])[0]["NAIVE"], 0)  # first seen again: historic bytes excluded
        self.assertEqual(s.sample([dict(b, download=2)])[0]["NAIVE"], 0)
        self.assertEqual(s.sample([dict(b, download=12)])[0]["NAIVE"], 10)

    def test_new_sessions_do_not_import_existing_bytes(self):
        s = model.CounterSampler()
        baseline = {"id":"old", "start":"1", "chains":["XUDP-TRUST"],
                    "upload":0, "download":100_000_000}
        s.sample([baseline])
        fresh = {"id":"new", "start":"2", "chains":["XUDP-MIERU"],
                 "upload":0, "download":500_000_000}
        first, counts, _ = s.sample([baseline, fresh])
        self.assertEqual(first["MIERU"], 0)
        self.assertEqual(counts["MIERU"], 1)
        again = dict(fresh, download=500_001_000)
        delta, _, _ = s.sample([baseline, again])
        self.assertEqual(delta["MIERU"], 1000)

    def test_window_and_policy(self):
        roll = model.RollingTraffic(600)
        roll.add(100, {"NAIVE": 10_000_000, "MIERU": 90_000_000})
        roll.add(300, {"NAIVE": 1_000_000, "MIERU": 1_000_000})
        weights, reason = model.policy(roll.totals(300), {"NAIVE": True, "MIERU": True}, roll.span())
        self.assertEqual(reason, "ADAPTIVE")
        self.assertGreater(weights["NAIVE"], 0.75)
        self.assertLessEqual(weights["NAIVE"], 0.8)
        weights, reason = model.policy(roll.totals(300), {"NAIVE": False, "MIERU": True}, 600)
        self.assertEqual(weights, {"NAIVE": 0.0, "MIERU": 1.0})
        self.assertEqual(reason, "NAIVE_UNHEALTHY")
        self.assertEqual(model.policy({}, {"NAIVE": True, "MIERU": True}, 20)[1], "WARMUP")
        roll.add(901, {"NAIVE": 2, "MIERU": 3})
        self.assertEqual(roll.totals(901)["NAIVE"], 2)

    def test_shadow_disagreement_refuses_unverified_failover(self):
        weights, reason = model.shadow_policy(
            {"NAIVE": 10_000_000, "MIERU": 90_000_000},
            {"NAIVE": False, "MIERU": True}, 600)
        self.assertEqual(weights, {"NAIVE": 0.0, "MIERU": 0.0})
        self.assertEqual(reason, "HEALTH_UNVERIFIED")
        weights, reason = model.shadow_policy(
            {"NAIVE": 10_000_000, "MIERU": 90_000_000},
            {"NAIVE": True, "MIERU": True}, 600)
        self.assertEqual(reason, "ADAPTIVE")
        self.assertGreater(weights["NAIVE"], 0.5)

    def test_smooth_chooser(self):
        c = model.SmoothChooser()
        x = [c.choose({"NAIVE": 0.7, "MIERU": 0.3}) for _ in range(1000)]
        self.assertEqual(x.count("NAIVE"), 700)
        self.assertEqual(c.choose({"NAIVE": 0, "MIERU": 0}), None)


class CanaryTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.orig_policy = canary.POLICY
        self.orig_upstream = dict(canary.UPSTREAM)
        canary.POLICY = pathlib.Path(self.tmp.name) / "status.json"
        canary.POLICY.write_text(json.dumps({
            "schema": 1, "timestamp": time.time(),
            "reason": "ADAPTIVE",
            "weights": {"NAIVE": 1.0, "MIERU": 0.0},
            "healthy": {"NAIVE": True, "MIERU": True}
        }))
        self.server = None
        self.backend_server = None

    async def asyncTearDown(self):
        canary.POLICY = self.orig_policy
        canary.UPSTREAM = self.orig_upstream
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        if self.backend_server:
            self.backend_server.close()
            await self.backend_server.wait_closed()
        self.tmp.cleanup()

    async def test_tcp_connect_localhost_canary(self):
        async def upstream(reader, writer):
            try:
                self.assertEqual(await reader.readexactly(3), b"\x05\x01\x00")
                writer.write(b"\x05\x00")
                await writer.drain()
                request = await reader.readexactly(4)
                self.assertEqual(request[:3], b"\x05\x01\x00")
                if request[3] == 3:
                    size = (await reader.readexactly(1))[0]
                    await reader.readexactly(size)
                elif request[3] == 1:
                    await reader.readexactly(4)
                else:
                    await reader.readexactly(16)
                await reader.readexactly(2)
                writer.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                await writer.drain()
                value = await reader.readexactly(8)
                writer.write(value)
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()
        self.backend_server = await asyncio.start_server(upstream, "127.0.0.1", 0)
        port = self.backend_server.sockets[0].getsockname()[1]
        canary.UPSTREAM["NAIVE"] = ("127.0.0.1", port)
        self.server = await asyncio.start_server(canary.handle, "127.0.0.1", 0)
        port = self.server.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        try:
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            self.assertEqual(await asyncio.wait_for(reader.readexactly(2), 3), b"\x05\x00")
            writer.write(b"\x05\x01\x00\x03\x0bexample.com\x00\x50")
            await writer.drain()
            response = await asyncio.wait_for(reader.readexactly(10), 3)
            self.assertEqual(response[1], 0)
            writer.write(b"12345678")
            await writer.drain()
            self.assertEqual(await asyncio.wait_for(reader.readexactly(8), 3), b"12345678")
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_udp_associate_localhost_canary(self):
        loop = asyncio.get_running_loop()
        backend_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        backend_udp.setblocking(False)
        backend_udp.bind(("127.0.0.1", 0))

        async def echo_udp():
            while True:
                data, addr = await loop.sock_recvfrom(backend_udp, 65535)
                await loop.sock_sendto(backend_udp, data, addr)

        echo_task = asyncio.create_task(echo_udp())

        async def fake_backend(reader, writer):
            try:
                self.assertEqual(await reader.readexactly(3), b"\x05\x01\x00")
                writer.write(b"\x05\x00")
                await writer.drain()
                self.assertEqual(await reader.readexactly(10),
                                 b"\x05\x03\x00\x01" + b"\x00"*6)
                port_bytes = struct.pack("!H", backend_udp.getsockname()[1])
                writer.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01" + port_bytes)
                await writer.drain()
                await reader.read()
            finally:
                writer.close()
                await writer.wait_closed()

        try:
            self.backend_server = await asyncio.start_server(fake_backend, "127.0.0.1", 0)
            canary.UPSTREAM["NAIVE"] = ("127.0.0.1", self.backend_server.sockets[0].getsockname()[1])
            self.server = await asyncio.start_server(canary.handle, "127.0.0.1", 0)
            reader, writer = await asyncio.open_connection(
                "127.0.0.1", self.server.sockets[0].getsockname()[1])
            try:
                writer.write(b"\x05\x01\x00")
                await writer.drain()
                self.assertEqual(await reader.readexactly(2), b"\x05\x00")
                writer.write(b"\x05\x03\x00\x01" + b"\x00"*6)
                await writer.drain()
                response = await asyncio.wait_for(reader.readexactly(10), 3)
                self.assertEqual(response[1], 0)
                port = struct.unpack("!H", response[-2:])[0]
                packet = b"\0\0\0\1" + socket.inet_aton("1.1.1.1") + struct.pack("!H", 53) + b"test-udp-packet"
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as cli_udp:
                    cli_udp.bind(("127.0.0.1", 0))
                    cli_udp.setblocking(False)
                    await loop.sock_sendto(cli_udp, packet, ("127.0.0.1", port))
                    response, _ = await asyncio.wait_for(loop.sock_recvfrom(cli_udp, 4096), 3)
                    self.assertEqual(response, packet)
            finally:
                writer.close()
                await writer.wait_closed()
        finally:
            echo_task.cancel()
            await asyncio.gather(echo_task, return_exceptions=True)
            backend_udp.close()

    async def test_fail_closed_on_stale_telemetry(self):
        canary.POLICY.write_text(json.dumps({
            "schema": 1, "timestamp": time.time()-100,
            "reason": "ADAPTIVE",
            "weights": {"NAIVE": 0.5, "MIERU": 0.5},
            "healthy": {"NAIVE": True, "MIERU": True}
        }))
        self.server = await asyncio.start_server(canary.handle, "127.0.0.1", 0)
        port = self.server.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        try:
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            self.assertEqual(await reader.readexactly(2), b"\x05\x00")
            writer.write(b"\x05\x01\x00\x01\x01\x01\x01\x01\x00\x50")
            await writer.drain()
            self.assertEqual((await reader.readexactly(10))[1], 1)
        finally:
            writer.close()
            await writer.wait_closed()


if __name__ == "__main__":
    unittest.main()
