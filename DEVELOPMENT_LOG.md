# QArmDroid — Development Log

## Goal
Run Android 16 ARM64 on Snapdragon X Elite (Windows ARM64) with GPU-accelerated rendering at 60 FPS, matching MuMu Player performance.

## What Works Today

| Feature | Status | How |
|---|---|---|
| Android 16 boot (WHPX) | ✅ | QEMU + WHPX hypervisor |
| USB keyboard input | ✅ | nec-usb-xhci + usb-kbd → guest evdev |
| USB mouse pointer | ✅ | nec-usb-xhci + usb-mouse → CURSOR class |
| Touch/swipe via adb | ✅ | `adb shell input swipe/tap` |
| Resolution 1280×800 | ✅ | `wm size` override persisted |
| adb over TCP | ✅ | `adb connect 127.0.0.1:5555` |
| Init wrapper network fix | ✅ | Retry loop survives netd route flush |
| Custom QEMU with rutabaga device | ✅ | Built from source, WHPX+slirp+USB |

## Rendering Performance Status

**Current: ~10 FPS via SwiftShader CPU rendering**

The guest's ANGLE falls back to SwiftShader because the pastel Vulkan HAL
(`vulkan.pastel.so` in `com.google.cf.vulkan` apex) cannot establish gfxstream
transport over virtio-gpu.

Root cause chain:
```
QEMU virtio-gpu-rutabaga-pci device offers features correctly
    ✓ (verified: rutabaga=128 blob=32 ctx_init=64)
Guest kernel virtio_gpu driver accepts them
    ✓ (kernel rebuilt with CONFIG_DRM_VIRTIO_GPU=y)
Pastel HAL tries to create gfxstream context
    ✓ (gfxstream_backend initializes on host side)
gfxstream needs VK_KHR_external_memory for zero-copy sharing
    ✗ FAILS: dzn (D3D12→Vulkan mapping layer) doesn't support it
    ✗ Native Qualcomm driver also lacks it on Windows ARM64
    ✗ No workaround exists — requires new GPU driver from Qualcomm/Microsoft
```

## Files Created/Modified

### Core daemon (`tools/hcs_engine/`)
- `src/vulkan_host.rs` — Vulkan loader, device creation, dispatch table
- `src/dispatch.rs` — opcode dispatcher (11 opcodes) + protocol spec
- `src/render.rs` — compute render pipeline + fill fallback backend
- `src/shm_ring.rs` — shared-memory aperture ring buffer
- `src/hcs.rs` — HCS probe (vmcompute.dll sync API detection)
- `src/ctrl.rs` — console ctrl handler for graceful shutdown
- `src/lib.rs`, `src/main.rs` — library root + CLI (--serve/--render/--selftest)
- `tests/dispatch_tests.rs` — 8 integration tests (all passing)

### Launcher scripts
- `tools/launch.ps1` — main launcher (6 vCPU default, USB input, wm size fix)
- `tools/launch_vulkan.ps1` — one-command Vulkan passthrough launch
- `tools/start_scrcpy.ps1` — scrcpy display mirror (30fps/2M stable cap)

### Guest-side client
- `tools/vk_guest_client.c` + `.elf` — freestanding static ARM64 binary
  (raw syscalls, no libc; runs inside Android via adb shell)

### Host-side verification tools
- `tools/vk_passthrough_client.py` — full protocol test suite
- `tools/sendinput.ps1` — real window input injection (SendInput API)
- `tools/qmp_input.py` — QMP keyboard/mouse injection
- `tools/raw_to_png.py` — framebuffer → PNG converter
- `tools/mp4_frames.py` — MP4 frame counter for stream FPS measurement
- `tools/touch_client.py` — touch_daemon TCP client (6666 protocol)

### Kernel rebuild
- Patched config: enable DRM_VIRTIO_GPU=y, VIRTIO_INPUT=y,
  force virtio transport stack built-in (PCI/BLK/MMIO/NET/CONSOLE/RNG)
- Built in WSL Ubuntu 24.04 (native aarch64) with gcc 13.3
- Output: 32 MB Image installed to `aosp_cf_arm64_only_phone-img/out/kernel`
- Original kernel backed up as `out/kernel.orig-novirtgpu`

### QEMU+gfxstream build (`tools/qemu-gfxstream/`)
- `session.ps1` — environment bootstrap (PATH, MSVC, Rust, PKG_CONFIG_PATH)
- `build-gfxstream.ps1` — gfxstream meson+ninja build script
- `boot-gfxstream-vm.ps1` — VM boot script with gfxstream
- `BUILD_PLAN.md`, `BUILD_LOG.md`, `BUILD_STATUS.md` — progress tracking
- `rutabaga-prefix/` — installed rutabaga_gfx_ffi (dll/lib/include/pc)
- `qemu/build/qemu-system-aarch64.exe` — 107 MB custom QEMU binary
- `gfxstream/build-host/host/libgfxstream_backend-0.dll` — backend library

### Documentation
- `PERFORMANCE.md` — performance analysis and optimization guide

## Key Findings

1. **virtio-keyboard-pci has no QEMU handler** — keys die in QEMU.
   Fix: use `nec-usb-xhci` + `usb-kbd` instead.
2. **virtio-tablet receives broken MT slots** from GTK frontend —
   clicks/moves dropped ("Unexpected touch slot number: N >= 10").
   Fix: use `usb-mouse` instead.
