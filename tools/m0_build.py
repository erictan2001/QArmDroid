#!/usr/bin/env python3
"""
arm64droid M0 builder — assembles a bootable Cuttlefish-on-QEMU image set.

What it fixes vs the original broken pipeline:
  1. Unquoted bootconfig values (kernel parses them literally).
  2. Real fstab suffix: cf.ext4.cts (the old 'cf.virtio' never existed).
  3. vendor_ramdisk actually unpacked and included.
  4. ONE GPT disk with named partitions (super/userdata/metadata/misc) so
     first-stage init can build /dev/block/by-name/* symlinks.
  5. super.img unsparsed (it is a sparse Android image, magic ED26FF3A).
  6. adbd-over-TCP injected via appended cpio in /debug_ramdisk (scanned by
     init on userdebug builds) + static slirp network config.
"""
import os, sys, struct, subprocess, zlib, hashlib

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPT_DIR)
IMG = os.path.join(ROOT, "aosp_cf_arm64_only_phone-img")
WORK = os.path.join(IMG, "work", "m0")
MSYS_BIN = os.environ.get("MSYS_BIN", r"C:\msys64\clangarm64\bin" if os.path.exists(r"C:\msys64\clangarm64\bin") else "")

# Pure-Python image tools (lz4 / sparse / cpio) — no external binaries needed.
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)
import imgtools
LZ4 = os.path.join(MSYS_BIN, "lz4.exe")      # optional fallback only

# Overridable for bundled (installed) deployment: the installer stages the
# image inputs + pure-Python tools at bundle paths and runs
# `python m0_build.py disk QARM_BUNDLE=<dir>` to build disk.raw there.
QARM_DISK_GB = int(os.environ.get("QARM_DISK_GB", "0")) or 8   # userdata size (GB)
QARM_FS = os.environ.get("QARM_FS", "ext4").strip().lower()    # ext4 | f2fs
if QARM_FS not in ("ext4", "f2fs"):
    QARM_FS = "ext4"

BUNDLE = os.environ.get("QARM_BUNDLE")
for arg in sys.argv[1:]:
    if arg.startswith("QARM_BUNDLE="):
        BUNDLE = arg.split("=", 1)[1]

if BUNDLE:
    IMG = os.path.join(BUNDLE, "image")       # super.img, boot.img, ... here
    WORK = os.path.join(BUNDLE, "image")      # disk.raw lands next to inputs
    tools_dir = os.path.join(BUNDLE, "tools")
    if os.path.exists(tools_dir) and tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    # Bundle-scoped overrides (set by provision_bundle.ps1).
    _gb = int(os.environ.get("QARM_DISK_GB", "0"))
    if _gb:
        QARM_DISK_GB = _gb
    _fs = os.environ.get("QARM_FS", "").strip().lower()
    if _fs in ("ext4", "f2fs"):
        QARM_FS = _fs
SIMG2IMG = os.path.join(MSYS_BIN, "simg2img.exe")  # optional fallback only

DISK_NAME = "disk.raw"
USERDATA_DISK_NAME = "userdata.raw"
SECTOR = 512
GPT_HDR_LBA = 1
GPT_ENTRIES_LBA = 2
FIRST_USABLE_LBA = 2048

def run(cmd, **kw):
    print("  $", " ".join(cmd[:4]), "...")
    r = subprocess.run(cmd, capture_output=True, **kw)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
        raise SystemExit(f"command failed: {cmd[0]}")
    return r

