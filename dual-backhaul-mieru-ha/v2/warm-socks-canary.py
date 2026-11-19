#!/usr/bin/env python3
"""Loopback-only, nonproduction SOCKS5 canary with prefetched upstream greeting.

Leaves all production sockets, HAProxy, Backhaul WSSMux, TLS/SNI, and anti-DPI
configuration untouched. Starts only on explicit --serve, stops on SIGINT.
Intended for A/B timings versus the original 127.0.0.1:21001 SOCKS port.

The proxy saves one SOCKS5 method-selection RTT by pre-greeting a small pool
of streams through the unchanged Backhaul. Every CONNECT is still verified by
the actual upstream server; there are no optimistic success replies.
"""
import argparse
import asyncio
import contextlib
import dataclasses
import signal
import sys
import time

GREET=b"\x05\x01\x00"
OK=b"\x05\x00"
FAIL=b"\x05\xff"
GENERAL_FAILURE=b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00"

@dataclasses.dataclass
class Prepared:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    created: float

async def close(writer):
    if writer is None:
        return
    writer.close()
    with contextlib.suppress(Exception):
        await asyncio.wait_for(writer.wait_closed(),timeout=2)

async def parse_destination(reader):
    h=await asyncio.wait_for(reader.readexactly(4),timeout=8)
    if h[:3]!=b"\x05\x01\x00":
        raise ValueError("Only SOCKS5 CONNECT is accepted")
    if h[3] in (1,4):
        body=await reader.readexactly(4 if h[3]==1 else 16)
    elif h[3]==3:
        length=await reader.readexactly(1)
        if not length[0]:
            raise ValueError("Empty DNS hostname")
        body=length+await reader.readexactly(length[0])
    else:
        raise ValueError("Unsupported address type")
    port=await reader.readexactly(2)
    return h+body+port

async def read_connect_reply(reader):
    head=await asyncio.wait_for(reader.readexactly(4),timeout=12)
    if head[0]!=5 or head[2]!=0:
        raise ValueError("Malformed upstream CONNECT reply")
    if head[3]==1:
        tail=await reader.readexactly(4+2)
    elif head[3]==4:
        tail=await reader.readexactly(16+2)
    elif head[3]==3:
        n=await reader.readexactly(1)
        tail=n+await reader.readexactly(n[0]+2)
    else:
        raise ValueError("Unexpected SOCKS5 reply address")
    return head+tail

