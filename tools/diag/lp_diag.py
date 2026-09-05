#!/usr/bin/env python3
"""Diagnostic: parse android LP metadata in super_raw.img, dump tables."""
import os, struct, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))
candidates = [
    sys.argv[1] if len(sys.argv) > 1 else "",
    os.path.join(ROOT_DIR, "aosp_cf_arm64_only_phone-img", "work", "m0", "super_raw.img"),
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "QArmDroid", "image", "super_raw.img"),
]
P = next((c for c in candidates if c and os.path.exists(c)), candidates[1])
if not os.path.exists(P):
    sys.exit(f"super_raw.img not found at {P}. Provide path as argument.")
data = open(P, "rb").read(400*1024)

H = 12288
magic, major, minor, header_size, tables_size = struct.unpack_from("<4sHHII", data, H)
print("magic", magic, "ver", major, minor, "header_size", header_size, "tables_size", tables_size)

# Scan for the table descriptors: find 4 consecutive {num,offset} pairs with
# sane values. They live inside the header (offsets relative to header start).
# partitions num ~16, block_devices num ~1.
best = None
for base in range(H+12, H+header_size-32, 4):
    try:
        pn, po, en, eo, gn, go, bn, bo = struct.unpack_from("<IIIIIIII", data, base)
    except struct.error:
        break
    if (1 <= pn <= 64 and 0 <= po <= 0x100000 and
        1 <= en <= 256 and 0 <= eo <= 0x100000 and
        1 <= gn <= 64 and 0 <= go <= 0x100000 and
        1 <= bn <= 8 and 0 <= bo <= 0x100000 and
        po < eo < go < bo):
        best = (base, pn, po, en, eo, gn, go, bn, bo)
        break
if not best:
    print("could not locate table descriptors by scan"); sys.exit(1)
base, pn, po, en, eo, gn, go, bn, bo = best
print(f"descriptors at header-offset {base-H}: parts n={pn} off={po} | "
      f"extents n={en} off={eo} | groups n={gn} off={go} | devs n={bn} off={bo}")

# The table blob begins right after the header (offsets are relative to it).
tbl = H + header_size
def part_name(i):
    o = tbl + po + i*52
    return data[o:o+36].split(b"\x00")[0].decode()

print("\n=== PARTITIONS ===")
parts = []
for i in range(pn):
    o = tbl + po + i*52
    name = data[o:o+36].split(b"\x00")[0].decode()
    attrs, fei, n_ext, gi = struct.unpack_from("<IIII", data, o+36)
    parts.append((name, attrs, fei, n_ext, gi))
    print(f"  [{i}] {name:20s} attrs={attrs} first_extent={fei} num_extents={n_ext} group={gi}")

print("\n=== EXTENTS ===")
exts = []
for i in range(en):
    o = tbl + eo + i*56
    ns, ttype, res = struct.unpack_from("<QHH", data, o)
    bdev, psec = struct.unpack_from("<IQ", data, o+16)
    exts.append((ns, ttype, bdev, psec))
    print(f"  [{i}] sectors={ns} type={ttype} bdev={bdev} phys_sector={psec} "
          f"(byte_off={psec*512})")

print("\n=== BLOCK DEVICES ===")
for i in range(bn):
    o = tbl + bo + i*128
    fls, al, aoff = struct.unpack_from("<QII", data, o)
    size, bs = struct.unpack_from("<QI", data, o+16)
    pname = data[o+24:o+60].split(b"\x00")[0].decode()
    print(f"  [{i}] {pname:12s} first_logical_sector={fls} size={size} block_size={bs}")

# Now resolve system_a
print("\n=== system_a resolution ===")
for (name, attrs, fei, n_ext, gi) in parts:
    if name == "system_a":
        tot = 0
        for e in range(fei, fei+n_ext):
            ns, ttype, bdev, psec = exts[e]
            tot += ns
            print(f"  extent[{e}]: {ns*512/1e9:.3f} GB at super-byte {psec*512}")
        print(f"  total system_a = {tot*512/1e9:.3f} GB")
