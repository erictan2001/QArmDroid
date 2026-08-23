f = open('work_sdk/ramdisk.cpio', 'rb')
data = f.read()
pos = 0
while pos < len(data) - 110:
    if data[pos:pos+6] != b'070701': break
    namesize = int(data[pos+94:pos+102], 16)
    filesize = int(data[pos+54:pos+62], 16)
    name = data[pos+110:pos+110+namesize-1].decode('utf-8', errors='ignore')
    pos = (pos + 110 + namesize + 3) & ~3
    print(name)
    pos = (pos + filesize + 3) & ~3
