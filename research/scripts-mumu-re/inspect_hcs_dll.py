with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-hcs.dll", "rb") as f:
    data = f.read()

# Let's inspect strings inside nemu-hcs.dll that are passed to ConfigVM/InitVM
import re
strs = [s.decode('utf-8', errors='ignore') for s in re.findall(rb"[\x20-\x7E]{4,}", data)]
for s in strs:
    if any(k in s.lower() for k in ["json", "vhd", "vm", "disk", "cpu", "mem", "kernel", "initrd", "boot", "adapter", "path"]):
        print("  ", s)
