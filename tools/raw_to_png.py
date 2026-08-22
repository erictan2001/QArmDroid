#!/usr/bin/env python3
"""Convert a raw BGRA8 frame (as produced by the passthrough renderer) to PNG.

Usage:  python tools/raw_to_png.py <frame.raw> <width> <height> <out.png>
"""

import struct
import sys
import zlib


def write_png(path, width, height, rgba_rows):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raw = b"".join(b"\x00" + row for row in rgba_rows)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 1
    src, w, h, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    data = open(src, "rb").read()
    expect = w * h * 4
    if len(data) < expect:
        print(f"ERROR: {src} has {len(data)} bytes, need {expect} for {w}x{h}")
        return 1
    rows = []
    for y in range(h):
        row = data[y * w * 4:(y + 1) * w * 4]
        # BGRA -> RGBA
        rgba = bytearray()
        for i in range(0, len(row), 4):
            b, g, r, a = row[i], row[i + 1], row[i + 2], row[i + 3]
            rgba += bytes((r, g, b, a))
        rows.append(bytes(rgba))
    write_png(dst, w, h, rows)
    print(f"wrote {dst} ({w}x{h}) from {len(data)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())