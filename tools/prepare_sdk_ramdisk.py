import struct
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
LOCALAPPDATA = os.environ.get("LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local"))

IMG_DIR = os.environ.get("ANDROID_IMAGE_DIR", os.path.join(LOCALAPPDATA, r"Android\Sdk\system-images\android-34\google_apis\arm64-v8a"))
WORK_DIR = os.environ.get("SDK_WORK_DIR", os.path.join(ROOT_DIR, "work_sdk"))
RAMDISK_SRC = os.path.join(IMG_DIR, "ramdisk.img")
RAMDISK_DST = os.path.join(WORK_DIR, "ramdisk_bc.img")
os.makedirs(WORK_DIR, exist_ok=True)

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

ramdisk_data = open(RAMDISK_SRC, "rb").read()
open(RAMDISK_DST, "wb").write(ramdisk_data + bc)
print(f"Generated {RAMDISK_DST} (original {len(ramdisk_data)} + bootconfig {len(bc)})")
