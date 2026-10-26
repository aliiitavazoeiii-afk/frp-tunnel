#!/usr/bin/env python3
"""Local-only SOCKS5 adaptive CANARY, TCP CONNECT + UDP ASSOCIATE.

This is NOT the production x-ui upstream. Binds 127.0.0.1:17990 only.
Each session pins exactly one carrier for its full lifetime.
For staging and controlled load testing, not yet certified for 1000-user production.
"""
import asyncio
import importlib.util
import ipaddress
import json
import pathlib
import signal
import socket
import struct
import sys
import time

LIB = pathlib.Path(__file__).with_name("nm-adaptive-core.py")
spec = importlib.util.spec_from_file_location("nm_adaptive_core", LIB)
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
STATE = core.STATE
POLICY = STATE / "status.json"
UPSTREAM = {"NAIVE": ("127.0.0.1", 7991), "MIERU": ("127.0.0.1", 7992)}
MAX_SESSIONS = 100
SEMAPHORE = asyncio.Semaphore(MAX_SESSIONS)
CHOOSER = core.SmoothChooser()
METRICS = {"TCP": {"NAIVE": 0, "MIERU": 0}, "UDP": {"NAIVE": 0, "MIERU": 0},
           "sessions": {"NAIVE": 0, "MIERU": 0}, "failures": 0}
LOCAL_LISTENER = ("127.0.0.1", 17990)


def pick():
    """Refuse NEW sessions if health or controller data cannot be verified."""
    try:
        status = json.loads(POLICY.read_text())
        if (status.get("schema") != 1 or time.time() - float(status["timestamp"]) > 8 or
                status["reason"] == "CONTROLLER_ERROR"):
            return None
        healthy = status["healthy"]
        weights = dict(status["weights"])
        for role in core.ROLES:
            if healthy.get(role) is not True:
                weights[role] = 0
        return CHOOSER.choose(weights)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def reply(code, port=0):
    return b"\x05" + bytes([code]) + b"\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", port)


async def response(reader):
    h = await reader.readexactly(4)
    if h[:1] != b"\x05":
        raise ValueError("backend not SOCKS5")
    atyp = h[3]
    if atyp == 1:
        body = await reader.readexactly(4)
    elif atyp == 3:
        size = await reader.readexactly(1)
        body = size + await reader.readexactly(size[0])
    elif atyp == 4:
        body = await reader.readexactly(16)
    else:
        raise ValueError("backend bad ATYP")
    port = await reader.readexactly(2)
    return h + body + port


async def backend(role):
    reader, writer = await asyncio.wait_for(asyncio.open_connection(*UPSTREAM[role]), 7)
    try:
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(2), 7) != b"\x05\x00":
            raise RuntimeError("backend SOCKS5 no-auth rejected")
        return reader, writer
    except BaseException:
        writer.close()
        await writer.wait_closed()
        raise


async def pump(reader, writer, role, direction):
    try:
        while True:
            data = await reader.read(32768)
            if not data:
                try:
                    writer.write_eof()
                except (NotImplementedError, OSError, AttributeError):
                    pass
                break
            writer.write(data)
            await writer.drain()
            METRICS["TCP"][role] += len(data)
    except (OSError, ConnectionError):
        pass


async def tcp_tunnel(client_r, client_w, hostreq, role):
    up_r, up_w = await backend(role)
    try:
        up_w.write(b"\x05\x01\x00" + hostreq)
        await up_w.drain()
        result = await asyncio.wait_for(response(up_r), 12)
        client_w.write(result)
        await client_w.drain()
        if result[1] != 0:
            return
        p1 = asyncio.create_task(pump(client_r, up_w, role, "upload"))
        p2 = asyncio.create_task(pump(up_r, client_w, role, "download"))
        pending = {p1, p2}
        try:
            await asyncio.wait(pending, return_when=asyncio.ALL_COMPLETED)
        finally:
            for p in pending:
                p.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
    finally:
        up_w.close()
        await up_w.wait_closed()


