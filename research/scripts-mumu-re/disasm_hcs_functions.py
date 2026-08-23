import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-hcs.dll", "rb") as f:
    data = f.read()

# Let's find export RVA of InitVM, ConfigVM, StartVM
e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
opt_hdr_off = e_lfanew + 24
magic = struct.unpack_from("<H", data, opt_hdr_off)[0]
export_rva = struct.unpack_from("<I", data, opt_hdr_off + 112)[0]
num_sections = struct.unpack_from("<H", data, e_lfanew + 6)[0]
sec_hdr_off = opt_hdr_off + 240

def rva_to_offset(rva):
    for i in range(num_sections):
        sh = sec_hdr_off + i * 40
        vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", data, sh + 8)
        if va <= rva < va + max(vsize, raw_size):
            return raw_ptr + (rva - va)
    return None

exp_off = rva_to_offset(export_rva)
num_funcs = struct.unpack_from("<I", data, exp_off + 0x14)[0]
num_names = struct.unpack_from("<I", data, exp_off + 0x18)[0]
funcs_rva = struct.unpack_from("<I", data, exp_off + 0x1C)[0]
names_rva = struct.unpack_from("<I", data, exp_off + 0x20)[0]
ordinals_rva = struct.unpack_from("<I", data, exp_off + 0x24)[0]

funcs_off = rva_to_offset(funcs_rva)
names_off = rva_to_offset(names_rva)
ords_off = rva_to_offset(ordinals_rva)

exports = {}
for i in range(num_names):
    nrva = struct.unpack_from("<I", data, names_off + i * 4)[0]
    ord_val = struct.unpack_from("<H", data, ords_off + i * 2)[0]
    frva = struct.unpack_from("<I", data, funcs_off + ord_val * 4)[0]
    noff = rva_to_offset(nrva)
    s = b""
    j = 0
    while data[noff+j] != 0:
        s += bytes([data[noff+j]])
        j += 1
    name = s.decode('utf-8')
    exports[name] = frva

for name, frva in exports.items():
    foff = rva_to_offset(frva)
    bytes_hex = data[foff:foff+32].hex()
    print(f"Export {name} at RVA 0x{frva:X} (file offset 0x{foff:X}): {bytes_hex}")