def build_bootconfig() -> bytes:
    keys = [
        # official keys extracted from vendor_boot.img (google's own)
        "androidboot.hardware=cutf_cvm",
        "kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size=16384",
        "androidboot.vendor.apex.com.google.emulated.camera.provider.hal=com.google.emulated.camera.provider.hal",
        # multi-install APEX selection (afr.cpp ScanBuiltInDir): property
        # ro.boot.vendor.apex.<module>=<filename> keeps only the matching .apex
        # and skips the rest; without these, apexd-bootstrap FATALs on modules
        # that ship several variants. cf_remote variants need cuttlefish's host
        # secure_env daemon (we have none) -> pick the software/nonsecure ones.
        # drm_hwcomposer matches the virtio-gpu display plan for M2.
        "androidboot.vendor.apex.com.android.hardware.gatekeeper=com.android.hardware.gatekeeper.nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.keymint=com.android.hardware.keymint.rust_nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.graphics.composer=com.android.hardware.graphics.composer.drm_hwcomposer.apex",
        "androidboot.vendor.apex.com.google.cf.light=none",
        "androidboot.vendor.apex.com.google.cf.oemlock=none",
        "androidboot.vendor.apex.com.google.cf.bt=none",
        "androidboot.vendor.apex.com.google.cf.uwb=none",
        "androidboot.vendor.apex.com.android.hardware.threadnetwork=none",
        # our additions — UNQUOTED, matching fstab.cf.ext4.cts in the ramdisk
        "androidboot.fstab_suffix=cf.ext4.cts",
        "androidboot.force_normal_boot=1",
        "androidboot.veritymode=disabled",
        "androidboot.vbmeta.invalidate=yes",
        "androidboot.verifiedbootstate=orange",
        "androidboot.selinux=permissive",
        "androidboot.debuggable=1",
        "androidboot.serialno=ARM64DROID01",
        "androidboot.slot_suffix=_a",
        # first_stage_console=1 left OFF — it drops init into a shell for debugging
        # single GPT disk at PCI 00:01.0 carrying super/userdata/metadata/misc.
        # ARM virt: PCI hangs under the platform bus, so devices.cpp FindPciDevicePrefix
        # (needs /devices/pci prefix) NEVER matches; FindPlatformDevice walks up to the
        # PCIe host bridge and, after stripping /devices/platform/, yields its sysfs name.
        # Kernel log confirms: /devices/platform/3f000000.pcie/pci0000:00/0000:00:01.0/...
        "androidboot.boot_devices=3f000000.pcie",
        # Graphics stack (from device/google/cuttlefish QemuManager::ConfigureGraphics,
        # gpu_mode=guest_swiftshader — exactly our case). Without these,
        # /vendor/etc/init/init_graphics.vendor.rc setprops fail, surfaceflinger
        # aborts, zygote restarts, netd wipes eth0 in a crash loop.
        # VK_API_VERSION_1_2 = (1<<22)|(2<<12) = 4202496; GLES 3.1 = 0x30001 = 196609.
        "androidboot.cpuvulkan.version=4202496",
        "androidboot.opengles.version=196609",
        "androidboot.hardware.gralloc=minigbm",
        "androidboot.hardware.egl=angle",
        "androidboot.hardware.vulkan=pastel",
        "androidboot.hardware.hwcomposer=drm_hwcomposer",
        "androidboot.hardware.hwcomposer.display_finder_mode=drm",
        "androidboot.hardware.hwcomposer.display_framebuffer_format=bgra",
        "androidboot.hardware.hwcomposer.mode=client",
        # other ro.boot.* props init_graphics.vendor.rc / system rc expand:
        # CF_DEFAULTS_DISPLAY_DPI=240 (hdpi for 1280x800), CF_DEFAULTS_SETUPWIZARD_MODE=DISABLED,
        # hw_timeout_multiplier=3 (native arch), hypervisor.vm.supported=0 (arm64).
        "androidboot.lcd_density=240",
        "androidboot.setupwizard_mode=DISABLED",
        "androidboot.hw_timeout_multiplier=3",
        "androidboot.hypervisor.vm.supported=0",
        "androidboot.hypervisor.protected_vm.supported=0",
        # bluetooth checker service gate in vendor rc; keep the service off
        "androidboot.cuttlefish_service_bluetooth_checker=false",
    ]
    body = ("\n".join(keys) + "\n").encode("ascii")
    while len(body) % 4:
        body += b"\x00"
    checksum = sum(body) & 0xFFFFFFFF
    footer = struct.pack("<II", len(body), checksum) + b"#BOOTCONFIG\n"
    return body + footer

def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF

def gpt_entry(name: str, first_lba: int, last_lba: int, ptype: str) -> bytes:
    GUID_BASIC_DATA = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
    def guid(s: str) -> bytes:
        f = s.replace("-", "")
        b = bytes.fromhex(f)
        # GPT stores first three fields little-endian
        return b[3::-1] + b[5:3:-1] + b[7:5:-1] + b[8:16]
    e = guid(GUID_BASIC_DATA) + os.urandom(16)
    e += struct.pack("<QQ", first_lba, last_lba)
    e += struct.pack("<Q", 0)  # attrs
    e += name.encode("utf-16-le").ljust(72, b"\x00")
    assert len(e) == 128
    return e

