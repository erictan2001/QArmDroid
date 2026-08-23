import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# Let's search for the method definitions of InitVM, ConfigVM, StartVM, StopVM, ReleaseVM
# We can search in #Strings stream for "InitVM" and find references in metadata tables
e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
opt_hdr_off = e_lfanew + 24
magic = struct.unpack_from("<H", data, opt_hdr_off)[0]
cli_rva = struct.unpack_from("<I", data, opt_hdr_off + 112 + 14 * 8)[0]
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
vlen = struct.unpack_from("<I", data, meta_off + 12)[0]
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
    streams[name.decode('utf-8')] = (meta_off + soff, ssize)

strings_off, strings_size = streams["#Strings"]
blob_off, blob_size = streams["#Blob"]
tilde_off, tilde_size = streams["#~"]

print(f"#~ at 0x{tilde_off:X}, #Strings at 0x{strings_off:X}, #Blob at 0x{blob_off:X}")

# Let's inspect string offsets for InitVM, ConfigVM, etc.
def find_str_offset(target_str):
    off = data.find(target_str.encode('utf-8') + b"\x00", strings_off, strings_off + strings_size)
    if off != -1:
        return off - strings_off
    return None

for name in ["InitVM", "ConfigVM", "StartVM", "StopVM", "ReleaseVM", "GetLastVMError", "InitializeDecoder"]:
    soff = find_str_offset(name)
    print(f"String '{name}' offset in #Strings: 0x{soff:X}" if soff else f"'{name}' not found")
