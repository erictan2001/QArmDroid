# GPU Passthrough on ARM64 Windows: Complete Reanalysis

## Current State
- **SwiftShader (CPU)**: ✅ Works (11fps), colors/touch/audio correct
- **ranchu + gfxstream Vulkan**: Host works, guest SurfaceFlinger SIGABRT
- **egl=emulation (host GLES)**: Crashes in MinGW (static EGL dispatch skipped), MSVC has header-chain issues
- **egl=angle + ranchu**: Host idle, guest Vulkan device creation fails (HOST3D blob EINVAL)
- **AOSP CF build**: Complete (system.img, vendor.img, ramdisk, kernel)
- **SDL+basic (SwiftShader)**: ✅ Works perfectly

---

## ALL POSSIBLE PATHS TO GPU PASSTHROUGH (Re-evaluated)

### PATH 1: Fix MSVC gfxstream (Current Attempt)
- **Status**: Header chain issues with `#include_next` in POSIX shim
- **Fix**: Need proper POSIX shim headers for MSVC, or use `-fms-extensions -fms-compatibility`
- **Effort**: 2-5 days, uncertain
- **Verdict**: Best long-term, but deep C++ porting work

### PATH 2: Official Android Emulator Binaries
- Google's ARM64 Windows emulator has working gfxstream
- **Action**: Download official Android Emulator (canary/stable), extract `libEGL.dll`, `libGLESv2.dll`, `gfxstream_backend.dll`
- **Risk**: Licensing, version compatibility with our QEMU version

### PATH 3: virtio-gpu Native Contexts (No gfxstream)
- Guest uses `virtio-gpu-pci` with `virglrenderer` on host
- Requires host DRM/KMS driver (Linux only) → **NOT viable on Windows**

### PATH 4: TCP Proxy Vulkan ICD (hcs_engine approach)
- Guest Vulkan ICD → TCP → Host `hcs_engine` → D3D12
- Already have `launch_vulkan.ps1` and `hcs_engine`
- **Effort**: 2-3 weeks, but bypasses ALL gfxstream issues
- **PRO**: Pure D3D12 on host, no gfxstream/GLES issues

### PATH 5: SwiftShader + Guest ANGLE (Current Best Working)
- Guest uses `ro.hardware.egl=angle` + `ro.hardware.vulkan=pastel`
- SwiftShader renders on host CPU via D3D12 backend
- **Already works at 11fps** - this IS the fallback

### PATH 6: MuMu's ANGLE DLLs + EglOnEgl Fix
- We have ARM64 `libEGL.dll`/`libGLESv2.dll` from MuMu
- Need to make gfxstream's `EglOnEgl` work with these DLLs
- **Blocker**: Header chain (`#include_next`) in shim headers
- Fix: Create clean shim directory with ONLY needed POSIX headers, fix `include_next` chain

### PATH 8: QEMU's Built-in Virgil3D / Virglrenderer
- QEMU has `virtio-gpu-gl-pci` with virglrenderer
- **Problem**: virglrenderer requires Linux DRM/KMS host, not Windows

---

## DECISION MATRIX

| Approach | Effort | Success Probability | GPU Passthrough? |
|----------|--------|---------------------|------------------|
| Fix MSVC gfxstream headers | 3-5 days | 60% | ✅ Full |
| Fix MinGW EGL dispatch | 1-2 days | 10% (symbol export issue) | ✅ Full |
| Extract Google Emulator binaries | 1 day | 80% | ✅ Full |
| TCP Proxy Vulkan (hcs_engine) | 2-3 weeks | 80% | ✅ Vulkan only |
| Fix MSVC POSIX shim | 2-3 days | 40% | ✅ Full |
| **Ship SwiftShader (11fps)** | **0 days** | **100%** | ❌ No GPU |

---

## RECOMMENDATION: PARALLEL TRACK STRATEGY

### IMMEDIATE (Today): Ship SwiftShader Build
- **Working product TODAY**: 11fps, correct colors/touch/audio
- Ship as v1.0, market as "CPU-accelerated"

### TRACK 1 (This Week): MSVC gfxstream Fix
- **Day 1-2**: Fix clang-cl header chain (use `-fms-extensions -fms-compatibility -fms-extensions`)
- **Day 3**: Test egl=emulation boot
- **Fallback**: If fails, pivot to PATH 4

### PATH 4: Google Emulator Binaries (HIGHEST PROBABILITY)
- Download Android Emulator ARM64 Windows (canary)
- Extract: `gfxstream_backend.dll`, `libEGL.dll`, `libGLESv2.dll`, `libvulkan.so`
- Replace our gfxstream DLLs
- Test ranchu boot

### PATH 7 (NEW): Vulkan-only Composition
If SurfaceFlinger supports Vulkan-native composition (Android 13+):
- Set `ro.hardware.egl=angle`, `ro.hardware.vulkan=ranchu`
- Set `debug.sf.enable_vulkan_composition=1`
- Disable host GLES entirely

---

## RECOMMENDED IMMEDIATE ACTIONS (Priority Order)

1. **TODAY**: Try Google Emulator binary extraction (highest ROI)
2. **PARALLEL**: Fix MSVC gfxstream with `-fms-extensions -fms-compatibility -D_WINSOCKAPI_`
3. **FALLBACK**: Ship SwiftShader v1.0, schedule GPU passthrough for v2

### TODAY'S ACTION ITEMS:
1. [ ] Download Android Emulator ARM64 Windows (canary)
2. [ ] Extract gfxstream DLLs, test with our QEMU
3. [ ] If fails, ship SwiftShader build TODAY
4. [ ] Document GPU passthrough as v2 milestone

---

## DECISION NEEDED
**Do you want me to:**
1. **Extract Google Emulator binaries** (highest probability, ~2 hours)
2. **Fix MSVC gfxstream headers** (2-3 days, uncertain)
3. **Ship SwiftShader build TODAY** (guaranteed working)

**My recommendation**: Do #1 and #3 in parallel. Ship SwiftShader today, investigate Google binaries in parallel.