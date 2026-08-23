import re

def search_flags(bin_path):
    with open(bin_path, "rb") as f:
        data = f.read()
    ascii_flags = re.findall(rb"-[a-zA-Z0-9_\-]+|--[a-zA-Z0-9_\-]+", data)
    utf16_flags = re.findall(rb"(?:-[a-zA-Z0-9_\-]\x00)+|(?:--[a-zA-Z0-9_\-]\x00)+", data)
    return set([s.decode('ascii', errors='ignore') for s in ascii_flags] + 
               [s.decode('utf-16le', errors='ignore') for s in utf16_flags])

print("Flags in Manager:", sorted(list(search_flags(r"C:\Program Files\Netease\MuMuPlayer\manager\nemux-shell-winui.Manager.exe")))[:30])
print("Flags in Shell:", sorted(list(search_flags(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.exe")))[:30])
