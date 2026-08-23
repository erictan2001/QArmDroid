with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# Let's inspect the bytes around offset 0xA388D
chunk = data[0xA3800:0xA3A00]
print("Strings near HcsSystem:")
for s in chunk.split(b"\x00"):
    if len(s) > 2:
        print("  ", s.decode('utf-8', errors='ignore'))
