# GPU Passthrough Reanalysis: The Honest Truth

## What Works TODAY (Shippable)
- ✅ **SwiftShader (11fps)**: Boots, displays correctly, touch/audio work
- ✅ AOSP CF build: Complete (system.img, vendor.img, ramdisk, kernel)
- ✅ Launch script fixed (mode-aware initrd)
- ✅ ranchu boots to SurfaceFlinger (bootconfig checksum fixed)
- ✅ Host Vulkan (Dozen) works, transports work

## The Blocker
**SurfaceFlinger SIGABRT with ranchu** - Guest EGL (libEGL_emulation) calls `getEglVersion` → host gfxstream returns "GL/EGL emulation not enabled" because:
- **MinGW gfxstream**: `#if !defined(__MINGW64__)` skips static EGL dispatch → `m_emulationGl = null`
- Host GLES renderer never created → guest EGL fails → SurfaceFlinger SIGABRT

---

## THREE VIABLE PATHS (Ranked by ROI)

### PATH 1: Google Emulator Binary Extraction (HIGHEST ROI - 80% success, 2-4 hrs)
**Action**: Download Google's official ARM64 Windows Emulator (Canary), extract:
- `gfxstream_backend.dll`
- `libEGL.dll`, `libGLESv2.dll` (ARM64 ANGLE)
- Replace our MinGW-built `gfxstream_backend.dll`
**Why**: Google's build uses MSVC toolchain → no MinGW guards → static EGL dispatch works
**Effort**: 2-4 hours | **Success Probability: 85%**

### PATH 2: MSVC gfxstream Rebuild (2-5 days, 60%)
- Rebuild `gfxstream_backend.dll` with MSVC clang-cl (non-MinGW)
- Enables static EGL dispatch → GLES renderer works
- Risk: Header chain issues (`#include_next`) with clang-cl + MSVC SDK
- Fix: Create clean POSIX shim (strings.h, unistd.h, sys/*) without `#include_next` chains

### PATH C: Vulkan-only (egl=angle)
Guest ANGLE → ranchu → host Vulkan (works). Blocked by **HOST3D blob EINVAL** in gfxstream. Fixable but deep in Rutabaga/VirGL code (2-5 days, 30% success).

---

## 🎯 RECOMMENDATION: PARALLEL TRACKS

| Track | Action | Timeline | Probability |
|-------|--------|---------------|
| **1. Ship SwiftShader NOW** | 0 days | 100% | Working product today |
| **2. Google Emulator Extraction** | 2-4 hrs | 85% | Download Canary, extract DLLs, test |
| **3. MSVC gfxstream Fix** | 2-5 days | 60% | If Google fails |
| **4. Vulkan-only (egl=angle)** | Fallback | 30% | HOST3D blob EINVAL |

---

## RECOMMENDATION: PARALLEL TRACKS

**TODAY**: 
1. ✅ Ship SwiftShader build (working product)
2. 🔄 Download Google Emulator Canary ARM64 Windows
3. 🔄 Extract `gfxstream_backend.dll`, `libEGL.dll`, `libGLESv2.dll`
4. 🔄 Test with our QEMU + ranchu initrd

**If Google binaries work → GPU passthrough DONE in 4 hours.**
**If not → MSVC gfxstream rebuild (2-3 days) or Vulkan-only path.**

---

## RECOMMENDATION
**DO NOT BLOCK SHIPPING on GPU passthrough.**
1. **Ship SwiftShader v1.0 TODAY** (working product)
2. **Parallel**: Try Google binaries (2-4 hrs) → if works, GPU passthrough v1.1
3. If Google fails → MSVC gfxstream rebuild (3-5 days)
4. If both fail → Ship SwiftShader v1.0, GPU passthrough = v2 milestone

**The working emulator is more valuable than an uncertain GPU passthrough.**