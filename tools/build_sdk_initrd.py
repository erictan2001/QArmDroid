import os
import struct
import io
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
LOCALAPPDATA = os.environ.get("LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local"))

IMG_DIR = os.environ.get("ANDROID_IMAGE_DIR", os.path.join(LOCALAPPDATA, r"Android\Sdk\system-images\android-34\google_apis\arm64-v8a"))
WORK_DIR = os.environ.get("SDK_WORK_DIR", os.path.join(ROOT_DIR, "work_sdk"))
RAMDISK_SRC = os.path.join(IMG_DIR, "ramdisk.img")
OUT_INITRD = os.path.join(WORK_DIR, "initrd_sdk.img")

# 1. Decompress ramdisk.img
lz4_candidates = [
    r"C:\msys64\clangarm64\bin\lz4.exe",
    "lz4.exe",
]
lz4_bin = next((c for c in lz4_candidates if os.path.exists(c)), "lz4")
cpio_raw = os.path.join(WORK_DIR, "ramdisk_raw.cpio")
os.makedirs(WORK_DIR, exist_ok=True)
subprocess.run([lz4_bin, "-d", "-f", RAMDISK_SRC, cpio_raw], check=True)

raw_data = open(cpio_raw, "rb").read()
# Strip TRAILER
trailer_idx = raw_data.find(b"TRAILER!!!")
if trailer_idx != -1:
    base_cpio = raw_data[:trailer_idx - 110]
else:
    base_cpio = raw_data

def cpio_entry(name: str, content: bytes, mode=0o100644):
    name_bytes = name.encode('ascii') + b'\x00'
    header = (
        f"070701"                  # magic
        f"{0:08x}"                 # ino
        f"{mode:08x}"              # mode
        f"{0:08x}"                 # uid
        f"{0:08x}"                 # gid
        f"{1:08x}"                 # nlink
        f"{0:08x}"                 # mtime
        f"{len(content):08x}"      # filesize
        f"{0:08x}"                 # maj
        f"{0:08x}"                 # min
        f"{0:08x}"                 # rmaj
        f"{0:08x}"                 # rmin
        f"{len(name_bytes):08x}"   # namesize
        f"{0:08x}"                 # check
    ).encode('ascii')
    
    pad1 = b'\x00' * ((4 - (len(header) + len(name_bytes)) % 4) % 4)
    pad2 = b'\x00' * ((4 - len(content) % 4) % 4)
    return header + name_bytes + pad1 + content + pad2

def cpio_trailer():
    return cpio_entry("TRAILER!!!", b"")

fstab_content = (
    "# Android fstab for Ranchu\n"
    "system /system ext4 ro wait,logical,first_stage_mount\n"
    "system_ext /system_ext ext4 ro wait,logical,first_stage_mount\n"
    "product /product ext4 ro wait,logical,first_stage_mount\n"
    "vendor /vendor ext4 ro wait,logical,first_stage_mount\n"
    "/dev/block/by-name/metadata /metadata ext4 noatime,nosuid,nodev,discard wait,formattable,first_stage_mount,check\n"
    "/dev/block/by-name/userdata /data ext4 noatime,nosuid,nodev,discard wait,formattable,latemount,check\n"
).encode('ascii')

inject_cpio = (
    cpio_entry("first_stage_ramdisk/system/etc/fstab.ranchu", fstab_content) +
    cpio_entry("system/etc/fstab.ranchu", fstab_content) +
    cpio_entry("fstab.ranchu", fstab_content) +
    cpio_trailer()
)

combined_cpio = base_cpio + inject_cpio
combined_path = os.path.join(WORK_DIR, "combined.cpio")
open(combined_path, "wb").write(combined_cpio)

compressed_path = os.path.join(WORK_DIR, "ramdisk_injected.lz4")
subprocess.run([lz4_bin, "-l", "-z", "-f", combined_path, compressed_path], check=True)
compressed_data = open(compressed_path, "rb").read()

keys = [
    "androidboot.hardware=ranchu",
    "androidboot.boot_devices=4010000000.pcie",
    "androidboot.hardware.egl=emulation",
    "androidboot.hardware.vulkan=ranchu",
    "androidboot.serialno=EMULATOR34",
    "androidboot.verifiedbootstate=orange",
    "androidboot.qemu=1",
    "qemu=1"
]
body = ("\n".join(keys) + "\n").encode("ascii")
csum = sum(body) & 0xFFFFFFFF
footer = struct.pack("<II12s", len(body), csum, b"#BOOTCONFIG\n")
bc = body + footer

open(OUT_INITRD, "wb").write(compressed_data + bc)
print(f"Generated {OUT_INITRD} (size {os.path.getsize(OUT_INITRD)} bytes)")
