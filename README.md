# ARM64 Android Emulator for PC (Snapdragon X Elite)

A high-performance, open-source Android emulator designed specifically for Windows ARM64 hosts. This project leverages native hardware virtualization (WHPX) and modern GPU paravirtualization (Venus/Vulkan) to provide a near-native Android experience on Snapdragon X Elite and other ARM64 PCs.

## 🚀 Key Features

- **Native Performance:** Uses Windows Hypervisor Platform (WHPX) for ARM64-on-ARM64 virtualization (no instruction translation overhead).
- **GPU Accelerated:** Utilizes the **Venus** protocol via VirtIO-GPU for native Vulkan/OpenGL acceleration on the Adreno GPU.
- **Modern Stack:** Built with **Rust**, **Tauri v2**, and **React** for a lightweight and responsive control panel.
- **QEMU Powered:** Uses the latest QEMU 11.0.0 (Native Windows ARM64 build).

## 🛠️ Prerequisites

1.  **Windows ARM64 PC:** (e.g., Snapdragon X Elite/Plus, Surface Pro 11).
2.  **Enable Virtualization:**
    -   Ensure "Windows Hypervisor Platform" is enabled in Windows Features.
3.  **MSYS2 (CLANGARM64):**
    -   Install MSYS2 and the CLANGARM64 toolchain.
    -   The project expects QEMU at `C:\msys64\clangarm64\bin\qemu-system-aarch64.exe`.

## 📦 Environment Setup

Run the following in an MSYS2 CLANGARM64 terminal to install the necessary binaries:

```bash
pacman -S mingw-w64-clang-aarch64-qemu mingw-w64-clang-aarch64-virglrenderer
```

## 📂 Android Image Requirements

To achieve full hardware acceleration, you need an AOSP image with **VirtIO** drivers.

1.  Go to [ci.android.com](https://ci.android.com/).
2.  Search for branch `aosp-main` and target `aosp_cf_arm64_phone` (Cuttlefish).
3.  Download the `aosp_cf_arm64_phone-img-xxxxxx.zip` artifact.
4.  Extract and locate `system.img` (or use the provided `download_image.sh` script in MSYS2).

## 🖥️ Development

### Install Node dependencies
```bash
npm install
```

### Run the Control Panel
```bash
npm run tauri dev
```

## 🏗️ Architecture

- **Frontend:** React + TypeScript (Vite)
- **Backend:** Rust (Tauri v2)
- **Virtualization:** QEMU 11.0.0 + WHPX
- **Graphics:** VirtIO-GPU-GL-PCI (Venus/Vulkan)

## 📜 License
Open Source - See LICENSE for details.
