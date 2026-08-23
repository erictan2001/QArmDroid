import re

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\libRenderer.dll", "rb") as f:
    data = f.read()

# ascii and utf-16
ascii_strs = [s.decode('ascii', errors='ignore') for s in re.findall(rb"[A-Za-z0-9_\-\./:= ]{5,}", data)]
utf16_strs = [s.decode('utf-16le', errors='ignore') for s in re.findall(rb"(?:[A-Za-z0-9_\-\./:= ]\x00){5,}", data)]

all_strs = ascii_strs + utf16_strs
keywords = ["vulkan", "d3d", "directx", "opengl", "angle", "gles", "pipe", "vsock", "swapchain", "render", "surfaceflinger", "gralloc", "virgl", "gfxstream"]

found = {}
for s in all_strs:
    low = s.lower()
    for k in keywords:
        if k in low and len(s) < 100:
            found[s] = True

for s in list(found.keys())[:80]:
    print("  ", s)