def make_gpt(disk_path: str, parts: list):
    """parts: [(name, start_lba, size_bytes)] — writes header only."""
    total_lba = parts[-1][1] + parts[-1][2] // SECTOR + 2048
    entries = b""
    for name, start_lba, size in parts:
        last_lba = start_lba + size // SECTOR - 1
        entries += gpt_entry(name, start_lba, last_lba, "")
    entries += b"\x00" * (128 * 128 - len(entries))
    disk_guid = os.urandom(16)
    entries_crc = crc32(entries)
    hdr = b"EFI PART" + struct.pack("<I", 0x00010000) + struct.pack("<I", 92)
    hdr += struct.pack("<I", 0)  # header crc32 placeholder
    hdr += struct.pack("<I", 0)  # reserved
    hdr += struct.pack("<Q", 1)  # my_lba
    hdr += struct.pack("<Q", total_lba - 1)  # alternate
    hdr += struct.pack("<Q", FIRST_USABLE_LBA)
    hdr += struct.pack("<Q", total_lba - FIRST_USABLE_LBA)
    hdr += disk_guid
    hdr += struct.pack("<Q", GPT_ENTRIES_LBA)
    hdr += struct.pack("<I", 128)  # num entries
    hdr += struct.pack("<I", 128)  # entry size
    hdr += struct.pack("<I", entries_crc)
    # header crc over first 92 bytes with crc field zeroed
    hdr_b = bytearray(hdr[:92])
    hdr_b[16:20] = b"\x00\x00\x00\x00"
    hdr_b[16:20] = struct.pack("<I", crc32(bytes(hdr_b)))
    hdr = bytes(hdr_b).ljust(SECTOR, b"\x00")

    with open(disk_path, "r+b") as f:
        f.seek(0)
        f.write(b"\x00" * SECTOR)          # protective MBR area: keep simple
        # minimal protective MBR
        mbr = bytearray(SECTOR)
        mbr[0x1BE:0x1CE] = bytes([0x00,0x00,0x02,0x00,0xEE,0xFF,0xFF,0xFF]) + struct.pack("<I", 1) + struct.pack("<I", min(total_lba-1, 0xFFFFFFFF))
        mbr[510:512] = b"\x55\xAA"
        f.seek(0); f.write(bytes(mbr))
        f.seek(GPT_HDR_LBA * SECTOR); f.write(hdr)
        f.seek(GPT_ENTRIES_LBA * SECTOR); f.write(entries)
        # backup GPT at end
        last_lba = total_lba - 1
        bak_entries_lba = last_lba - 32
        bak_hdr = bytearray(hdr[:92])
        # my_lba <-> alternate swap
        bak_hdr[24:32] = struct.pack("<Q", last_lba)
        bak_hdr[32:40] = struct.pack("<Q", 1)
        bak_hdr[72:80] = struct.pack("<Q", bak_entries_lba)
        bak_hdr[16:20] = b"\x00\x00\x00\x00"
        bak_hdr[16:20] = struct.pack("<I", crc32(bytes(bak_hdr)))
        f.seek(bak_entries_lba * SECTOR); f.write(entries)
        f.seek(last_lba * SECTOR); f.write(bytes(bak_hdr).ljust(SECTOR, b"\x00"))
        # ensure file length and truncate when shrinking
        f.seek(total_lba * SECTOR - 1); f.write(b"\x00")
        f.truncate(total_lba * SECTOR)
    return total_lba

def sparse_copy(sparse_path: str, raw_path: str):
    """Unsparse (or copy raw) via pure-Python imgtools — no simg2img.exe."""
    imgtools.simg2img(sparse_path, raw_path)

def write_at(disk_path: str, lba: int, src_path: str):
    """stream-copy src file into disk at lba offset (sparse-friendly)."""
    off = lba * SECTOR
    size = os.path.getsize(src_path)
    CHUNK = 4 << 20
    zero_chunk = b"\x00" * CHUNK
    with open(disk_path, "r+b") as dst, open(src_path, "rb") as src:
        dst.seek(off)
        n = 0
        while True:
            b = src.read(CHUNK)
            if not b: break
            if len(b) == CHUNK and b == zero_chunk:
                dst.seek(dst.tell() + CHUNK)
            elif b == b"\x00" * len(b):
                dst.seek(dst.tell() + len(b))
            else:
                dst.write(b)
            n += len(b)
    print(f"    wrote {size/1e9:.2f} GB -> lba {lba}")

def cpio_newc(files: dict) -> bytes:
    """files: {path: bytes} or {path: (bytes, mode)}. Minimal newc cpio."""
    out = bytearray()
    ino = 721
    def rec(name, data, mode):
        nonlocal ino
        ino += 1
        hdr = "070701" + "".join(
            f"{v:08X}" for v in [
                ino, mode, 0, 0, 1, 0, len(data),
                0, 0, 0, 0, len(name) + 1, 0])
        out.extend(hdr.encode())
        out.extend(name.encode() + b"\x00")
        while len(out) % 4: out.extend(b"\x00")
        out.extend(data)
        while len(out) % 4: out.extend(b"\x00")
    rec("debug_ramdisk", b"", 0o40755)
    for path, val in files.items():
        if isinstance(val, tuple):
            data, mode = val
        else:
            data, mode = val, 0o100644
        rec(path, data, mode)
    # trailer: ino,mode,uid,gid,nlink,mtime,filesize,devmaj,devmin,rdevmaj,rdevmin,namesize,check
    hdr = "070701" + "".join(f"{v:08X}" for v in [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 11, 0])
    out.extend(hdr.encode() + b"TRAILER!!!\x00")
    while len(out) % 4: out.extend(b"\x00")
    return bytes(out)

def lz4_compress(data: bytes) -> bytes:
    """LZ4 legacy-frame compress via pure-Python imgtools (no lz4.exe)."""
    return imgtools.lz4_compress(data)

