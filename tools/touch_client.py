#!/usr/bin/env python3
"""Host-side touch client for the guest touch_daemon (TCP 127.0.0.1:6666).

The guest ramdisk runs /touch_daemon, which writes raw evdev events into the
tablet input node. Protocol (tools/touch_daemon.c): fixed 14-byte LE packets
[cmd:u8][pad:u8][x1:u16][y1:u16][x2:u16][y2:u16][dur:u16][key:u16]
cmds: 1=tap(x1,y1) 2=down 3=move 4=up 5=swipe(x1,y1,x2,y2,dur_ms)

Requires launch.ps1's hostfwd tcp:127.0.0.1:6666-10.0.2.15:6666.

Usage:
  python tools/touch_client.py tap 640 400
  python tools/touch_client.py swipe 600 600 600 300 300
  python tools/touch_client.py down 640 400 / move 650 410 / up
"""
import socket
import struct
import sys

HOST, PORT = "127.0.0.1", 6666


def send(cmd, pkt):
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall(pkt)
    s.close()
    print(f"sent {cmd}: {pkt.hex()}")


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    cmd = args[0]
    if cmd == "tap":
        x, y = int(args[1]), int(args[2])
        pkt = struct.pack("<BBHHHHHH", 1, 0, x, y, 0, 0, 20, 0)
        send(cmd, pkt)
    elif cmd == "down":
        x, y = int(args[1]), int(args[2])
        pkt = struct.pack("<BBHHHHHH", 2, 0, x, y, 0, 0, 0, 0)
        send(cmd, pkt)
    elif cmd == "move":
        x, y = int(args[1]), int(args[2])
        pkt = struct.pack("<BBHHHHHH", 3, 0, x, y, 0, 0, 0, 0)
        send(cmd, pkt)
    elif cmd == "up":
        pkt = struct.pack("<BBHHHHHH", 4, 0, 0, 0, 0, 0, 0, 0)
        send(cmd, pkt)
    elif cmd == "swipe":
        x1, y1, x2, y2 = int(args[1]), int(args[2]), int(args[3]), int(args[4])
        dur = int(args[5]) if len(args) > 5 else 250
        pkt = struct.pack("<BBHHHHHH", 5, 0, x1, y1, x2, y2, dur, 0)
        send(cmd, pkt)
    else:
        print(f"unknown cmd {cmd}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())