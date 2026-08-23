import re

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# Search for DllImport("nemu-hcs.dll")
for m in re.finditer(rb"nemu-hcs\.dll", data):
    start = max(0, m.start() - 100)
    end = min(len(data), m.end() + 200)
    print(f"Match at {m.start()}: {data[start:end]}")
