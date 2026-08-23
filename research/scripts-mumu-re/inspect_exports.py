import struct

def get_exports(dll_path):
    with open(dll_path, "rb") as f:
        data = f.read()
    
    # DOS Header
    if data[:2] != b"MZ":
        return []
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    
    # PE Header
    pe_sig = data[e_lfanew:e_lfanew+4]
    if pe_sig != b"PE\x00\x00":
        return []
    
    opt_hdr_off = e_lfanew + 4 + 20
    magic = struct.unpack_from("<H", data, opt_hdr_off)[0]
    
    if magic == 0x20B: # PE32+ (64-bit)
        export_rva, export_size = struct.unpack_from("<II", data, opt_hdr_off + 112)
    elif magic == 0x10B: # PE32 (32-bit)
        export_rva, export_size = struct.unpack_from("<II", data, opt_hdr_off + 96)
    else:
        return []
    
    if export_rva == 0 or export_size == 0:
        return []
    
    # Find section containing export_rva
    num_sections = struct.unpack_from("<H", data, e_lfanew + 6)[0]
    sec_hdr_off = opt_hdr_off + (240 if magic == 0x20B else 224)
    
    def rva_to_offset(rva):
        for i in range(num_sections):
            sh = sec_hdr_off + i * 40
            vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", data, sh + 8)
            if va <= rva < va + max(vsize, raw_size):
                return raw_ptr + (rva - va)
        return None

    exp_off = rva_to_offset(export_rva)
    if exp_off is None:
        return []
    
    num_funcs, num_names, names_rva = struct.unpack_from("<III", data, exp_off + 20 + 4)
    # The layout:
    # 0x18: NumberOfFunctions (DWORD)
    # 0x1C: NumberOfNames (DWORD)
    # 0x20: AddressOfFunctions (DWORD RVA)
    # 0x24: AddressOfNames (DWORD RVA)
    # 0x28: AddressOfNameOrdinals (DWORD RVA)
    num_funcs = struct.unpack_from("<I", data, exp_off + 0x14)[0]
    num_names = struct.unpack_from("<I", data, exp_off + 0x18)[0]
    names_rva = struct.unpack_from("<I", data, exp_off + 0x20)[0]
    
    names_off = rva_to_offset(names_rva)
    if names_off is None:
        return []
    
    names = []
    for i in range(num_names):
        name_rva = struct.unpack_from("<I", data, names_off + i * 4)[0]
        name_off = rva_to_offset(name_rva)
        if name_off:
            s = b""
            j = 0
            while data[name_off + j] != 0:
                s += bytes([data[name_off + j]])
                j += 1
            names.append(s.decode('utf-8', errors='ignore'))
    return names

for dll in [
    r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-hcs.dll",
    r"C:\Program Files\Netease\MuMuPlayer\shell\libRenderer.dll",
    r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-inputmanager.dll"
]:
    print(f"=== Exports of {dll} ===")
    exps = get_exports(dll)
    for exp in exps:
        print("  ", exp)
