# ARM64 Android Emulator for Windows (Snapdragon X Elite)

A working **Android 16 (Baklava) Cuttlefish ARM64 emulator** for **Windows 11 on
ARM64** (Qualcomm Snapdragon X Elite / Plus, Surface Pro 11, ThinkPad T14s, ...),
accelerated by **Windows Hypervisor Platform (WHPX)** with a SwiftShader guest
GPU — fully usable today: **boot, display, touch, keyboard, audio, ADB**.

> **GPU passthrough (gfxstream/ranchu) is documented but NOT working yet** —
> blocked by a Windows-ARM64 platform limitation. See [GPU passthrough status](#gpu-passthrough-status).

---

## ✅ Working Today (Verified)

| Feature | Status | Notes |
|---------|--------|-------|
| Boot to launcher | ✅ | Android 16 (Baklava), AOSP Cuttlefish image |
| Display (SDL window) | ✅ | 1280x800, correct colors (R/B swap fixed) |
| Touch | ✅ | USB-tablet absolute pointer |
| Keyboard | ✅ | USB HID keyboard |
| Audio | ✅ | virtio-sound (virtio_snd driver) |
| ADB over TCP | ✅ | `adb connect 127.0.0.1:5555` |
| GPU (guest) | ✅ | SwiftShader (CPU, ~11 fps — usable for dev) |
| Virtualization | ✅ | WHPX (`-accel whpx -cpu host`) |

---

## 🚀 Quick Start (Reproduce)

Everything needed is in this repo (QEMU build, launch scripts, image pipeline).
Run one script — it rebuilds the boot artifacts in the **correct order**
(bootconfig → initrd → disk) and launches:

```powershell
cd C:\Users\erict\OneDrive\Desktop\Arm64AndroidEmulator
tools\reproduce.ps1
```

`tools\reproduce.ps1` does:
1. Preflight-checks the Cuttlefish image pieces (`boot.img`, `super.img`,
   `out_init/ramdisk`, `out_vendor/vendor_ramdisk00`, ...).
2. Rebuilds `bootconfig` then `initrd` — **order matters**: the `initrd` stage
   embeds the *existing* `bootconfig.bin`, so `bootconfig` must run first.
   Includes `androidboot.lcd_density=240` (hdpi for 1280x800 — prevents the
   cut-off launcher / missing nav bar).
3. Builds `disk.raw` (GPT, 16 GB sparse) if missing.
4. Launches QEMU: `-DisplayMode sdl -GpuMode basic`.
5. Waits for boot, applies the runtime display fix (`wm size 1280x800;
   wm density 240`), prints the resolved display.

### Manual / step-by-step

```powershell
# 1. Build boot artifacts (ORDER: bootconfig then initrd!)
python tools/m0_build.py bootconfig
python tools/m0_build.py initrd
#    (fresh disk only needed once)
python tools/m0_build.py disk

# 2. Launch
tools\launch.ps1 -DisplayMode sdl -GpuMode basic

# 3. Connect (another terminal)
C:\platform-tools\adb.exe connect 127.0.0.1:5555
C:\platform-tools\adb.exe -s 127.0.0.1:5555 shell getprop sys.boot_completed
#    → 1
```

### Launch script options

```powershell
tools\launch.ps1 -DisplayMode <sdl|gtk|none|scrcpy|vnc> -GpuMode <basic|gfxstream> [-Memory 6G] [-Cores 6] [-PrintArgs]
```

* `-DisplayMode sdl / gtk` — native window (recommended).
* `-DisplayMode none / scrcpy` — headless + external scrcpy client.
* `-GpuMode basic` — plain `virtio-gpu-pci`; works on **any** QEMU incl. the
  stock msys2 binary (`C:\msys64\clangarm64\bin\qemu-system-aarch64.exe`).
* `-GpuMode gfxstream` — `virtio-gpu-rutabaga-pci` (repo-local custom QEMU);
  see [GPU passthrough status](#gpu-passthrough-status).
* `-PrintArgs` — print the resolved QEMU argv without booting (safe diffing).

### Prerequisites

1. **Windows 11 ARM64** with **Windows Hypervisor Platform** enabled
   (Settings → Optional features → Windows Hypervisor Platform).
2. **QEMU**: either the repo-local custom build
   (`tools\qemu-gfxstream\qemu\build\qemu-system-aarch64.exe`) or the stock
   msys2 clangarm64 package: `pacman -S mingw-w64-clang-aarch64-qemu`.
3. **Python 3** on PATH (used by `m0_build.py`).
4. **ADB platform-tools** at `C:\platform-tools\adb.exe` (or edit the paths in
   the scripts).
5. The **Cuttlefish ARM64 image** extracted into `aosp_cf_arm64_only_phone-img\`
   (`boot.img`, `super.img`, `init_boot.img`, `vendor_boot.img`, plus the
   unpacked ramdisks in `out_init\` / `out_vendor\`).

---

## 🏗️ Repository Layout (What Matters)

```
Arm64AndroidEmulator/
├── tools/
│   ├── reproduce.ps1           # ★ ONE-SHOT reproduce: build + launch + verify
│   ├── launch.ps1              # Canonical QEMU launcher (single source of argv)
│   ├── m0_build.py             # bootconfig / initrd / GPT disk generator
│   ├── build_gfxstream_msvc.bat# MSVC/clang-cl gfxstream build (WIP, blocked)
│   └── qemu-gfxstream/         # Custom QEMU 11 + gfxstream/rutabaga sources
├── aosp_cf_arm64_only_phone-img/  # Cuttlefish image + work/m0 artifacts (gitignored)
├── DECISION_LOG.md             # Full engineering decision history
├── GPU_PASSTHROUGH_DECISION.md # Honest GPU-passthrough assessment
├── docs/research/GPU_PASSTHROUGH_RETHOUGHT.md  # Deep dive into EGL/Vulkan paths
└── README.md
```

---

## 🖥️ Display Pipeline (how the fixes work)

```
virtio-gpu-pci (xres=1280, yres=800)
  → guest kernel framebuffer (video=virtio-fb:1280x800@60)
  → SurfaceFlinger @ density 240 (androidboot.lcd_density=240)
  → SDL window 1280x800
```

Three coordinated fixes prevent the cut-off launcher / missing nav bar:

1. **`video=virtio-fb:1280x800@60`** (kernel cmdline) — framebuffer matches the
   virtio-gpu device.
2. **`androidboot.lcd_density=240`** (kernel cmdline **and** bootconfig) —
   hdpi density at boot, so the launcher never lays out for a taller phone
   screen. The bootconfig value is what actually sticks; cmdline is a backup.
3. **Runtime watchdog** (`wm size 1280x800; wm density 240` after
   `sys.boot_completed=1`) — belt-and-suspenders re-assertion.

> ⚠️ If you rebuild `initrd.img`, always rebuild `bootconfig` first — the
> initrd embeds the existing `bootconfig.bin`. (This exact mistake caused the
> density fix to silently not apply — see DECISION_LOG.)

---

## 🎮 GPU Passthrough Status

**Blocked by a Windows-ARM64 platform limitation — not by this repo.**

| Path | Host GLES | Host Vulkan | Works? |
|------|-----------|-------------|--------|
| SDL + basic (SwiftShader) | — | — | ✅ **Working** |
| gfxstream/ranchu (Vulkan-only) | ❌ | ✅ | ❌ SurfaceFlinger needs GLES interop |

**Root cause chain** (details in `GPU_PASSTHROUGH_DECISION.md`):
1. gfxstream's host GLES renderer uses **WGL (desktop OpenGL)** → **no native
   desktop OpenGL on Windows ARM64** → `x-gfxstream-gles` capset crashes QEMU.
2. MinGW build additionally skips the static EGL dispatch (`#if
   !defined(__MINGW64__)`), so `glInteropSupported=false`.
3. MSVC/clang-cl rebuild is the correct toolchain but is **blocked by
   `#include_next` header-chain incompatibilities** with the MSVC CRT
   (ctime/clock_t, min/max macros, PATH_MAX) — a multi-week port.
4. Even with gfxstream fixed, host Vulkan on ARM64 goes through **dzn**
   (D3D12→Vulkan) which **lacks `VK_KHR_external_memory_fd`** — no zero-copy
   GPU sharing until Qualcomm ships a native Vulkan ICD for Windows ARM64.

**Options**: accept SwiftShader for dev, wait for Qualcomm/Microsoft/Google to
ship native GPU passthrough, or remote-render from a Linux ARM64 host.

---

## 📜 License

Open Source — Apache 2.0 / MIT (see individual files).