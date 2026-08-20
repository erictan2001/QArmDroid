"""List top-level entries of the vendor ramdisk cpio to locate prop.default."""
import sys

c = open(sys.argv[1], "rb").read()
pos = 0
count = 0
while c[pos:pos + 6] == b"070701":
    hdr = c[pos:pos + 110]
    namesize = int(hdr[94:102], 16)
    filesize = int(hdr[54:62], 16)
    name = c[pos + 110:pos + 110 + namesize - 1].decode("utf-8", "replace")
    if name == "TRAILER!!!":
        break
    if "/" not in name.rstrip("/"):
        print(name, filesize)
    count += 1
    data_start = pos + 110 + namesize
    data_start = (data_start + 3) & ~3
    pos = data_start + filesize
    pos = (pos + 3) & ~3
print(f"--- total entries: {count}")
