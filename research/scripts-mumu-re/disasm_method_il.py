with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# Let's inspect bytes from 0x38750 to 0x38820
chunk = data[0x38750:0x38820]

# Simple IL opcode map
IL_OPS = {
    0x00: "nop",
    0x01: "break",
    0x02: "ldarg.0",
    0x03: "ldarg.1",
    0x04: "ldarg.2",
    0x05: "ldarg.3",
    0x06: "ldloc.0",
    0x07: "ldloc.1",
    0x08: "ldloc.2",
    0x09: "ldloc.3",
    0x0A: "stloc.0",
    0x0B: "stloc.1",
    0x0C: "stloc.2",
    0x0D: "stloc.3",
    0x14: "ldnull",
    0x15: "ldc.i4.m1",
    0x16: "ldc.i4.0",
    0x17: "ldc.i4.1",
    0x25: "dup",
    0x26: "pop",
    0x28: "call",
    0x2A: "ret",
    0x6F: "callvirt",
    0x72: "ldstr",
    0x7B: "ldfld",
    0x7C: "ldflda",
    0x7D: "stfld",
}

import struct
i = 0
while i < len(chunk):
    op = chunk[i]
    off = 0x38750 + i
    name = IL_OPS.get(op, f"0x{op:02X}")
    if op in [0x28, 0x6F, 0x72, 0x7B, 0x7C, 0x7D]:
        tok = struct.unpack_from("<I", chunk, i+1)[0]
        print(f"  IL_{off:05X}: {name} 0x{tok:08X}")
        i += 5
    elif op in [0x20]:
        val = struct.unpack_from("<I", chunk, i+1)[0]
        print(f"  IL_{off:05X}: ldc.i4 0x{val:X}")
        i += 5
    else:
        print(f"  IL_{off:05X}: {name}")
        i += 1
