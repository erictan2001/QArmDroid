import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

blob_off = 0x953F8

# ImplMap record format (8 bytes if indices are 2 bytes):
# MappingFlags (2 bytes)
# MemberForwarded (MemberForwarded coded index, 2 bytes)
# ImportName (String index, 2 bytes)
# ImportScope (ModuleRef index, 2 bytes)

for off in range(0x8A366, 0x8A39A, 8):
    flags, member_fwd, name_idx, mod_ref = struct.unpack_from("<HHHH", data, off)
    # MemberForwarded: low 1 bit is table (0 = MethodDef, 1 = Field), high 15 bits is row
    method_row = (member_fwd >> 1)
    print(f"ImplMap at 0x{off:X}: flags=0x{flags:X}, MemberForwarded=0x{member_fwd:X} (MethodDef #{method_row}), name_idx=0x{name_idx:X}, mod_ref={mod_ref}")