def main():
    os.makedirs(WORK, exist_ok=True)
    stage = sys.argv[1] if len(sys.argv) > 1 else "all"

    if stage in ("all", "bootconfig"):
        bc = build_bootconfig()
        open(os.path.join(WORK, "bootconfig.bin"), "wb").write(bc)
        print(f"[1/5] bootconfig: {len(bc)} bytes")

    if stage in ("all", "initrd"):
        generic = open(os.path.join(IMG, "out_init", "ramdisk"), "rb").read()
        vendor = open(os.path.join(IMG, "out_vendor", "vendor_ramdisk00"), "rb").read()
        vendor_raw = imgtools.lz4_decompress(vendor)
        vendor_raw = vendor_raw.replace(b"ro.control_privapp_permissions=enforce", b"ro.control_privapp_permissions=log    ")
        vendor = lz4_compress(vendor_raw)
        # adb over TCP + static slirp network, injected for second-stage init
        adb_rc = (
            "# arm64droid: force adbd to listen on TCP 5555 for QEMU slirp hostfwd\n"
            "on early-init\n"
            "    setprop service.adb.tcp.port 5555\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.light.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.oemlock.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.health.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.wifi.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.bt.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.nfc.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.health.storage.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.identity.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.ir.apex bind\n"
            "    mount none /dev/null /vendor/apex/com.google.cf.confirmationui.apex bind\n"
            "    mount none /dev/null /vendor/bin/hw/android.hardware.secure_element.sim bind\n"
            "    write /dev/empty.xml \"<manifest version=\\\"1.0\\\" type=\\\"device\\\"></manifest>\"\n"
            "    mount none /dev/empty.xml /vendor/etc/vintf/manifest/android.hardware.secure_element.sim.xml bind\n"
            "\n"
            "on property:sys.boot_completed=1\n"
            "    setprop service.adb.tcp.port 5555\n"
            "    restart adbd\n"
            "\n"
            "# static IP matching QEMU user-mode net (gateway 10.0.2.2, guest .15)\n"
            "on property:sys.boot_completed=1\n"
            "    exec -- /system/bin/ip addr add 10.0.2.15/24 dev eth0\n"
            "    exec -- /system/bin/ip link set eth0 up\n"
            "    exec -- /system/bin/ip route add default via 10.0.2.2\n"
        ).encode()
        # AVB bypass: strip avb/avb_keys flags from the first-stage fstab and
        # re-inject it via the appended cpio (later segments override earlier
        # ones when unpacked). Without this, init tries to build a dm-verity
        # table and dies with "Unknown androidboot.veritymode: disabled"
        # (fs_mgr only accepts enforcing/logging/eio — 'disabled' is not a
        # valid fstab-level verity mode; the gate is the fstab avb flag).
        import re as _re
        fstab_src = os.path.join(WORK, "..", "vend", "fs", "first_stage_ramdisk",
                                 "system", "etc", "fstab.cf.ext4.cts")
        if not os.path.exists(fstab_src):
            for candidate in [
                os.path.join(WORK, "..", "vend", "first_stage_ramdisk", "system", "etc", "fstab.cf.ext4.cts"),
                os.path.join(WORK, "..", "vend", "fs", "system", "etc", "fstab.cf.ext4.cts"),
                os.path.join(WORK, "..", "vend", "system", "etc", "fstab.cf.ext4.cts"),
            ]:
                if os.path.exists(candidate):
                    fstab_src = candidate
                    break
        fstab_out_lines = []
        for line in open(fstab_src).read().splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                fstab_out_lines.append(line)
                continue
            # fstab columns: src mnt_point type mnt_flags fs_mgr_flags
            # avb/avb_keys live in fs_mgr_flags = 5th column (index 4)
            fields = line.split()
            if len(fields) >= 5:
                # Honor a user-selected userdata filesystem (ext4|f2fs).
                # The /data line's fstype is column 3; only swap when the
                # partition is userdata and a non-default format was chosen.
                if QARM_FS == "f2fs" and fields[1] == "/data" and fields[0].endswith("userdata"):
                    fields[2] = "f2fs"
                flags = [f for f in fields[4].split(",")
                         if not (f == "avb" or f.startswith("avb=") or f.startswith("avb_keys="))]
                fields[4] = ",".join(flags)
                line = " ".join(fields)
            fstab_out_lines.append(line)
        fstab = ("\n".join(fstab_out_lines) + "\n").encode()
        # Ramdisk build.prop -> /second_stage_resources channel (THE fix).
        #
        # Root-cause of every failed rc-injection attempt (boots #6-#10):
        #   - second-stage init's / is the SYSTEM partition: first_stage_init
        #     does SwitchRoot("/first_stage_ramdisk"), then "Switching root to
        #     '/system'" (3.32s in the log). Ramdisk-root files are invisible
        #     to second-stage rc parsing after that (/init.environ.rc parses
        #     only because it exists at the system root).
        #   - /debug_ramdisk is mounted MS_NOEXEC (first_stage_init.cpp:400),
        #     so init never parses .rc files from it. Our arm64droid_adb.rc
        #     was dead code from boot #5 onward.
        #   - bootconfig only maps androidboot.X -> ro.boot.X
        #     (prop_service.cpp ProcessBootconfig), never ro.vendor.*.
        #
        # The channel that DOES work: second_stage_resources.h -- if
        # /system/etc/ramdisk/build.prop exists in the ramdisk (pre-switch,
        # where /system is still a ramdisk dir), first-stage init copies it
        # to /second_stage_resources/system/etc/ramdisk/build.prop. That tmpfs
        # survives both pivots (GetMounts MS_MOVE). PropertyLoadBootDefaults()
        # then calls LoadPropertiesFromSecondStageRes() FIRST (before system/
        # vendor/product build.props and before any trigger runs).
        #
        # ro.vendor.disable_rename_eth0=1 breaks the cuttlefish rename trigger
        # ("ro.vendor.disable_rename_eth0= && post-fs-data" matches only when
        # the property is empty), so eth0 keeps its name and Android's
        # EthernetService DHCPs it (QEMU slirp serves 10.0.2.15).
        # service.adb.tcp.port=5555 forces adbd's TCP listener (persist.*
        # already ships in the image; the live prop is what gates the listen).
        ramdisk_build_prop = (
            "# arm64droid: injected via /system/etc/ramdisk/build.prop ->\n"
            "# /second_stage_resources -> PropertyLoadBootDefaults (loads\n"
            "# before every init trigger; see tools/m0_build.py comments)\n"
            "ro.vendor.disable_rename_eth0=1\n"
            "service.adb.tcp.port=5555\n"
            "ro.adb.secure=0\n"
            "ro.control_privapp_permissions=log\n"
            "logd.klogd=false\n"
            "persist.logd.klogd=false\n"
            "ro.debuggable=1\n"
            "ro.serialconsole=0\n"
            "persist.sys.console=0\n"
            "ro.boot.serialconsole=0\n"
            "ro.frp.pst=/dev/block/by-name/frp\n"
            "# Performance optimizations for CPU SwiftShader & SurfaceFlinger\n"
            "persist.sys.sf.disable_blurs=1\n"
            "debug.sf.disable_blurs=1\n"
            "ro.surface_flinger.supports_background_blur=0\n"
            "ro.sf.blurs_are_expensive=1\n"
            "ro.surface_flinger.has_wide_color_display=false\n"
            "ro.surface_flinger.has_HDR_display=false\n"
            "ro.surface_flinger.use_color_management=false\n"
            "persist.sys.sf.color_mode=0\n"
            "persist.sys.sf.native_mode=1\n"
            "debug.sf.disable_backpressure=1\n"
            "debug.sf.enable_gl_backpressure=0\n"
            "debug.sf.latch_unsignaled=1\n"
            "debug.sf.enable_hwc_vds=0\n"
            "ro.surface_flinger.max_frame_buffer_acquired_buffers=3\n"
            "debug.renderengine.skia_atrace_enabled=0\n"
            "debug.hwui.use_hint_manager=true\n"
            "persist.sys.ui.hw=1\n"
            "# Disable cellular radio retry loop for non-telephony VM\n"
            "ro.radio.noril=yes\n"
            "ro.telephony.default_network=0\n"
            "ro.telephony.disable_call=true\n"
            "keyguard.no_require_sim=true\n"
            "ro.carrier=unknown\n"
            "# ART / Dalvik JIT multi-threading on 6 vCPUs\n"
            "dalvik.vm.dex2oat-threads=6\n"
            "dalvik.vm.boot-dex2oat-threads=6\n"
            "dalvik.vm.image-dex2oat-threads=6\n"
            "dalvik.vm.background-dex2oat-threads=4\n"
            "dalvik.vm.usejit=true\n"
            "dalvik.vm.usejitprofiles=true\n"
            "dalvik.vm.dex2oat-filter=speed-profile\n"
            "dalvik.vm.heapgrowthlimit=256m\n"
            "dalvik.vm.heapsize=512m\n"
            "dalvik.vm.heaptargetutilization=0.75\n"
        ).encode()
        # init wrapper (boot #11 -> #12 fix): nothing in this image ever
        # brings eth0 up. CONFIG_IP_PNP=n in the kernel (no ip= param),
        # virtio_net is module-only (eth0 appears mid-boot), the phone
        # image has no EthernetService/IpClient/DHCP, and system/vendor
        # are read-only EROFS so no rc can be injected into a partition.
        # Solution: replace /init with a tiny static aarch64 ELF wrapper
        # (tools/init_wrapper.c, built by build_init_wrapper below). It
        # forks a child that polls for eth0 and configures it via raw
        # socket ioctls (10.0.2.15/24, gw 10.0.2.2 = QEMU slirp), then
        # execs the real first-stage init as /init.orig. Network state
        # is kernel-global so it survives every switch_root after.
        wrapper = open(os.path.join(SCRIPT_DIR, "init_wrapper.elf"), "rb").read()
        touch_daemon_bin = open(os.path.join(SCRIPT_DIR, "touch_daemon.elf"), "rb").read()
        stub_daemon_bin = open(os.path.join(SCRIPT_DIR, "stub_daemon.elf"), "rb").read()
        tablet_idc_content = (
            "touch.deviceType = touchScreen\n"
            "touch.orientationAware = 1\n"
            "touch.gestureMode = default\n"
            "touch.displayId = 0\n"
            "device.internal = 1\n"
        ).encode()
        tablet_kl_content = (
            "key 272   BTN_TOUCH\n"
            "key 330   BTN_TOUCH\n"
            "key 273   BACK\n"
        ).encode()
        orig_init = open(os.path.join(IMG, "work", "init", "fs", "init"), "rb").read()
        cpio = cpio_newc({
            "init": (wrapper, 0o100755),
            "init.orig": (orig_init, 0o100755),
            "touch_daemon": (touch_daemon_bin, 0o100755),
            "stub_daemon": (stub_daemon_bin, 0o100755),
            "first_stage_ramdisk/system/etc/fstab.cf.ext4.cts": fstab,
            "system/etc/ramdisk/build.prop": ramdisk_build_prop,
            "system/etc/init/disable_serial.rc": (
                b"service crashlogger /system/bin/sh -c \"while true; do /system/bin/logcat -b crash -t 50 -d > /dev/kmsg; sleep 2; done\"\n"
                b"    class main\n"
                b"    user root\n"
                b"    seclabel u:r:su:s0\n"
                b"\n"
                b"on post-fs-data\n"
                b"    start crashlogger\n"
                b"    stop seriallogging\n"
                b"    stop console\n"
                b"on property:sys.boot_completed=1\n"
                b"    stop seriallogging\n"
                b"    stop console\n", 0o100644),
            "system/usr/idc/Vendor_1af4_Product_0006.idc": (tablet_idc_content, 0o100644),
            "system/usr/idc/Vendor_1af4_Product_0006_Version_0100.idc": (tablet_idc_content, 0o100644),
            "system/usr/idc/QEMU_Virtio_Tablet.idc": (tablet_idc_content, 0o100644),
            "system/usr/idc/Virtio_Tablet.idc": (tablet_idc_content, 0o100644),
            "system/usr/idc/virtio_tablet.idc": (tablet_idc_content, 0o100644),
            "system/usr/keylayout/Vendor_1af4_Product_0006.kl": (tablet_kl_content, 0o100644),
            "system/usr/keylayout/QEMU_Virtio_Tablet.kl": (tablet_kl_content, 0o100644),
            "system/usr/keylayout/Virtio_Tablet.kl": (tablet_kl_content, 0o100644),
            "force_debuggable": (b"", 0o100644),
            "adb_debug.prop": (b"ro.control_privapp_permissions=log\nro.adb.secure=0\nro.debuggable=1\n", 0o100644),
        })
        extra = lz4_compress(cpio)
        bc = open(os.path.join(WORK, "bootconfig.bin"), "rb").read()
        initrd = generic + vendor + extra + bc
        out = os.path.join(WORK, "initrd.img")
        open(out, "wb").write(initrd)
        print(f"[2/5] initrd: {len(initrd)} bytes "
              f"(generic {len(generic)} + vendor {len(vendor)} + inject {len(extra)} + bc {len(bc)})")

    if stage in ("all", "super"):
        raw = os.path.join(WORK, "super_raw.img")
        if not os.path.exists(raw) or os.path.getsize(raw) < 8_000_000_000:
            print("PROGRESS 62 Unsparsing super.img -> 8.59 GB raw...")
            print("[3/5] unsparse super.img -> 8.59 GB raw (this takes a while)")
            sparse_copy(os.path.join(IMG, "super.img"), raw)
        else:
            print("PROGRESS 65 super_raw.img verified")
            print("[3/5] super_raw.img already present")

    if stage in ("all", "disk", "os_disk"):
        super_raw_path = os.path.join(WORK, "super_raw.img")
        if not os.path.exists(super_raw_path) or os.path.getsize(super_raw_path) < 8_000_000_000:
            print("PROGRESS 62 Unsparsing super.img -> 8.59 GB raw...")
            print("[3/5] unsparse super.img -> 8.59 GB raw")
            sparse_copy(os.path.join(IMG, "super.img"), super_raw_path)
        super_size = os.path.getsize(super_raw_path)
        GB = 1024**3
        MB = 1024**2
        # Canonical OS disk layout without userdata (userdata is now on a dedicated disk)
        parts = []
        lba = FIRST_USABLE_LBA
        def add(name, size):
            nonlocal lba
            start = lba
            lba += (size + SECTOR - 1) // SECTOR
            lba = ((lba + 2047) // 2048) * 2048
            parts.append((name, start, size))
        add("boot_a", 64 * MB)
        add("boot_b", 64 * MB)
        add("init_boot_a", 8 * MB)
        add("init_boot_b", 8 * MB)
        add("vendor_boot_a", 64 * MB)
        add("vendor_boot_b", 64 * MB)
        add("vbmeta_a", 64 * 1024)
        add("vbmeta_b", 64 * 1024)
        add("vbmeta_system_a", 64 * 1024)
        add("vbmeta_system_b", 64 * 1024)
        add("vbmeta_system_dlkm_a", 64 * 1024)
        add("vbmeta_system_dlkm_b", 64 * 1024)
        add("vbmeta_vendor_dlkm_a", 64 * 1024)
        add("vbmeta_vendor_dlkm_b", 64 * 1024)
        add("super", super_size)
        add("metadata", 16 * MB)
        add("misc", 1 * MB)
        add("frp", 1 * MB)
        contents = {
            "boot_a": os.path.join(IMG, "boot.img"),
            "boot_b": os.path.join(IMG, "boot.img"),
            "init_boot_a": os.path.join(IMG, "init_boot.img"),
            "init_boot_b": os.path.join(IMG, "init_boot.img"),
            "vendor_boot_a": os.path.join(IMG, "vendor_boot.img"),
            "vendor_boot_b": os.path.join(IMG, "vendor_boot.img"),
            "vbmeta_a": os.path.join(IMG, "vbmeta.img"),
            "vbmeta_b": os.path.join(IMG, "vbmeta.img"),
            "vbmeta_system_a": os.path.join(IMG, "vbmeta_system.img"),
            "vbmeta_system_b": os.path.join(IMG, "vbmeta_system.img"),
            "vbmeta_system_dlkm_a": os.path.join(IMG, "vbmeta_system_dlkm.img"),
            "vbmeta_system_dlkm_b": os.path.join(IMG, "vbmeta_system_dlkm.img"),
            "vbmeta_vendor_dlkm_a": os.path.join(IMG, "vbmeta_vendor_dlkm.img"),
            "vbmeta_vendor_dlkm_b": os.path.join(IMG, "vbmeta_vendor_dlkm.img"),
            "super": os.path.join(WORK, "super_raw.img"),
        }
        disk = os.path.join(WORK, DISK_NAME)
        # Check if disk.raw already exists and is the new OS-only layout (~8.9 GB)
        need_rebuild_os = (
            not os.path.exists(disk)
            or os.path.getsize(disk) > 10 * GB
            or os.path.getsize(disk) < 8 * GB
        )
        if need_rebuild_os:
            if os.path.exists(disk):
                print(f"[4/5] Rebuilding clean OS disk (~8.9 GB, separate from userdata)...")
                try:
                    os.remove(disk)
                except Exception as e:
                    raise SystemExit(f"Cannot overwrite {disk}: {e}. Ensure emulator is stopped.")
            open(disk, "wb").close()
            subprocess.run(["fsutil", "sparse", "setflag", disk], capture_output=True)
            print("PROGRESS 72 Assembling OS disk GPT partition table...")
            total = make_gpt(disk, parts)
            print(f"[4/5] OS GPT disk: {total*SECTOR/1e9:.2f} GB virtual, parts: " +
                  ", ".join(f"{n}@{s*SECTOR/1e9:.2f}G" for n, s, _ in parts))
            
            written_count = 0
            total_parts_to_write = sum(1 for n, _, _ in parts if n in contents and os.path.exists(contents[n]))
            for name, start, size in parts:
                if name in contents and os.path.exists(contents[name]):
                    written_count += 1
                    pct = 75 + int((written_count / max(1, total_parts_to_write)) * 20)
                    print(f"PROGRESS {pct} Writing partition: {name} ({size/1e6:.1f} MB)...")
                    write_at(disk, start, contents[name])
            print("[4/5] OS disk content written (metadata/misc left zero -> formatted by guest)")
        else:
            print(f"[4/5] OS disk {disk} already present and valid ({os.path.getsize(disk)/1e9:.2f} GB) - reusing")

    if stage in ("all", "disk", "userdata"):
        GB_DECIMAL = 10**9   # AOSP roundStorageSize() uses decimal GB tiers (8e9, 16e9, 32e9...)
        GB = 1024**3
        userdata_disk = os.path.join(WORK, USERDATA_DISK_NAME)
        # In AOSP, Settings storage total is calculated by:
        #   FileUtils.roundStorageSize(DataDirectory.getTotalSpace() + RootDirectory.getTotalSpace())
        # and System size is:
        #   Total - DataDirectory.getTotalSpace()
        #
        # RootDirectory (/system) is ~725 MB. If userdata partition is a full 8.0 GB,
        # Data + Root totals ~8.4 GB which exceeds 8.0 GB and causes AOSP to round up
        # to 16 GB (showing 8.2 GB used as "Android System").
        # By reserving 800 MB for system partitions (matching real OEM device partitioning),
        # Data + Root <= target tier (e.g. 7.2 GB + 0.725 GB = 7.925 GB <= 8.0 GB),
        # so roundStorageSize() reports exactly QARM_DISK_GB (e.g. 8.0 GB total, ~1.1 GB system).
        SYSTEM_RESERVE_BYTES = 800_000_000
        userdata_part_bytes = max(10**9, QARM_DISK_GB * GB_DECIMAL - SYSTEM_RESERVE_BYTES)
        parts_u = [("userdata", FIRST_USABLE_LBA, userdata_part_bytes)]
        expected_total_lba = FIRST_USABLE_LBA + userdata_part_bytes // SECTOR + 2048
        expected_total_bytes = expected_total_lba * SECTOR
        
        need_rebuild_u = not os.path.exists(userdata_disk)
        if os.path.exists(userdata_disk):
            # Check length against target
            u_len = os.path.getsize(userdata_disk)
            if abs(u_len - expected_total_bytes) > 4096:
                need_rebuild_u = True
            # Also check fstype
            fstype_path = os.path.join(WORK, "userdata.fstype")
            if os.path.exists(fstype_path):
                cur_fs = open(fstype_path).read().strip().lower()
                if cur_fs and cur_fs != QARM_FS:
                    need_rebuild_u = True

        if need_rebuild_u or stage == "userdata":
            print(f"PROGRESS 96 Assembling dedicated userdata.raw ({QARM_DISK_GB} GB target, {userdata_part_bytes/1e9:.2f} GB partition)...")
            if os.path.exists(userdata_disk):
                try:
                    os.remove(userdata_disk)
                except Exception as e:
                    raise SystemExit(f"Cannot overwrite {userdata_disk}: {e}. Ensure emulator is stopped.")
            open(userdata_disk, "wb").close()
            subprocess.run(["fsutil", "sparse", "setflag", userdata_disk], capture_output=True)
            total_u = make_gpt(userdata_disk, parts_u)
            actual_bytes = total_u * SECTOR
            print(f"[4/5] Dedicated userdata GPT disk: {actual_bytes/1e9:.3f} GB "
                  f"(partition {userdata_part_bytes/1e9:.2f} GB, AOSP tier {QARM_DISK_GB} GB)")
        else:
            print(f"[4/5] Dedicated userdata disk {userdata_disk} already present with matching size ({QARM_DISK_GB} GB)")

        with open(os.path.join(WORK, "userdata.fstype"), "w") as f:
            f.write(QARM_FS)
        try:
            import json
            cfg_path = os.path.join(os.path.dirname(WORK), "image_config.json")
            cfg = {}
            if os.path.exists(cfg_path):
                try:
                    cfg = json.load(open(cfg_path))
                except Exception:
                    cfg = {}
            cfg["userdata_fs"] = QARM_FS
            cfg["userdata_size_gb"] = QARM_DISK_GB
            json.dump(cfg, open(cfg_path, "w"), indent=2)
        except Exception:
            pass
        if QARM_FS == "f2fs":
            print(f"[4/5] userdata will be formatted as f2fs ({QARM_DISK_GB} GB) on first boot")
        else:
            print(f"[4/5] userdata will be formatted as ext4 ({QARM_DISK_GB} GB) on first boot")

    if stage in ("all", "summary"):
        print("[5/5] artifacts:")
        for f in ["bootconfig.bin", "initrd.img", DISK_NAME, USERDATA_DISK_NAME]:
            p = os.path.join(WORK, f)
            if os.path.exists(p):
                print(f"    {p}  ({os.path.getsize(p)} bytes)")
            p = os.path.join(WORK, f)
            if os.path.exists(p):
                print(f"    {p}  ({os.path.getsize(p)} bytes)")
        print("\nQEMU launch line:")
        qemu_bundle = os.path.join(BUNDLE, "qemu", "qemu-system-aarch64.exe") if BUNDLE else ""
        if qemu_bundle and os.path.exists(qemu_bundle):
            qemu = qemu_bundle
        elif MSYS_BIN and os.path.exists(os.path.join(MSYS_BIN, "qemu-system-aarch64.exe")):
            qemu = os.path.join(MSYS_BIN, "qemu-system-aarch64.exe")
        else:
            qemu = "qemu-system-aarch64.exe"
        kernel = os.path.join(IMG, "out", "kernel")
        print(f'  "{qemu}" -accel whpx -cpu host -machine virt,gic-version=3,highmem=on -m 6G -smp 6 '
              f'-kernel "{kernel}" -initrd "{WORK}\\initrd.img" '
              f'-drive file="{WORK}\\{DISK_NAME}",format=raw,if=none,id=disk '
              f'-device virtio-blk-pci,drive=disk,addr=01.0 '
              f'-netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-10.0.2.15:5555 '
              f'-device virtio-net-pci,netdev=net0 '
              f'-serial file:{WORK}\\serial.log -monitor none -display none -no-reboot '
              f'-append "console=ttyAMA0 earlycon=pl011,0x9000000 printk.devkmsg=on audit=1 panic=-1 8250.nr_uarts=1 binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig"')

if __name__ == "__main__":
    main()



