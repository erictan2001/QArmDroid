#!/usr/bin/env python3
"""QMP client: inject keyboard/touch events into the QEMU frontend.

Uses the QMP `input-send-event` command (same path the SDL window uses:
frontend -> virtio-keyboard/virtio-tablet -> guest kernel). This isolates
whether the virtio input path works at all, independent of window focus/grab.

Usage:
  python tools/qmp_input.py <port> home           # qcode key press+release
  python tools/qmp_input.py <port> enter
  python tools/qmp_input.py <port> qcode:space
"""
import json
import socket
import sys


def rpc(sock, execute, arguments=None, ident=None):
    msg = {"execute": execute}
    if arguments is not None:
        msg["arguments"] = arguments
    if ident is not None:
        msg["id"] = ident
    sock.sendall(json.dumps(msg).encode() + b"\n")
    while True:
        line = sock.readline()
        if not line:
            raise ConnectionError("QMP closed")
        obj = json.loads(line)
        if "event" in obj:
            continue
        return obj


def main():
    port = int(sys.argv[1])
    qcode = sys.argv[2]
    if qcode.startswith("qcode:"):
        qcode = qcode[6:]
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    f = s.makefile("rwb")
    greeting = json.loads(f.readline())
    assert "QMP" in greeting, greeting
    rpc(f, "qmp_capabilities", ident=1)
    ev = {
        "type": "key",
        "data": {"key": {"type": "qcode", "data": qcode}},
    }
    r = rpc(f, "input-send-event",
            {"device": "keyboard", "events": [ev]}, ident=2)
    print("key down:", r.get("return") if "return" in r else r)
    r = rpc(f, "input-send-event",
            {"device": "keyboard", "events": [{"type": "key", "data": {"key":
             {"type": "qcode", "data": "ctrl"}}}]}, ident=3)
    print("ctrl down:", r.get("return") if "return" in r else r)
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())