import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# MemberForwarded indices for InitVM, ConfigVM, StartVM, StopVM, ReleaseVM:
# InitVM = MethodDef #4179 -> token 0x06001053 (0x1053 = 4179)
# ConfigVM = MethodDef #4180 -> token 0x06001054
# StartVM = MethodDef #4181 -> token 0x06001055
# StopVM = MethodDef #4182 -> token 0x06001056
# ReleaseVM = MethodDef #4183 -> token 0x06001057

for name, row in [("InitVM", 4179), ("ConfigVM", 4180), ("StartVM", 4181), ("StopVM", 4182), ("ReleaseVM", 4183)]:
    token = 0x06000000 | row
    pattern = struct.pack("<I", token)
    pos = 0
    while True:
        p = data.find(pattern, pos)
        if p == -1: break
        # Print opcode preceding the token
        op = data[p-1] if p > 0 else 0
        print(f"Call to {name} (token 0x{token:08X}) at file offset 0x{p:X} with opcode 0x{op:02X}")
        # Print preceding 30 bytes of IL instructions
        il_chunk = data[max(0, p-30):p+4]
        print("  Preceding IL bytes:", il_chunk.hex())
        pos = p + 4
