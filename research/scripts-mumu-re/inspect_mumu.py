import re

def extract_strings(filepath, min_len=4):
    with open(filepath, "rb") as f:
        data = f.read()
    # ascii strings
    res = re.findall(rb"[A-Za-z0-9_\-\./:= ]{6,}", data)
    return [s.decode('ascii', errors='ignore') for s in res]

print("=== nemu-hcs.dll strings ===")
hcs_strings = extract_strings(r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-hcs.dll")
for s in hcs_strings:
    if any(k in s.lower() for k in ["boot", "kernel", "gpu", "render", "vulkan", "dxgi", "d3d", "pipe", "vsock", "hcs", "vhdx", "cmdline"]):
        print("  ", s)

print("\n=== libRenderer.dll strings ===")
ren_strings = extract_strings(r"C:\Program Files\Netease\MuMuPlayer\shell\libRenderer.dll")
for s in ren_strings[:50]:
    if any(k in s.lower() for k in ["vulkan", "d3d11", "d3d12", "gl", "angle", "surface", "swapchain"]):
        print("  ", s)
