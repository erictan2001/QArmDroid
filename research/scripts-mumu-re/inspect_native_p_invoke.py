import re

def search_patterns(dll_path):
    with open(dll_path, "rb") as f:
        data = f.read()
    
    # ASCII strings
    ascii_strs = [s.decode('ascii', errors='ignore') for s in re.findall(rb"[A-Za-z0-9_\-\./:= <>]{4,}", data)]
    return ascii_strs

for dll in [
    r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.Native.dll",
    r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.Core.dll",
    r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll"
]:
    print(f"=== {dll} ===")
    strs = search_patterns(dll)
    for s in strs:
        if any(k in s.lower() for k in ["initvm", "configvm", "startvm", "stopvm", "hcssystem", "vmadapter", "renderadapter", "nativemethods"]):
            print("  ", s)
