# QEMU 11.0.0 (aarch64-softmmu) + gfxstream/rutabaga — Build Plan

Host: Windows 11 ARM64 (Snapdragon X Elite), native CPU aarch64.
Goal: `tools\qemu-gfxstream\qemu-system-aarch64.exe` with the `virtio-gpu-rutabaga(-pci)`
device and `rutabaga` object, so the Android 16 Cuttlefish ARM64 guest can use its
"pastel"/gfxstream Vulkan HAL over virtio-gpu.

## Environment findings (verified)

### Network
- **HTTPS works only via the OpenSSL TLS backend.** Windows-schannel tools fail with
  `SEC_E_NO_CREDENTIALS (0x8009030e)`.
  - Works: `C:\msys64\clangarm64\bin\curl.exe` (OpenSSL 3.6.2),
    `git -c http.sslBackend=openssl`, `cargo` (after we bypass schannel — see below).
  - Broken: Windows `curl.exe` (schannel), `git` default (schannel), pacman (https-only mirrors + cygwin).
- Web search / modsearch is DOWN (all engines fail). Research is done from primary sources
  (git clones + read_page against github/gitlab) only.

### Shell
- `C:\msys64\usr\bin\bash.exe` and Git-for-Windows `bash.exe` **cannot run** in this sandbox:
  cygwin's `msys-2.0.dll` fails to create its signal pipe (named-pipe sandbox restriction) —
  `fatal error - couldn't create signal pipe, Win32 error 5`.
- `wsl.exe` exists but `wsl -l` → `E_ACCESSDENIED` (WSL service blocked).
- **Solution used:** `busybox64.exe` (BusyBox for Windows, frippery.org) — a native Win32
  single binary with 179 POSIX applets (`sh`, `ash`, `sed`, `awk`, `grep`, `make`, `find`,
  `xargs`, `tar`, `gzip`, `diff`, `patch`, `expr`, ...). No cygwin, no named pipes → runs here.
  Installed as applets into `tools\qemu-gfxstream\bin\`.

### Toolchain (all installed under `C:\msys64\clangarm64\`)
- clang 22.1.4 (aarch64-w64-windows-gnu), lld, llvm-ar/nm/objcopy/ranlib/dlltool/rc/windres
- meson 1.11.1, ninja 1.13.2, pkgconf/pkg-config 2.5.1, python 3.14.4
- glib2 2.88.1 (headers present), pixman 0.46.4, dtc 1.7.2, capstone 5.0.7,
  libslirp 4.9.1, zstd 1.5.7, virglrenderer 1.3.0
- Rust 1.95.0, rustup (host `aarch64-pc-windows-msvc`), cargo/rustc at `C:\Users\erict\.cargo\bin`

## QEMU 11.0.0 gfxstream integration (authoritative, from source)

- meson option: `rutabaga_gfx` (feature, default `auto`).
- meson.build (lines 1411-1416):
  ```
  rutabaga = dependency('rutabaga_gfx_ffi',
                         method: 'pkg-config',
                         required: get_option('rutabaga_gfx'))
  ```
- C source `hw/display/virtio-gpu-rutabaga.c` does:
  `#include <rutabaga_gfx/rutabaga_gfx_ffi.h>`.
- Devices gated on `CONFIG_VIRTIO_GPU` + rutabaga (hw/display/meson.build):
  - `virtio-gpu-rutabaga` (virtio-gpu-rutabaga.c)
  - `virtio-gpu-rutabaga-pci` (virtio-gpu-pci-rutabaga.c)
  - `virtio-vga-rutabaga` (virtio-vga-rutabaga.c)
- Device properties on VirtIOGPURutabaga (capset mask bits):
  `gfxstream-vulkan`, `x-gfxstream-gles`, `x-gfxstream-composer`.
  The "pastel"/gfxstream Vulkan HAL uses `gfxstream-vulkan=on`.
