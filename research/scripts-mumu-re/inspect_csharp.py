import re

def search_csharp_strings(dll_path):
    with open(dll_path, "rb") as f:
        data = f.read()
    # Find UTF-8 / ASCII strings in metadata
    strs = [s.decode('utf-8', errors='ignore') for s in re.findall(rb"[\x20-\x7E]{5,}", data)]
    return strs

for dll in [
    r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.Core.dll",
    r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll"
]:
    print(f"=== {dll} ===")
    strs = search_csharp_strings(dll)
    for s in strs:
        if any(k in s.lower() for k in ["launch", "startvm", "hcs", "argument", "cmdline", "commandline", "vmindex", "-v", "madoa"]):
            print("  ", s)
