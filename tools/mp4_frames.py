#!/usr/bin/env python3
"""Count video frames in an MP4 (stsz sample_count of the video track)."""
import struct
import sys


def main():
    path = sys.argv[1]
    data = open(path, "rb").read()
    counts = []
    # collect every stsz; the video track is the one with the most samples
    start = 0
    while True:
        i = data.find(b"stsz", start)
        if i < 0:
            break
        # skip possible false positive inside mdat by requiring sane size
        size, = struct.unpack(">I", data[i - 4:i])
        if 16 <= size <= len(data):
            sample_count, = struct.unpack(">I", data[i + 12:i + 16])
            if 0 < sample_count < (1 << 30):
                counts.append(sample_count)
        start = i + 4
    if not counts:
        print(f"{path}: no stsz found")
        return 1
    frames = max(counts)
    print(f"{path}: {frames} video frames (stsz candidates: {counts})")
    return 0


if __name__ == "__main__":
    sys.exit(main())