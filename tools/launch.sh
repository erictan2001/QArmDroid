#!/bin/bash
# arm64droid launch harness v0 — Cuttlefish ARM64 on QEMU+WHPX
# NOTE: QEMU is a Windows binary; it needs native C:\ paths, not MSYS /c/ paths.
set -u
msys_to_win() { cygpath -w "$1"; }

ROOT="/c/Users/erict/OneDrive/Desktop/Arm64AndroidEmulator"
IMG="$ROOT/aosp_cf_arm64_only_phone-img"
M0="$IMG/work/m0"
QEMU="/c/msys64/clangarm64/bin/qemu-system-aarch64.exe"
MEM="${MEM:-6G}"
SMP="${SMP:-6}"
# DISPLAY_MODE: sdl (plan default — QEMU SDL window first, Tauri panel later)
# or none for headless adb debugging.
DISPLAY_MODE="${DISPLAY_MODE:-sdl}"

: > "$M0/serial.log"
exec "$QEMU" \
  -accel whpx \
  -cpu host \
  -machine virt,gic-version=3,highmem=on \
  -m "$MEM" -smp "$SMP" \
  -kernel "$(msys_to_win "$IMG/out/kernel")" \
  -initrd "$(msys_to_win "$M0/initrd.img")" \
  -drive "file=$(msys_to_win "$M0/disk.raw"),format=raw,if=none,id=disk" \
  -device virtio-blk-pci,drive=disk,addr=01.0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-10.0.2.15:5555,hostfwd=udp:127.0.0.1:6666-10.0.2.15:6666 \
  -device virtio-net-pci,netdev=net0,addr=02.0 \
  -device virtio-gpu-pci,addr=03.0 \
  -device virtio-keyboard-pci \
  -device virtio-mouse-pci \
  -display "$DISPLAY_MODE" \
  -serial stdio \
  -serial "file:$(msys_to_win "$ROOT/logcat_serial.log")" \
  -monitor none \
  -no-reboot \
  -append "console=ttyAMA0 earlycon=pl011,0x9000000 printk.devkmsg=on audit=0 panic=-1 8250.nr_uarts=4 binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig"
