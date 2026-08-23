with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

import re
# Find all occurrences of string "InitVM" or token 0x06000...
for m in re.finditer(rb"(InitVM|ConfigVM|setting\.json|base\.madoa)", data):
    start = max(0, m.start() - 80)
    end = min(len(data), m.end() + 80)
    print(f"Match at {m.start()}: {data[start:end]}")