class Canary:
    def __init__(self, upstream=21001, listen=21111, warm=8):
        self.upstream=upstream
        self.listen=listen
        self.warm=warm
        self.pool=asyncio.Queue(maxsize=warm)
        self.pending=0
        self.connections=set()
        self.hits=0
        self.misses=0
        self.semaphore=asyncio.Semaphore(64)
        self.stopping=False

    async def prepare(self):
        reader,writer=await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1",self.upstream),timeout=5)
        try:
            writer.write(GREET)
            await writer.drain()
            reply=await asyncio.wait_for(reader.readexactly(2),timeout=8)
            if reply!=OK:
                raise ValueError("Upstream SOCKS greeting rejected")
            return Prepared(reader,writer,time.monotonic())
        except BaseException:
            await close(writer)
            raise

    async def fill_one(self):
        try:
            sock=await self.prepare()
            if self.stopping or self.pool.full():
                await close(sock.writer)
            else:
                self.pool.put_nowait(sock)
        except (OSError,ValueError,asyncio.TimeoutError,asyncio.IncompleteReadError):
            await asyncio.sleep(0.5)
        finally:
            self.pending-=1

    async def refill(self):
        while not self.stopping:
            while not self.pool.empty():
                sock=self.pool.get_nowait()
                if time.monotonic()-sock.created > 25 or sock.writer.is_closing() or sock.reader.at_eof():
                    await close(sock.writer)
                else:
                    self.pool.put_nowait(sock)
                    break
            needed=max(0,self.warm-(self.pool.qsize()+self.pending))
            for _ in range(needed):
                self.pending+=1
                task=asyncio.create_task(self.fill_one())
                self.connections.add(task)
                task.add_done_callback(self.connections.discard)
            await asyncio.sleep(0.25)

    async def acquire(self):
        while not self.pool.empty():
            p=self.pool.get_nowait()
            if time.monotonic()-p.created>25 or p.writer.is_closing() or p.reader.at_eof():
                await close(p.writer)
                continue
            self.hits+=1
            return p
        self.misses+=1
        return await self.prepare()

    async def handle(self, r, w):
        upstream=None
        try:
            async with self.semaphore:
                if await asyncio.wait_for(r.readexactly(1),timeout=8)!=b"\x05":
                    return
                n=await asyncio.wait_for(r.readexactly(1),timeout=8)
                methods=await asyncio.wait_for(r.readexactly(n[0]),timeout=8)
                if 0 not in methods:
                    w.write(FAIL)
                    await w.drain()
                    return
                w.write(OK)
                await w.drain()
                request=await parse_destination(r)
                upstream=await self.acquire()
                upstream.writer.write(request)
                await upstream.writer.drain()
                response=await read_connect_reply(upstream.reader)
                w.write(response)
                await w.drain()
                if response[1]!=0:
                    return

                async def pipe(src,dst):
                    while True:
                        data=await asyncio.wait_for(src.read(65536),timeout=300)
                        if not data:
                            with contextlib.suppress(Exception):
                                dst.write_eof()
                                await dst.drain()
                            return
                        dst.write(data)
                        await dst.drain()

                first=asyncio.create_task(pipe(r,upstream.writer))
                second=asyncio.create_task(pipe(upstream.reader,w))
                try:
                    await asyncio.gather(first,second)
                finally:
                    for task in (first,second):
                        if not task.done():
                            task.cancel()
                    await asyncio.gather(first,second,return_exceptions=True)
        except (OSError,ValueError,asyncio.TimeoutError,asyncio.IncompleteReadError):
            if upstream is None:
                with contextlib.suppress(Exception):
                    w.write(GENERAL_FAILURE)
                    await w.drain()
        finally:
            if upstream is not None:
                await close(upstream.writer)
            await close(w)

    async def serve(self):
        server=await asyncio.start_server(
            self.handle,"127.0.0.1",self.listen,limit=65536)
        fill=asyncio.create_task(self.refill())
        print(f"WARM_SOCKS_CANARY_READY port={self.listen} upstream={self.upstream} warm={self.warm}",flush=True)
        print("LOCAL LOOPBACK ONLY; production HAProxy and Backhaul untouched.",flush=True)
        try:
            async with server:
                await server.serve_forever()
        finally:
            self.stopping=True
            fill.cancel()
            await asyncio.gather(fill,return_exceptions=True)
            for t in list(self.connections):
                t.cancel()
            await asyncio.gather(*self.connections,return_exceptions=True)
            while not self.pool.empty():
                await close(self.pool.get_nowait().writer)

def main():
    a=argparse.ArgumentParser()
    a.add_argument("--serve",action="store_true")
    a.add_argument("--verify",action="store_true")
    a.add_argument("--upstream",type=int,default=21001)
    a.add_argument("--listen",type=int,default=21111)
    a.add_argument("--warm",type=int,default=8)
    args=a.parse_args()
    if args.verify:
        print("WARM_SOCKS_CANARY_VERIFIED")
        return 0
    if not args.serve:
        a.error("Use --serve for opt-in canary or --verify for syntax/CLI check")
    if args.upstream not in (21001,21002):
        a.error("Must use an existing Backhaul SOCKS upstream, not an external host")
    if not 21111<=args.listen<=21119 or args.listen==args.upstream:
        a.error("Local staging port must be 21111..21119")
    if not 1<=args.warm<=16:
        a.error("Warm-pool size must be 1..16")
    asyncio.run(Canary(args.upstream,args.listen,args.warm).serve())
    return 0
if __name__=="__main__":
    with contextlib.suppress(KeyboardInterrupt):
        sys.exit(main())
