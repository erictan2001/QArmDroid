# QArmDroid — ARM64 Android Emulator for Windows (Snapdragon X Elite)

A working **Android 16 (Baklava) Cuttlefish ARM64 emulator** for **Windows 11 on
ARM64** (Qualcomm Snapdragon X Elite / Plus, Surface Pro 11, ThinkPad T14s, ...),
accelerated by **Windows Hypervisor Platform (WHPX)** with a SwiftShader guest
GPU — fully usable today: **boot, display, touch, keyboard, audio, ADB**.

> **GPU passthrough (gfxstream/ranchu) is documented but NOT working yet** —
> blocked by a Windows-ARM64 platform limitation. See [GPU passthrough status](#gpu-passthrough-status).

---

## 🎬 Showcase Demo

<p align="center">
  <video src="https://github.com/erictan2001/QArmDroid/raw/main/examples/showcase-demo.mp4" controls="controls" width="100%" style="border-radius: 8px;">
    <a href="https://github.com/erictan2001/QArmDroid/raw/main/examples/showcase-demo.mp4">▶️ Watch / Download Showcase Demo Video (showcase-demo.mp4 — 7 MB)</a>
  </video>
</p>

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

## 📦 Standalone Installer (Recommended)

If you want to run Android 16 on your Windows ARM64 device without manually building QEMU or fetching multi-gigabyte system images, download the **self-contained standalone installer**:

### 📥 Download
* **Latest GitHub Release**: [QArmDroid Releases](https://github.com/erictan2001/QArmDroid/releases)
* **Latest CI Build Artifacts**: Download `QArmDroid-Windows-Installer` from the latest green [GitHub Actions Run](https://github.com/erictan2001/QArmDroid/actions/workflows/build.yml).

### ✨ What's Included (100% Self-Contained)
The Windows ARM64 `.msi` package bundles everything required to run out of the box:
* **Custom-Patched QEMU ARM64**: Built with WHPX acceleration, custom touchscreen HID digitizer, rutabaga ExternalBlob support, and SDL letterboxing.
* **Android 16 (Baklava) System**: Pre-processed AOSP Cuttlefish ARM64 images (`kernel`, `initrd.img`, `super.img`, `boot.img`).
* **Tooling & Connectivity**: Bundled Scrcpy v3.3.4 and Google ADB platform-tools.
* **Zero-Setup Provisioning**: Embedded Python 3.12 ARM64 runtime that automatically provisions and initializes the userdata storage in `%LOCALAPPDATA%\QArmDroid` on first launch.

### 🚀 Installation & First Launch
1. Ensure **Windows Hypervisor Platform** is enabled:
   * Open **Windows Settings** → **System** → **Optional features** → **More Windows features** → check **Windows Hypervisor Platform** (reboot if prompted).
2. Run `QArmDroid.msi` to complete the guided setup.
3. Launch **QArmDroid** from your Start Menu or Desktop. On initial launch, the embedded provisioner prepares the local storage and boots directly to the Android 16 home screen.

---

## 🛠️ Building & Reproducing from Source

### 1. Set Up the Repository

Clone the repository and initialize the required submodules (`qemu` and `gfxstream`):

```powershell
# Clone the repository
git clone https://github.com/erictan2001/QArmDroid.git
cd QArmDroid

# Initialize required submodules (pinned to upstream releases)
git submodule update --init --recursive tools/qemu-gfxstream/qemu tools/qemu-gfxstream/gfxstream
```

> [!TIP]
> Initializing the specific submodules above (`tools/qemu-gfxstream/qemu` and `tools/qemu-gfxstream/gfxstream`) avoids downloading the massive ~10 GB Android kernel source tree (`kernel-src/common`), which is not needed for building or running the emulator.

### 2. Environment & Boot Pipeline

```powershell
.\tools\bootstrap_env.ps1     # 1. detect python/adb/qemu -> tools\env.json
.\tools\apply_patches.ps1     # 2. apply custom QEMU/gfxstream patches (idempotent)
.\tools\setup_image.ps1 -ImageZip C:\path\to\aosp_cf_arm64_only_phone-img-<build>.zip   # 3. unpack image (first run only)
.\tools\reproduce.ps1         # 4. build bootconfig->initrd->disk + launch + verify
```

`tools\reproduce.ps1` is the ONE-SHOT entry: it runs environment detection,
patches, image setup (if you pass `-ImageZip`), rebuilds the boot artifacts in
the **correct order** (bootconfig → initrd), launches QEMU
(`-DisplayMode sdl -GpuMode basic`), and waits for `sys.boot_completed=1`.

### Image download (one-time, ~2 GB)

The Android 16 Cuttlefish **arm64** image is not in this repo. Get it from
[ci.android.com](https://ci.android.com) → branch `aosp-main` → target
**`aosp_cf_arm64_only_phone-userdebug`** → build artifacts →
`aosp_cf_arm64_only_phone-img-<BUILD_ID>.zip`. (The old `fetch_cvd` wrapper in
this repo was a 404 when last tested — download via the web UI instead.)

`setup_image.ps1 -ImageZip <zip>` unzips it and runs the unpack steps
(`init_boot.img`→`out_init/ramdisk`, `vendor_boot.img`→`out_vendor/vendor_ramdisk00`,
cpio-extraction of both ramdisks) using **pure-Python tooling** — no msys2,
busybox, lz4.exe, or simg2img.exe required.

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
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 shell getprop sys.boot_completed
#    → 1
```

### Launch script options

```powershell
tools\launch.ps1 -DisplayMode <sdl|gtk|none|scrcpy|vnc> -GpuMode <basic|gfxstream> [-Memory 6G] [-Cores 6] [-PrintArgs]
```

* `-DisplayMode sdl / gtk` — native window (recommended).
* `-DisplayMode none / scrcpy` — headless + external scrcpy client.
* `-GpuMode basic` — plain `virtio-gpu-pci`; works on **any** aarch64 QEMU
  (repo-local custom build, msys2 package, or PATH binary).
* `-GpuMode gfxstream` — `virtio-gpu-rutabaga-pci` (repo-local custom QEMU);
  see [GPU passthrough status](#gpu-passthrough-status).
* `-PrintArgs` — print the resolved QEMU argv without booting (safe diffing).

### Prerequisites (minimal)

1. **Windows 11 ARM64** with **Windows Hypervisor Platform** enabled
   (Settings → Optional features → Windows Hypervisor Platform).
2. **Python 3** on PATH — used by `m0_build.py`, `imgtools.py`,
   `setup_image.ps1`. **That's it for the build pipeline**: image compression,
   sparse expansion and cpio extraction are pure-Python (`tools/imgtools.py`).
3. **ADB platform-tools** (`adb.exe`) — any location; pass `-Adb` to
   `bootstrap_env.ps1` if not at the default spots.
4. **QEMU aarch64** — either the repo-local custom build
   (`tools\qemu-gfxstream\qemu\build\qemu-system-aarch64.exe`, requires
   building from source with the msys2 toolchain — see BUILD_LOG.md), or any
   stock aarch64 QEMU (e.g. `pacman -S mingw-w64-clang-aarch64-qemu` for the
   custom build's runtime DLLs, or a PATH-installed binary).
5. The **Cuttlefish ARM64 image** (see "Image download" above).

---

## 🏗️ Repository Layout (What Matters)

```
QArmDroid/
├── src/                        # React + TypeScript Vite frontend (UI & setup panels)
├── src-tauri/                  # Rust Tauri application host (windowing, VNC, lifecycle)
├── tools/                      # Automation, launchers & build pipelines
│   ├── reproduce.ps1           # ★ ONE-SHOT reproduce: env + patches + image + build + launch + verify
│   ├── launch.ps1              # Canonical QEMU launcher (single source of argv)
│   ├── m0_build.py             # bootconfig / initrd / GPT disk generator (pure-Python tools)
│   ├── provision_bundle.ps1    # Automated installer provisioning & disk builder
│   ├── stage_bundle.ps1        # Bundles QEMU, Python, images & tools into installer
│   ├── bootstrap_env.ps1       # detect python/adb/qemu -> tools/env.json (machine-independent)
│   ├── apply_patches.ps1       # apply custom QEMU/gfxstream patches to nested sources
│   ├── setup_image.ps1         # unpack Cuttlefish image zip -> m0_build layout (pure-Python)
│   ├── imgtools.py             # ★ pure-Python lz4 / sparse-unsparse / cpio (no msys2/busybox)
│   └── qemu-gfxstream/         # Custom QEMU 11 + gfxstream/rutabaga submodules & patches
│       └── patches/            # Custom patches applied to upstream sources
├── docs/                       # Project documentation & logs
│   ├── DECISION_LOG.md         # Full engineering decision history
│   ├── history/                # Development, performance & project history logs
│   └── research/               # Architecture & GPU passthrough research
├── STATUS.md                   # Single source of truth for project status
└── README.md
```

### How the repo stays reproducible

The nested repos `tools/qemu-gfxstream/qemu` and `gfxstream` are **submodules**
pinned to upstream commits (`qemu/qemu` tag `v11.0.0` and `google/gfxstream` commit `46d937b`).
All custom modifications (ExternalBlob `renderer-features` property, SDL color-format mapping,
USB HID fix, gfxstream Windows bincompat + POSIX shim headers) live in
`tools/qemu-gfxstream/patches/` and are applied cleanly and idempotently by
`apply_patches.ps1`. A fresh clone gets the patches, the pure-Python build tools,
and only needs the image + python + ADB + QEMU from outside the repo.

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
> density fix to silently not apply — see `docs/DECISION_LOG.md`.)

---

## 🎮 GPU Passthrough Status

**Blocked by a Windows-ARM64 platform limitation — not by this repo.**

| Path | Host GLES | Host Vulkan | Works? |
|------|-----------|-------------|--------|
| SDL + basic (SwiftShader) | — | — | ✅ **Working** |
| gfxstream/ranchu (Vulkan-only) | ❌ | ✅ | ❌ SurfaceFlinger needs GLES interop |

**Root cause chain** (details in `docs/research/GPU_PASSTHROUGH_DECISION.md`):
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