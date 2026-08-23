import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

tilde_off = 0x5AB90
strings_off = 0x8BA6C
blob_off = 0x953F8

reserved, major, minor, heflags, rid = struct.unpack_from("<IBBBI", data, tilde_off)
valid_mask = struct.unpack_from("<Q", data, tilde_off + 8)[0]
sorted_mask = struct.unpack_from("<Q", data, tilde_off + 16)[0]

# Read row counts for valid tables
table_rows = {}
curr = tilde_off + 24
for i in range(64):
    if (valid_mask & (1 << i)):
        rows = struct.unpack_from("<I", data, curr)[0]
        curr += 4
        table_rows[i] = rows

print("Table rows:", {f"0x{k:02X}": v for k, v in table_rows.items() if v > 0})

# ImplMap is table 0x1C (28)
# MethodDef is table 0x06 (6)
# ModuleRef is table 0x1A (26)

strings_index_size = 4 if (heflags & 0x01) else 2
guid_index_size = 4 if (heflags & 0x02) else 2
blob_index_size = 4 if (heflags & 0x04) else 2

def read_str_idx(p):
    if strings_index_size == 4:
        return struct.unpack_from("<I", data, p)[0], p + 4
    else:
        return struct.unpack_from("<H", data, p)[0], p + 2

def read_blob_idx(p):
    if blob_index_size == 4:
        return struct.unpack_from("<I", data, p)[0], p + 4
    else:
        return struct.unpack_from("<H", data, p)[0], p + 2

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

# Find table offsets
table_offsets = {}
table_start = curr
for i in range(64):
    if (valid_mask & (1 << i)):
        table_offsets[i] = table_start
        # calculate row size
        row_size = 0
        if i == 0x00: # Module
            row_size = 2 + strings_index_size + guid_index_size * 3
        elif i == 0x01: # TypeRef
            row_size = (4 if max(table_rows.get(0,0), table_rows.get(0x1A,0), table_rows.get(0x23,0), table_rows.get(1,0)) > 65535 else 2) + strings_index_size * 2
        elif i == 0x02: # TypeDef
            row_size = 4 + strings_index_size * 2 + (4 if max(table_rows.get(2,0), table_rows.get(1,0), table_rows.get(0x1B,0)) > 65535 else 2) + (4 if table_rows.get(4,0) > 65535 else 2) + (4 if table_rows.get(6,0) > 65535 else 2)
        elif i == 0x04: # Field
            row_size = 2 + strings_index_size + blob_index_size
        elif i == 0x06: # MethodDef
            row_size = 4 + 2 + 2 + strings_index_size + blob_index_size + (4 if table_rows.get(8,0) > 65535 else 2)
        elif i == 0x08: # Param
            row_size = 2 + 2 + strings_index_size
        elif i == 0x1C: # ImplMap
            row_size = 2 + (4 if max(table_rows.get(4,0), table_rows.get(6,0)) > 65535 else 2) + strings_index_size + (4 if table_rows.get(0x1A,0) > 65535 else 2)
        else:
            # Approximate / skip parsing other tables dynamically
            pass
        table_start += row_size * table_rows[i]

print("MethodDef rows:", table_rows.get(6))

# Let's inspect MethodDef
m_off = table_offsets[6]
m_row_size = 4 + 2 + 2 + strings_index_size + blob_index_size + (4 if table_rows.get(8,0) > 65535 else 2)
for row in range(table_rows.get(6, 0)):
    rp = m_off + row * m_row_size
    rva, impl_flags, flags = struct.unpack_from("<IHH", data, rp)
    name_idx, _ = read_str_idx(rp + 8)
    sig_idx, _ = read_blob_idx(rp + 8 + strings_index_size)
    name = get_str(name_idx)
    if name in ["InitVM", "ConfigVM", "StartVM", "StopVM", "ReleaseVM", "GetLastVMError"]:
        sig = get_blob(sig_idx)
        print(f"Method {name} (RVA 0x{rva:X}, flags 0x{flags:X}): sig_bytes={sig.hex()}")