3. **AArch64 Linux passes argc/argv on the stack**, not in x0/x1.
   Fix: naked asm stub captures sp before prologue.
4. **lld defaults to dynamic linking** — must pass `-static` explicitly.
5. **Meson replays original configure env on regenerate** — set
   PKG_CONFIG_PATH before initial configure, not after.
6. **MSYS2 pkg-config default search**: `C:\msys64\clangarm64\lib\pkgconfig`.
7. **Android init_wrapper's serial output is ~950 bytes** regardless of
   boot success — don't use serial size as a health indicator.

## Remaining Work for 60fps GPU Acceleration

1. **Guest kernel**: already rebuilt with DRM_VIRTIO_GPU=y ✓
2. **Host→guest transport**: VIRTIO_GPU_F_CONTEXT_INIT not negotiated.
   Debug logging confirms QEMU offers bit 4; guest kernel driver must accept.
   May require checking if Android 16 kernel's virtio_gpu module handles
   context-init ioctl (DRM_IOCTL_VIRTGPU_CONTEXT_INIT) properly.
3. **gfxstream external memory**: dzn lacks VK_KHR_external_memory_fd.
   Native Qualcomm driver (qcvkarm64xum.dll) also lacks it currently.
   Requires Qualcomm to ship native Vulkan ICD with external memory support.
4. **Alternative**: build complete gfxstack on Linux ARM64 host, use
   network-based rendering transport instead of local virtio-gpu.

## Quick Start (current working configuration)

```powershell
# Boot
powershell -ExecutionPolicy Bypass -File tools\launch.ps1 -DisplayMode gtk

# Connect adb
adb connect 127.0.0.1:5555

# Interact
adb shell input tap 640 400
adb shell input swipe 500 600 500 200 300
```

## Cleanup 2026-08-23 (Candidate 1 wrap-up)

Deleted launch scripts were divergent copies of launch.ps1's QEMU line.
Unique facts preserved here before deletion:
- run_vm.bat / launch-detached.bat variants used `-smp 4/8` and `blob=on`
  with no virtconsoles - both configs are superseded by launch.ps1's
  canonical shape (smp param, hvc0-15 always wired).
- boot-gfxstream-vm.ps1 duplicated gfxstream flags; see BUILD_STATUS.md.
- launch.sh was the v0 bash harness using broken virtio-keyboard/mouse
  (see Key Findings #1-2); superseded by USB HID input.
- gen_rust.py was a codegen existence-checker; cargo build subsumes it.
- Root cause of "launch.ps1 fails to boot" (fixed this session): custom QEMU
  links MSYS2 runtime DLLs from C:\msys64\clangarm64\bin which are absent
  from GUI/user PATH -> STATUS_DLL_NOT_FOUND (0xC0000135) sub-second death,
  zero stderr. Fix: PATH bootstrap at top of launch.ps1. Secondary hardening:
  $ErrorActionPreference must stay Continue (PS5.1 + native stderr banner =
  terminating NativeCommandError under Stop).

## Display-binary resolution (2026-08-23, post-cleanup)
User hit "Parameter 'type' does not accept value 'sdl'" on -DisplayMode sdl:
custom QEMU was configured --disable-gtk/--disable-sdl/--disable-vnc, so its
only backend is none (vnc also absent from msys2 stock). launch.ps1 now
probes -display help on the selected binary and auto-resolves: windowed
modes switch to msys2 QEMU with GPU forced basic; vnc degrades to none with
a visible warning. Verified via -PrintArgs matrix + live sdl spawn.

## SDL color inversion investigation (2026-08-24)
Symptom: -DisplayMode sdl shows R/B-swapped UI. Quantified via QMP screendump
vs adb screencap saturation analysis: 1007/1007 saturated pixels swapped.
Lever matrix ALL produced identical swap: bootconfig display_framebuffer_format
bgra->rgba (composer ignores it), gralloc minigbm->default (no effect),
pixman vs GL-on scanout (identical), custom-vs-msys2 binary (identical).
Conclusion: guest DRM/minigbm format-naming mismatch baked into this AOSP
image; unreachable via cmdline/props. Input over USB HID proven healthy
(HMP sendkey -> /dev/input/event1 KEY_B/C/SPACE events). Correct-color
windowed viewing remains scrcpy; color-correct GPU windows return when
Qualcomm ships VK_KHR_external_memory_win32 (unlocks gfxstream compositor).
Side-gains kept: custom QEMU rebuilt WITH sdl enabled (single binary for
headless+gfxstream+window), launcher gained -MonitorPort/-SdlGl/
-GrallockOverride switches; m0_build bootconfig/initrd caching pitfall
documented (must run bootconfig stage before initrd after edits).

## Arch review Candidate 5 complete (2026-08-24)
- Removed dead aperture transport: src/shm_ring.rs, --aperture mode,
  aperture_loop, unconditional 16 MB block; PROTOCOL.md TCP-only claim now true.
- Payload packing collapsed: 7 shared builders in dispatch.rs replace hand-
  packed byte arrays in selftest + render_to_file (single Rust definition
  per wire layout alongside the parser).
- Verified: cargo check clean, 7/7 unit tests, release selftest PASSED on
  Adreno X1-85 AFTER fixing a stale-daemon exe-lock that had made the first
  selftest run validate pre-refactor code (kill daemon, relink, re-run).
- All six architecture-review candidates now closed or deferred-by-design.
