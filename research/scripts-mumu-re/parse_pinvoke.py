import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# Parse CLI Header (COM descriptor)
e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
opt_hdr_off = e_lfanew + 24
magic = struct.unpack_from("<H", data, opt_hdr_off)[0]
if magic == 0x20B: # PE32+ (64-bit)
    cli_rva = struct.unpack_from("<I", data, opt_hdr_off + 112 + 14 * 8)[0]
elif magic == 0x10B: # PE32 (32-bit)
    cli_rva = struct.unpack_from("<I", data, opt_hdr_off + 96 + 14 * 8)[0]
num_sections = struct.unpack_from("<H", data, e_lfanew + 6)[0]
sec_hdr_off = opt_hdr_off + 240

def rva_to_offset(rva):
    for i in range(num_sections):
        sh = sec_hdr_off + i * 40
        vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", data, sh + 8)
        if va <= rva < va + max(vsize, raw_size):
            return raw_ptr + (rva - va)
    return None

cli_off = rva_to_offset(cli_rva)
meta_rva, meta_size = struct.unpack_from("<II", data, cli_off + 8)
meta_off = rva_to_offset(meta_rva)

# Metadata root
sig = data[meta_off:meta_off+4]
assert sig == b"BSJB"
vlen = struct.unpack_from("<I", data, meta_off + 12)[0]
vstr = data[meta_off+16:meta_off+16+vlen]
stream_hdr_start = meta_off + 16 + vlen
flags, num_streams = struct.unpack_from("<HH", data, stream_hdr_start)

streams = {}
curr = stream_hdr_start + 4
for _ in range(num_streams):
    soff, ssize = struct.unpack_from("<II", data, curr)
    curr += 8
    name = b""
    while data[curr] != 0:
        name += bytes([data[curr]])
        curr += 1
    while curr % 4 != 0 or data[curr] == 0:
        curr += 1
    streams[name.decode('utf-8')] = meta_off + soff

print("Streams:", streams.keys())

# Strings stream
strings_off = streams.get("#Strings")
def get_string(idx):
    if not strings_off or idx >= len(data) - strings_off: return ""
    s = b""
    p = strings_off + idx
    while p < len(data) and data[p] != 0:
        s += bytes([data[p]])
        p += 1
    return s.decode('utf-8', errors='ignore')

# Dump all strings in #Strings stream matching our functions
p = strings_off
found = []
while p < strings_off + 30000:
    s = b""
    while p < len(data) and data[p] != 0:
        s += bytes([data[p]])
        p += 1
    p += 1
    if s:
        st = s.decode('utf-8', errors='ignore')
        if any(k in st.lower() for k in ["vm", "hcs", "renderer", "decoder", "input", "display"]):
            found.append(st)

print("Relevant strings in #Strings:")
for f in sorted(list(set(found))):
    print("  ", f)
