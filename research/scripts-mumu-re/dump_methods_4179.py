import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

strings_off = 0x8BA6C
blob_off = 0x953F8

# MethodDef table offset in #~ stream:
# MethodDef table starts at offset 0x6198C
# Each row: RVA(4), ImplFlags(2), Flags(2), Name(2), Signature(2), ParamList(2) = 14 bytes
m_off = 0x6198C
row_size = 14

def get_str(idx):
    p = strings_off + idx
    s = b""
    while p < len(data) and data[p] != 0:
        s += bytes([data[p]])
        p += 1
    return s.decode('utf-8', errors='ignore')

def get_blob(idx):
    p = blob_off + idx
    b0 = data[p]
    if (b0 & 0x80) == 0:
        length = b0
        p += 1
    elif (b0 & 0xC0) == 0x80:
        length = ((b0 & 0x3F) << 8) | data[p+1]
        p += 2
    else:
        length = ((b0 & 0x1F) << 24) | (data[p+1] << 16) | (data[p+2] << 8) | data[p+3]
        p += 4
    return data[p:p+length]

# Element type names in CLI metadata
ELEMENT_TYPES = {
    0x01: "void",
    0x02: "bool",
    0x03: "char",
    0x04: "sbyte",
    0x05: "byte",
    0x06: "int16",
    0x07: "uint16",
    0x08: "int32",
    0x09: "uint32",
    0x0A: "int64",
    0x0B: "uint64",
    0x0C: "float32",
    0x0D: "float64",
    0x0E: "string",
    0x0F: "ptr",
    0x10: "byref",
    0x18: "intptr",
    0x19: "uintptr",
    0x1C: "object",
    0x1D: "szarray",
}

def parse_sig(blob):
    # blob: [calling_conv, param_count, ret_type, p1, p2...]
    call_conv = blob[0]
    param_count = blob[1]
    ret = ELEMENT_TYPES.get(blob[2], f"0x{blob[2]:02X}")
    params = [ELEMENT_TYPES.get(b, f"0x{b:02X}") for b in blob[3:3+param_count]]
    return f"{ret} ({', '.join(params)})"

for row in range(4178, 4186):
    rp = m_off + (row - 1) * row_size
    rva, impl_flags, flags, name_idx, sig_idx, param_idx = struct.unpack_from("<IHHHHH", data, rp)
    name = get_str(name_idx)
    sig_blob = get_blob(sig_idx)
    print(f"MethodDef #{row}: {name} -> hex_sig={sig_blob.hex()} -> decoded: {parse_sig(sig_blob)}")