- **rutabaga_gfx is consumed as a plain pkg-config C library** (`rutabaga_gfx_ffi`), NOT a
  meson cargo subproject in v11.0.0 (the `-rs` cargo wraps are for QEMU's own internal Rust
  devices, independent of rutabaga). QEMU's `rust` meson option defaults to `disabled` and is
  NOT needed for rutabaga.

=> The hard part is producing `librutabaga_gfx_ffi` + `rutabaga_gfx/rutabaga_gfx_ffi.h` +
   `rutabaga_gfx_ffi.pc` from the Rust `rutabaga_gfx` crate, installed to a prefix QEMU can
   see (`PKG_CONFIG_PATH`).

## Dependency list (msys2 packages, all ALREADY CACHED/INSTALLED)
- mingw-w64-clang-aarch64-{meson, ninja, pkgconf, glib2, pixman, dtc, capstone, libslirp, zstd}
- mingw-w64-clang-aarch64-clang (22.1.4) + clang-libs, lld, llvm, binutils
- mingw-w64-clang-aarch64-python (3.14.4)
- Rust via rustup (not msys2)
- (rutabaga_gfx_ffi — to be built from source, see below)

## Source URLs + versions
- QEMU: `https://gitlab.com/qemu-project/qemu.git`, tag `v11.0.0`,
  commit `14f38a63b9adc02c0ebe3b5ada1f1208abaf21ea`. (CLONED at `qemu/`.)
- rutabaga_gfx: Rust crate (crates.io `rutabaga_gfx`, latest 0.1.85) — exact repo/commit:
  see research subagent + BUILD_LOG. Historical home: crosvm (Google) repo.

## Build steps

### 1. Environment (PATH for every build command)
```
PATH = tools\qemu-gfxstream\bin   (busybox sh/sed/awk/grep/make/...)
     ; C:\msys64\clangarm64\bin   (clang, lld, llvm-*, meson, ninja, pkg-config, python)
     ; C:\Users\erict\.cargo\bin  (cargo, rustc)
     ; %PATH%
```

### 2. Baseline (toolchain validation, no rutabaga yet)
```
cd tools\qemu-gfxstream\qemu
./configure --target-list=aarch64-softmmu \
    --disable-docs --disable-tools \
    --disable-vnc --disable-gtk --disable-sdl \
    --disable-opengl --disable-virglrenderer \
    --disable-guest-agent \
    (minimal feature set to cut compile time)
ninja  (via meson build dir; see BUILD_LOG for exact dir)
```

### 3. rutabaga_gfx_ffi
Build the Rust crate's FFI (see research subagent result for exact cargo/cbindgen commands),
producing lib + header + `.pc`, installed to `tools\qemu-gfxstream\rutabaga-prefix\`.

### 4. Final build
```
PKG_CONFIG_PATH=<rutabaga-prefix>/lib/pkgconfig \
./configure --target-list=aarch64-softmmu --enable-rutabaga-gfx ...same minimal set...
ninja
```

### 5. Validation
```
qemu-system-aarch64.exe -device help | findstr rutabaga
qemu-system-aarch64.exe -object help | findstr rutabaga
```
Expect `virtio-gpu-rutabaga-pci` (and `virtio-gpu-rutabaga`) in devices and a `rutabaga`
object.

## Known risks / blockers (to be resolved in BUILD_LOG)
1. POSIX shell — RESOLVED via busybox64.exe.
2. Whether `./configure` (a 2060-line POSIX sh script) completes correctly under busybox ash
   (ash is POSIX-but-less-than-bash; configure is written portably, should work).
3. rutabaga_gfx FFI ABI version matching QEMU 11.0.0's expectations (struct/enum definitions
   in `rutabaga_gfx_ffi.h`).
4. Whether rutabaga_gfx FFI build requires gfxstream goldfish / Vulkan SDK / gbm at BUILD
   time (vs runtime only). Cuttlefish's "pastel" backend = gfxstream, loaded at runtime.
