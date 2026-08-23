import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

strings_off = 0x8BA6C
blob_off = 0x953F8

# Field table starts at table 0x04 offset
# In #~ stream, Field table is table 0x04
# Each row in Field table: Flags(2), Name(2), Signature(2) = 6 bytes

# Field row for token 0x04000A47 is row 0xA47 = 2631
# Field row for token 0x04000A48 is row 0xA48 = 2632
# Field row for token 0x04000A44 is row 0xA44 = 2628

# Let's find Field table offset
# In dump_hcs_signatures2.py, Field table is at table_offsets[4]
# Table rows: 0x00=1, 0x01=763, 0x02=670, 0x04=2705
# Field table offset = tilde_off + 24 + 64*4 + row_sizes
# Let's search in data for the string offsets
def get_str(idx):
    p = strings_off + idx
    s = b""
    while p < len(data) and data[p] != 0:
        s += bytes([data[p]])
        p += 1
    return s.decode('utf-8', errors='ignore')

tilde_off = 0x5AB90
strings_off = 0x8BA6C

# Calculate Field table offset:
# Table sizes: 0x00 (1 row * 10), 0x01 (763 rows * 6), 0x02 (670 rows * 14)
# Header = 24 + 29 tables * 4 = 140 bytes
hdr_size = 24 + 29 * 4
t0_size = 1 * 10
t1_size = 763 * 6
t2_size = 670 * 14
field_off = tilde_off + hdr_size + t0_size + t1_size + t2_size

for r in [2628, 2631, 2632]:
    fp = field_off + (r - 1) * 6
    flags, name_idx, sig_idx = struct.unpack_from("<HHH", data, fp)
    print(f"Field #{r}: name='{get_str(name_idx)}', flags=0x{flags:X}")
