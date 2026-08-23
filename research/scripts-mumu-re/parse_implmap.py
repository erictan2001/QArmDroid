import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

tilde_off = 0x5AB90
strings_off = 0x8BA6C
blob_off = 0x953F8

# Read table sizes
valid_mask = struct.unpack_from("<Q", data, tilde_off + 8)[0]
table_rows = {}
curr = tilde_off + 24
for i in range(64):
    if (valid_mask & (1 << i)):
        rows = struct.unpack_from("<I", data, curr)[0]
        curr += 4
        table_rows[i] = rows

strings_index_size = 4 if (data[tilde_off + 6] & 0x01) else 2
guid_index_size = 4 if (data[tilde_off + 6] & 0x02) else 2
blob_index_size = 4 if (data[tilde_off + 6] & 0x04) else 2

# Search through the whole binary for string indices 0x108C, 0x107C, 0x1093, 0x1085, 0x1072, 0x6BAC
for name, idx in [("InitVM", 0x108C), ("ConfigVM", 0x107C), ("StartVM", 0x1093), ("StopVM", 0x1085), ("ReleaseVM", 0x1072), ("GetLastVMError", 0x6BAC)]:
    pattern = struct.pack("<I" if strings_index_size == 4 else "<H", idx)
    pos = 0
    while True:
        p = data.find(pattern, pos)
        if p == -1: break
        print(f"Index for {name} (0x{idx:X}) found at file offset 0x{p:X}")
        pos = p + len(pattern)
