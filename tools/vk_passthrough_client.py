#!/usr/bin/env python3
"""Reference client for the native Vulkan passthrough IPC protocol.

Talks to hcs_engine.exe --serve (127.0.0.1:6520 on the host; from inside
the Android guest connect to 10.0.2.2:6520 through the QEMU slirp gateway).

Wire format:
  request  = magic u32 'AVKQ', opcode u32, seq u32, payload_len u32, payload
  response = magic u32 'AVKA', opcode u32, seq u32, status i32,
             handles u64 x4, detail_len u32, detail

Opcode payload layouts (documented in tools/hcs_engine/src/dispatch.rs).
This client exercises every opcode and prints a pass/fail report — the
same regression loop as the Rust unit tests, but over the real socket.

Usage:  python tools/vk_passthrough_client.py [host] [port]
"""

import socket
import struct
import sys

MAGIC_REQ = 0x514B5641  # 'AVKQ'
MAGIC_RSP = 0x41564B41  # 'AVKA'

OP = {
    "create_instance": 1,
    "create_device": 2,
    "allocate_memory": 3,
    "create_image": 4,
    "create_buffer": 5,
    "queue_submit": 6,
    "queue_present": 7,
    "destroy_device": 8,
}

def call(sock, opcode, payload=b"", seq=0):
    sock.sendall(struct.pack("<4I", MAGIC_REQ, opcode, seq, len(payload)) + payload)
    hdr = recv_exact(sock, 52)
    magic, op, seq_r, status, h0, h1, h2, h3, dlen = struct.unpack("<3Ii4QI", hdr)
    assert magic == MAGIC_RSP, f"bad response magic 0x{magic:08x}"
    detail = recv_exact(sock, dlen).decode("utf-8", errors="replace")
    # binary data payload (e.g. rendered pixels)
    dlen2 = struct.unpack("<I", recv_exact(sock, 4))[0]
    data = recv_exact(sock, dlen2) if dlen2 else b""
    return status, (h0, h1, h2, h3), detail, data

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed mid-response")
        buf += chunk
    return buf

def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 6520
    sock = socket.create_connection((host, port), timeout=10)
    failures = 0

    def check(label, status, expect, detail="", handles=None):
        nonlocal failures
        ok = status == expect
        if not ok:
            failures += 1
        handles_txt = f" handles={['0x%X' % h for h in handles]}" if handles else ""
        print(f"[{'+' if ok else '-'}] {label:<24} status {status:<12} {detail}{handles_txt}")

    # CreateInstance: no payload
    status, handles, detail, _data = call(sock, OP["create_instance"])
    check("CreateInstance", status, 0, detail, [handles[0]])

    # CreateDevice: no payload
    status, handles, detail, _data = call(sock, OP["create_device"])
    check("CreateDevice", status, 0, detail, handles)

    # AllocateMemory: size u64, flags u32 (bit0 prefers host-visible)
    payload = struct.pack("<QI", 1 << 20, 1)
    status, handles, detail, _data = call(sock, OP["allocate_memory"], payload)
    check("AllocateMemory", status, 0, detail, handles)

    # CreateBuffer: size u64, usage u32
    payload = struct.pack("<QI", 64 << 10, 0)
    status, handles, detail, _data = call(sock, OP["create_buffer"], payload)
    check("CreateBuffer", status, 0, detail, handles)

    # CreateImage: width, height, format, usage (all u32)
    payload = struct.pack("<4I", 64, 64, 37, 20)
    status, handles, detail, _data = call(sock, OP["create_image"], payload)
    check("CreateImage", status, 0, detail, handles)

    # QueueSubmit: cmd buffer count u32 (informational)
    status, _h, detail, _data = call(sock, OP["queue_submit"], struct.pack("<I", 0))
    check("QueueSubmit", status, 0, detail)

    # QueuePresent: expected documented limitation (-1000001004)
    status, _h, detail, _data = call(sock, OP["queue_present"], struct.pack("<I", 0))
    check("QueuePresent (no WSI)", status, -1000001004, detail)

    # DestroyDevice
    status, _h, detail, _data = call(sock, OP["destroy_device"])
    check("DestroyDevice", status, 0, detail)

    sock.close()
    print(f"--- client {('PASSED' if failures == 0 else 'FAILED')}: {failures} failures ---")
    return 0 if failures == 0 else 1

if __name__ == "__main__":
    sys.exit(main())