async def udp_tunnel(client_r, client_w, role):
    up_r, up_w = await backend(role)
    local_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    remote_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    local_sock.setblocking(False)
    remote_sock.setblocking(False)
    try:
        up_w.write(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        await up_w.drain()
        result = await asyncio.wait_for(response(up_r), 12)
        if result[1] != 0:
            client_w.write(reply(result[1]))
            await client_w.drain()
            return
        atyp = result[3]
        start = 4
        if atyp == 1:
            ip = socket.inet_ntoa(result[start:start+4])
            ptr = start+4
        elif atyp == 3:
            size = result[start]
            ip = result[start+1:start+1+size].decode()
            ptr = start+1+size
        elif atyp == 4:
            ip = socket.inet_ntop(socket.AF_INET6, result[start:start+16])
            ptr = start+16
        else:
            raise ValueError("backend UDP associate invalid bind address")
        backend_port = struct.unpack("!H", result[ptr:ptr+2])[0]
        if ip in ("0.0.0.0", "::"):
            ip = UPSTREAM[role][0]
        resolved = ipaddress.ip_address(ip)
        if resolved.version != 4 or not resolved.is_loopback or backend_port == 0:
            raise ValueError("backend UDP relay not loopback IPv4, refuse")
        dest = (str(resolved), backend_port)
        local_sock.bind(("127.0.0.1", 0))
        remote_sock.bind(("127.0.0.1", 0))
        client_w.write(reply(0, local_sock.getsockname()[1]))
        await client_w.drain()
        loop = asyncio.get_running_loop()
        peer = client_w.get_extra_info("peername")
        expected_ip = peer[0]
        allowed_client = None

        async def client_to_backend():
            nonlocal allowed_client
            while True:
                data, src = await loop.sock_recvfrom(local_sock, 65535)
                if src[0] != expected_ip or len(data) < 10 or data[:3] != b"\x00\x00\x00":
                    continue
                if allowed_client is None:
                    allowed_client = src
                if src != allowed_client:
                    continue
                await loop.sock_sendto(remote_sock, data, dest)
                METRICS["UDP"][role] += len(data)

        async def backend_to_client():
            while True:
                data, src = await loop.sock_recvfrom(remote_sock, 65535)
                if src != dest or allowed_client is None:
                    continue
                await loop.sock_sendto(local_sock, data, allowed_client)
                METRICS["UDP"][role] += len(data)

        tasks = [asyncio.create_task(client_to_backend()),
                 asyncio.create_task(backend_to_client()),
                 asyncio.create_task(client_r.read(1)),
                 asyncio.create_task(up_r.read(1))]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        local_sock.close()
        remote_sock.close()
        up_w.close()
        await up_w.wait_closed()


async def handle(reader, writer):
    acquired = False
    try:
        # localhost is a non-public staging interface; never admit remote clients.
        if writer.get_extra_info("peername")[0] not in ("127.0.0.1", "::1"):
            return
        if SEMAPHORE.locked():
            return
        await asyncio.wait_for(SEMAPHORE.acquire(), timeout=0.5)
        acquired = True
        h = await asyncio.wait_for(reader.readexactly(2), 7)
        if h[0] != 5 or not (0 < h[1] <= 16):
            return
        methods = await asyncio.wait_for(reader.readexactly(h[1]), 7)
        if 0 not in methods:
            writer.write(b"\x05\xff")
            await writer.drain()
            return
        writer.write(b"\x05\x00")
        await writer.drain()
        req = await asyncio.wait_for(reader.readexactly(4), 7)
        if req[0] != 5 or req[2] != 0 or req[1] not in (1, 3):
            writer.write(reply(7))
            await writer.drain()
            return
        if req[3] == 1:
            addr = await reader.readexactly(4)
        elif req[3] == 3:
            size = await reader.readexactly(1)
            if not (1 <= size[0] <= 253):
                writer.write(reply(8));await writer.drain();return
            addr = size + await reader.readexactly(size[0])
        elif req[3] == 4:
            addr = await reader.readexactly(16)
        else:
            writer.write(reply(8))
            await writer.drain()
            return
        port = await reader.readexactly(2)
        role = pick()
        if role is None:
            writer.write(reply(1))
            await writer.drain()
            return
        METRICS["sessions"][role] += 1
        if req[1] == 1:
            await tcp_tunnel(reader, writer, req[3:4] + addr + port, role)
        else:
            await udp_tunnel(reader, writer, role)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, OSError, ConnectionError,
            ValueError, RuntimeError):
        METRICS["failures"] += 1
    finally:
        if acquired:
            SEMAPHORE.release()
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, OSError):
            pass


async def main():
    if not POLICY.is_file():
        raise SystemExit("Refusing start: no healthy shadow status yet")
    server = await asyncio.start_server(handle, *LOCAL_LISTENER, backlog=128, limit=65536)
    print("ADAPTIVE TCP+UDP CANARY: SOCKS5 127.0.0.1:17990 ONLY. Production :7990 unchanged.", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
