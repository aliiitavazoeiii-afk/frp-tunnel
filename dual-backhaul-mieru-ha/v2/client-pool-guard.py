#!/usr/bin/env python3
"""Apply bounded concurrent WSSMux physical-connection pool guard to the
pinned Backhaul 0.7.2-derived source AFTER existing anti-DPI patches.
Patch ONLY internal/client/transport/wsmux.go.
No TLS, WS URL/headers/SNI, heartbeat, frame or cipher changes.
"""
from pathlib import Path
import sys

ROOT=Path(sys.argv[1]).resolve()
PATH=ROOT/"internal/client/transport/wsmux.go"

def change(data, before, after, label):
    n=data.count(before)
    if n!=1:
        raise RuntimeError(f"{label}: expected exactly one anchor, got {n}")
    return data.replace(before,after,1)

source=PATH.read_text()
if "func (c *WsMuxTransport) maxLivePool() int32" in source:
    raise RuntimeError("Pool guard was already applied")

source=change(source,
    "\tpoolConnections int32\n\tloadConnections int32\n",
    "\tpoolConnections int32\n\tloadConnections int32\n\tpoolSlots       int32 // established + in-flight; atomically bounded\n",
    "slot declaration")

source=change(source,
    "\tpoolConnections: 0,\n\t\tloadConnections: 0,\n",
    "\tpoolConnections: 0,\n\t\tloadConnections: 0,\n\t\tpoolSlots:       0,\n",
    "constructor")

source=change(source,
    "\tc.poolConnections = 0\n\tc.loadConnections = 0\n",
    "\tc.poolConnections = 0\n\tc.loadConnections = 0\n\tatomic.StoreInt32(&c.poolSlots, 0)\n",
    "restart")

helpers=r'''
// maxLivePool is a finite cap on concurrent physical reverse connections.
// The existing mux_con stream limit is unchanged. With connection_pool=16
// this permits up to 64 physical channels, enough for 16*64=1024 streams.
// Does NOT alter WebSocket paths, TLS/SNI/ALPN, heartbeat or wire format.
func (c *WsMuxTransport) maxLivePool() int32 {
	maximum := c.config.ConnPoolSize * 4
	if maximum < 64 {
		maximum = 64
	}
	if maximum > 128 {
		maximum = 128
	}
	return int32(maximum)
}

func (c *WsMuxTransport) reservePoolSlot() bool {
	limit := c.maxLivePool()
	for {
		old := atomic.LoadInt32(&c.poolSlots)
		if old >= limit {
			return false
		}
		if atomic.CompareAndSwapInt32(&c.poolSlots, old, old+1) {
			return true
		}
	}
}
'''
source=change(source,
    "\treturn client\n}\n\nfunc (c *WsMuxTransport) Start()",
    "\treturn client\n}\n"+helpers+"\nfunc (c *WsMuxTransport) Start()",
    "pool helpers")

source=change(source,
    "\t\t\tif (loadConnections + a) > poolConnectionsAvg*b {",
    "\t\t\tif (loadConnections + a) > poolConnectionsAvg*b && newPoolSize < int(c.maxLivePool()) {",
    "pool maintainer cap")

source=change(source,
    'func (c *WsMuxTransport) tunnelDialer() {\n\tc.logger.Debugf(',
    'func (c *WsMuxTransport) tunnelDialer() {\n'
    '\tif !c.reservePoolSlot() {\n'
    '\t\tc.logger.Debug("physical tunnel pool cap reached; reusing existing channels")\n'
    '\t\treturn\n'
    '\t}\n'
    '\tdefer atomic.AddInt32(&c.poolSlots, -1)\n'
    '\tc.logger.Debugf(',
    "atomic dial cap")

PATH.write_text(source)
print("POOLGUARD_PATCH_OK: finite 64..128 physical WSSMux tunnels (default 64).")
