with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-hcs.dll", "rb") as f:
    data = f.read()

# Let's inspect InitVM at file offset 0x5F6F8
initvm_off = 0x5F6F8
chunk = data[initvm_off:initvm_off+128]

# Disassemble ARM64 instructions using capstone if available, or print words
import struct
words = struct.unpack_from(f"<{len(chunk)//4}I", chunk)
for i, w in enumerate(words):
    print(f"  0x{initvm_off + i*4:05X}: {w:08X}")
