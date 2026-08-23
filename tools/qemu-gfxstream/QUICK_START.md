# Quick Start — Android 16 ARM64 Emulator

> Canonical entry point is `tools\launch.ps1`. The old
> `tools\qemu-gfxstream\run_vm.bat` and friends were divergent copies and
> have been deleted. Current state: see root `STATUS.md`.

## Boot (headless, pairs with scrcpy)

```powershell
cd C:\Users\erict\OneDrive\Desktop\Arm64AndroidEmulator
tools\launch.ps1                 # boots headless; watchdog enforces 1280x800
adb connect 127.0.0.1:5555       # after ~2-4 min, sys.boot_completed=1
```

## Boot with a window (USB keyboard + mouse)

```powershell
tools\launch.ps1 -DisplayMode gtk    # or sdl / embedded (VNC :5901)
```

## Inspect configuration without booting

```powershell
tools\launch.ps1 -PrintArgs
```

## GPU modes

- `-GpuMode gfxstream` (default): repo-local custom QEMU with virtio-gpu-rutabaga.
  In-guest acceleration still blocked on Qualcomm shipping
  VK_KHR_external_memory_win32 — falls back to SwiftShader (~10 fps).
- `-GpuMode basic`: plain virtio-gpu-pci; also works with the stock
  msys2 QEMU via `-QemuPath C:\msys64\clangarm64\bin\qemu-system-aarch64.exe`.
