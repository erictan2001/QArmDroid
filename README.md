# ARM64 Android Emulator for Windows (Snapdragon X Elite)

A high-performance, open-source Android 16 (Baklava) emulator designed specifically for **Windows 11 on ARM64** (Qualcomm Snapdragon X Elite / Plus, Surface Pro 11, ThinkPad T14s, etc.).

This project achieves full, bare-metal speed virtualization through **Windows Hypervisor Platform (WHPX)** with **direct in-GUI display rendering**, hardware touch/pointer tracking via `virtio-tablet`, and native ADB networking.

---

## 🚀 Key Features

* **Direct Embedded GUI Display**: Live Android screen stream rendered directly inside the Tauri window via hardware-accelerated HTML5 Canvas (`@novnc/novnc` WebSocket RFB).
* **Native Virtualization (WHPX)**: Near-zero CPU overhead with `-accel whpx -cpu host` (no instruction translation / emulation needed).
* **Interactive Navigation & Hardware Controls**: Back, Home, Recents, Volume, Power, and Direct Text Typing integrated into the app toolbar.
* **VirtIO Subsystems**: VirtIO Block (GPT storage), VirtIO Net (slirp with port forwarding on `127.0.0.1:5555`), VirtIO GPU (SwiftShader Vulkan CPU / ANGLE), and VirtIO Tablet (1:1 absolute touch tracking).
* **Cross-Platform Tooling**: Includes both a native PowerShell launcher (`tools/launch.ps1`) and a Tauri v2 desktop application.

---

## 🏗️ Repository Architecture

```
Arm64AndroidEmulator/
├── src/                        # React + TypeScript Frontend (Vite)
│   ├── App.tsx                 # Embedded VNC screen & Navigation Toolbar
│   ├── App.css                 # Dark-mode styling and responsive canvas layout
│   └── main.tsx                # App entrypoint
├── src-tauri/                  # Rust Backend (Tauri v2)
│   ├── src/lib.rs              # VM lifecycle management, ADB bridge, status polling
│   ├── tauri.conf.json         # Window configuration & permissions
│   └── Cargo.toml              # Rust crate dependencies
├── tools/                      # Emulator Build & Launch Toolchain
│   ├── launch.ps1              # Native PowerShell launch harness (GUI / Headless / Embedded)
│   ├── launch.ps1              # Canonical launcher (Build-QemuArgs)
│   ├── m0_build.py             # Composite GPT disk, bootconfig, and initrd generator
│   ├── init_wrapper.c          # Custom static aarch64 ELF early init wrapper
│   ├── init_wrapper.elf        # Pre-built static ELF binary
│   ├── diag/                   # Diagnostic & probing utilities
│   └── mkbootimg/              # Android boot image packing/unpacking tool
├── research/                   # Engineering Whitepapers & Docs
│   ├── android-on-arm64-pc.md  # Comprehensive research paper on ARM64 Android on Windows
│   ├── docs/                   # Reference documentation & specs
│   └── aosp-src/               # AOSP source reference headers & implementations
├── screenshot.png              # Android 16 live boot verification screenshot
├── package.json                # NPM configuration & dependencies
└── README.md
```

---

## 🛠️ Prerequisites

1. **Windows 11 ARM64 PC**: (Qualcomm Snapdragon X Elite / Plus, Surface Pro 11, etc.).
2. **Enable Virtualization**:
   * Turn on **Windows Hypervisor Platform** (`whpx`) in *Turn Windows features on or off*.
3. **QEMU ARM64 (CLANGARM64 Toolchain)**:
   * Install MSYS2 and install QEMU aarch64:
     ```bash
     pacman -S mingw-w64-clang-aarch64-qemu
     ```
   * Ensure QEMU is present at `C:\msys64\clangarm64\bin\qemu-system-aarch64.exe`.
4. **Node.js & Rust**:
   * Node.js v18+ and Rust (`cargo`) installed.

---

## 🚦 Getting Started

### 1. Build & Generate Android Disk Images
Generate the customized ramdisk and composite GPT disk image:
```powershell
python tools/m0_build.py initrd
python tools/m0_build.py disk
```

### 2. Run via Tauri Desktop Application (Embedded Screen)
```powershell
npm install
npm run tauri dev
```
Click **"▶ Launch Emulator"** to boot the system. The screen will automatically stream and become interactive inside the window.

### 3. Run Standalone from PowerShell
```powershell
# Launch with native SDL graphical window
.\tools\launch.ps1

# Launch in headless mode for background ADB testing
.\tools\launch.ps1 -Headless
```

---

## 📱 Connecting via ADB

Once the VM is running, attach via standard Android Debug Bridge:
```powershell
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 shell
```

Verify boot completion:
```powershell
adb -s 127.0.0.1:5555 shell getprop sys.boot_completed
# Output: 1
```

---

## 📜 License
Open Source under the Apache 2.0 / MIT License.
