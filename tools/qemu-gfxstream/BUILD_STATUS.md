
# Build Status Update (2026-08-22 14:24)

## ACHIEVED
- rutabaga_gfx_ffi.dll built successfully (Rust cdylib, 1.5 MB) 
- Installed to rutabaga-prefix/ (bin/, lib/, include/, lib/pkgconfig/)
- QEMU reconfigured with -Drutabaga_gfx=enabled
- Full ninja build completed [2398/2398] -> qemu-system-aarch64.exe (107 MB)
- VALIDATED: virtio-gpu-rutabaga-pci + virtio-gpu-rutabaga devices present
- VALIDATED: gfxstream-vulkan=<bool> property exists on the device
- Self-contained runtime (7 msys2 DLLs copied beside exe)

## BLOCKER
- gfxstream-vulkan=on requires the 'gfxstream' feature in rutabaga_gfx
- Enabling it requires pkg-config dependency 'gfxstream_backend'
- gfxstream_backend is part of google/gfxstream project
- Cloned to gfxstream/ — meson build system exists but requires:
  - Multiple third-party deps (aemu, abseil-like base, etc.)
  - Windows ARM64 support is experimental at best
  - Build complexity comparable to Mesa itself

## OPTIONS TO UNBLOCK
1. Build gfxstream from source (multi-hour, complex cross-deps)
2. Use Android SDK emulator binary (has prebuilt gfxstream, not installed)
3. Use virglrenderer instead (installed! but guest needs virgl GL driver, not present in Cuttlefish image)

## CURRENT WORKING STATE (without gfxstream)
- QEMU boots Android 16 ARM64 with WHPX
- USB keyboard + mouse input verified working from GTK window
- Resolution forced to 1280x800 via wm size override
- adb over TCP works (adb connect 127.0.0.1:5555)
- Guest UI renders via SwiftShader (CPU software rendering, ~11 fps stream)

## Round 1 Progress (2026-08-22 16:48)

### Completed
- Built QEMU 11 from source: WHPX + rutabaga_gfx=enabled + slirp=enabled
- Built rutabaga_gfx_ffi Rust cdylib (28/28 targets)  
- Built gfxstream_backend C++ library (218/218 targets)
- Installed all components to msys64 prefix
- VM boots successfully with custom QEMU + virtio-gpu-rutabaga-pci,gfxstream-vulkan=on,blob=on
- Gfxstream renderer initializes: "Selecting Vulkan device: Qualcomm Adreno X1-85 GPU"
- USB keyboard/mouse verified working in GTK window
- Resolution enforced at 1280x800 via wm size override
- adb connectivity verified

### Remaining Blocker
Guest pastel Vulkan HAL cannot establish gfxstream transport because:
- VIRTIO_GPU_F_CONTEXT_INIT feature not properly negotiated between
  guest kernel (6.12.38-android16) and QEMU rutabaga device
- Blob resource allocation not completing
- Pastel HAL silently falls back, ANGLE uses bundled SwiftShader

### Next Steps Required
1. Add debug logging to QEMU virtio-gpu-rutabaga.c to trace feature negotiation
2. Verify guest kernel sees CONTEXT_INIT and BLOB features
3. Check if pastel HAL uses correct capset ID for gfxstream transport
4. May need to modify guest kernel config or apply Cuttlefish-specific patches

## FINAL STATUS (2026-08-22 17:16)

### What was BUILT from source (all working)
- QEMU 11.0.0 (aarch64-softmmu) with WHPX + rutabaga + slirp + USB + GTK-capable
- rutabaga_gfx_ffi.dll v0.1.85 (Rust cdylib with gfxstream feature)
- gfxstream_backend library (218 targets, full build)
- All installed and linked: virtio-gpu-rutabaga-pci device present

### How far gfxstream gets before failing
1. ✅ Loads vulkan-1.dll (host Vulkan loader)
2. ✅ Finds Adreno X1-85 GPU via dzn mapping layer  
3. ✅ Creates VkInstance and VkDevice
4. ✅ Initializes VkEmulation with all features
5. ❌ FAILS: "Vulkan driver doesn't support any external memory modes!"
   → dzn (D3D12 mapping layer) lacks VK_KHR_external_memory_fd
   → gfxstream REQUIRES external memory for host-guest GPU sharing
   → Without it, zero-copy GPU rendering is impossible

### WHY THIS IS A PLATFORM LIMITATION
- Qualcomm Adreno X1-85 on Windows uses D3D12 natively
- Vulkan access goes through dzn (Microsoft's D3D12-to-Vulkan layer)  
- dzn does NOT implement VK_KHR_external_memory_fd/fence_fd
- These extensions require native Vulkan driver support (not mapping layers)
- No native Vulkan driver exists yet for Adreno X1 on Windows

### WHAT WOULD FIX THIS
1. Qualcomm releases a native Vulkan ICD for Adreno X1 on Windows
2. Microsoft adds external memory support to dzn
3. Google ships Android Emulator for Windows ARM64 with their own solution
4. Build gfxstream on Linux ARM64 and use remote rendering protocol

### CURRENT BEST CONFIGURATION
- launch.ps1 -DisplayMode gtk (or scrcpy for touch)
- USB keyboard/mouse input working
- 1280x800 resolution enforced
- adb connectivity for development
- SwiftShader CPU rendering at ~10 fps (acceptable for basic use)
