# Quick Start — QArmDroid (Android 16 ARM64 Emulator)

> Canonical entry point is `tools\launch.ps1` for just launching, or
> **`tools\reproduce.ps1`** for the one-shot clone→working pipeline
> (env detect → patches → image unpack → bootartifacts → launch → verify).
> Current state: see root `STATUS.md` / `README.md`.

## One-shot reproduce (fresh clone)

```powershell
cd <clone>\QArmDroid
.\tools\reproduce.ps1 -ImageZip C:\path\to\aosp_cf_arm64_only_phone-img-<build>.zip
# subsequent runs: .\tools\reproduce.ps1   (reuses existing image + artifacts)
```

Manual steps equivalent:

```powershell
.\tools\bootstrap_env.ps1                       # detect python/adb/qemu -> env.json
.\tools\apply_patches.ps1                       # apply custom QEMU/gfxstream patches
.\tools\setup_image.ps1 -ImageZip <img.zip>     # unpack image (first time only)
python tools\m0_build.py bootconfig
python tools\m0_build.py initrd
python tools\m0_build.py disk                   # if disk.raw missing (slow)
tools\launch.ps1 -DisplayMode sdl -GpuMode basic
```

> No msys2 / busybox / lz4.exe / simg2img.exe needed for the build pipeline:
> `tools\imgtools.py` implements lz4 + sparse + cpio in pure Python (stdlib).

## Boot (headless, pairs with scrcpy)

```powershell
cd <clone>\QArmDroid
tools\launch.ps1                 # boots headless; watchdog enforces 1280x800
adb connect 127.0.0.1:5555       # after ~2-4 min, sys.boot_completed=1
```

## Display modes & binary auto-selection

The repo-local custom QEMU is headless-only (`--disable-gtk --disable-sdl --disable-vnc`).
launch.ps1 probes `-display help` and resolves automatically:

| Requested | Resolved |
|---|---|
| none / scrcpy | custom QEMU + chosen GpuMode |
| sdl / gtk / egl-headless | msys2 stock QEMU, GPU forced basic |
| embedded / vnc | no installed QEMU has vnc -> degrades to none with warning |

## Boot with a window (USB keyboard + mouse)

```powershell
tools\launch.ps1 -DisplayMode gtk    # or sdl / embedded (VNC :5901)
```

## Inspect configuration without booting

```powershell
tools\launch.ps1 -PrintArgs
```

## GPU modes

- `-GpuMode basic` (default): plain virtio-gpu-pci; also works with the stock
  msys2 QEMU via `-QemuPath C:\msys64\clangarm64\bin\qemu-system-aarch64.exe`.
- `-GpuMode gfxstream`: repo-local custom QEMU with virtio-gpu-rutabaga.
  In-guest acceleration still blocked on Qualcomm shipping
  VK_KHR_external_memory_win32 — falls back to SwiftShader (~10 fps).

