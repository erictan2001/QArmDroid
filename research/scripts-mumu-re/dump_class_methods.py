import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# Let's search for "HcsSystem" in #Strings
strings_off = 0x8BA6C
blob_off = 0x953F8

# Let's find all occurrences of "HcsSystem"
import re
for m in re.finditer(rb"HcsSystem", data):
    print(f"Match HcsSystem at offset 0x{m.start():X}")
