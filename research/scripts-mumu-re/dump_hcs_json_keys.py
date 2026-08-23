with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-hcs.dll", "rb") as f:
    data = f.read()

import re
# Find all ASCII and UTF-16 strings
strs = [s.decode('utf-8', errors='ignore') for s in re.findall(rb"[\x20-\x7E]{3,}", data)]
strs += [s.decode('utf-16le', errors='ignore') for s in re.findall(rb"(?:[\x20-\x7E]\x00){3,}", data)]

keys = set()
for s in strs:
    if len(s) < 80 and not s.startswith("http") and not s.startswith("?"):
        keys.add(s)

print("Potential JSON keys / config fields in nemu-hcs.dll:")
for k in sorted(list(keys)):
    terms = [
        "schema", "computesystem", "virtualmachine", "guest", "memory", "processor",
        "disk", "device", "storage", "network", "adapter", "pipe", "com", "serial",
        "boot", "vhd", "kernel", "ramdisk", "cmdline", "display", "gpu", "render",
        "hcs", "hcn", "switch", "endpoint", "path", "guid", "id"
    ]
    if any(t in k.lower() for t in terms):
        print("  ", k)
