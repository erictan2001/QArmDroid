with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

import re
# Find all occurrences of InitVM, ConfigVM, StartVM and dump surrounding strings
for m in re.finditer(rb"(InitVM|ConfigVM|StartVM|StopVM|ReleaseVM|HcsSystem)", data):
    start = max(0, m.start() - 60)
    end = min(len(data), m.end() + 60)
    chunk = data[start:end]
    # Filter printable
    printable = "".join(chr(c) if 32 <= c <= 126 else "." for c in chunk)
    print(f"Match at {m.start()}: {printable}")
