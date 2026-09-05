import os, sys

default_p = os.path.join(os.environ.get("LOCALAPPDATA", ""), r"Android\Sdk\system-images\android-34\google_apis\arm64-v8a\system.img")
p = sys.argv[1] if len(sys.argv) > 1 else default_p
if not os.path.exists(p):
    sys.exit(f"Image not found at {p}. Pass path as argument.")
f = open(p, 'rb')
f.seek(1024)
for i in range(128):
    entry = f.read(128)
    if entry[:16] == b'\x00'*16: continue
    first_lba = int.from_bytes(entry[32:40], 'little')
    last_lba = int.from_bytes(entry[40:48], 'little')
    name = entry[56:128].decode('utf-16le').strip('\x00')
    print(f"Partition {i}: {name} (LBA {first_lba}..{last_lba}, {(last_lba-first_lba+1)*512//(1024*1024)} MB)")
