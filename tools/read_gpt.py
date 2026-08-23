f = open(r'C:\Users\erict\AppData\Local\Android\Sdk\system-images\android-34\google_apis\arm64-v8a\system.img', 'rb')
f.seek(1024)
for i in range(128):
    entry = f.read(128)
    if entry[:16] == b'\x00'*16: continue
    first_lba = int.from_bytes(entry[32:40], 'little')
    last_lba = int.from_bytes(entry[40:48], 'little')
    name = entry[56:128].decode('utf-16le').strip('\x00')
    print(f"Partition {i}: {name} (LBA {first_lba}..{last_lba}, {(last_lba-first_lba+1)*512//(1024*1024)} MB)")
