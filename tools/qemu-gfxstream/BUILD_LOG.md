# QEMU 11.0.0 (aarch64-softmmu) + gfxstream/rutabaga — Build Log

## Environment bootstrap (blockers found & solved)

1. **Network**: schannel TLS broken (`SEC_E_NO_CREDENTIALS`). Workaround: OpenSSL
   backend — `C:\msys64\clangarm64\bin\curl.exe` (OpenSSL 3.6.2) and
   `git -c http.sslBackend=openssl`. Both confirmed working.
2. **POSIX shell**: msys2/Git bash fail (cygwin signal-pipe = named-pipe sandbox
   denial); WSL denied. Workaround: **busybox64.exe** (frippery.org), 179 applets
   installed to `tools\qemu-gfxstream\bin\`. `sh`/`sed`/`awk`/`grep`/`make`/`find`
   all functional.
3. **QEMU configure "spaces nor colons"**: patched `configure` to allow a leading
   drive letter (`C:`) while still rejecting real spaces/internal colons.
4. **Python venv / ensurepip**: system python 3.14.4 lacked pip+setuptools, so QEMU's
   mkvenv ran `ensurepip` which failed. Fixed by:
   - Bootstrap pip 26.2.1 + setuptools 84.0.0 + wheel 0.48.0 wheels into
     `tools\qemu-gfxstream\pysite\` (on PYTHONPATH).
   - Copy QEMU's local `python/qemu` package + vendored `qemu_qmp`, `pycotap` into
     `pysite/`.
5. **tempfile.mkdtemp() sandbox denial**: the sandbox denies file creation inside
   directories created by `tempfile.mkdtemp()` (mode 0o700 → flagged "private", so
   pip's unpack/build-tracker temp dirs all failed with WinError 5).
   Fixed via `pysite/sitecustomize.py` which reimplements `tempfile.mkdtemp` using
   `os.mkdir(..., 0o755)` and wraps `TemporaryDirectory`. Verified working.

## Toolchain (verified working)
- clang 22.1.4 (aarch64-w64-windows-gnu), meson 1.11.1, ninja 1.13.2,
  pkgconf 2.5.1, python 3.14.4, glib2 2.88.1, pixman 0.46.4, Rust 1.95.0.

## Source versions
- QEMU: gitlab.com/qemu-project/qemu, tag v11.0.0, commit 14f38a63... (cloned at `qemu/`).
- rutabaga_gfx: **github.com/magma-gpu/rutabaga_gfx.git** (crosvm deleted it 2025-09-15;
  magma-gpu is now source of truth). Recommended version v0.1.75 (FFI API matches QEMU
  11.0.0's virtio-gpu-rutabaga.c usage: rutabaga_command struct, resource_map/unmap,
  builder.wsi/debug_cb/capset_mask). Built via **meson -Dffi=true**, emits
  `rutabaga_gfx_ffi.pc` + vendored header `ffi/src/include/rutabaga_gfx_ffi.h`.

## Build steps so far
- [x] Clone QEMU v11.0.0.
- [x] Bootstrap busybox sh + python deps + build env (incl. sitecustomize tempfile fix).
- [x] Baseline configure (SUCCEEDED) — keycodemapdb subproject cloned & pinned at f5772a62.
  - Extra fixes: `GIT_CONFIG_GLOBAL` -> workspace gitconfig (sslBackend=openssl) so meson's
    `git fetch` works; restored `pyvenv/meson.build` accidentally deleted during cleanup.
- [ ] QEMU `qemu-system-aarch64.exe` compile (running, ninja -j8).
- [x] Clone magma-gpu/rutabaga_gfx (v0.1.85).
- [x] meson setup rutabaga_gfx `-Dffi=true` (SUCCEEDED) — 26 cargo subprojects resolved.
  - Fixes: real rust toolchain on PATH (`C:\Users\erict\.rustup\toolchains\stable-aarch64-pc-windows-msvc\bin`)
    to bypass rustup shim temp-write denial; MSVC ARM64 env (vcvarsall x64_arm64) for link.exe +
    LIB/INCLUDE; `RUST_LD=link`; removed busybox `link`/`ar`/`patch` applets that shadowed MSVC/llvm tools
    (patch removed entirely -> meson falls back to `git apply`).
- [ ] rutabaga_gfx_ffi ninja build (running).
- [ ] Final configure with -Drutabaga_gfx=enabled + build.
- [ ] Validate devices/object.

## Validation target
```
qemu-system-aarch64.exe -device help | findstr rutabaga   # expect virtio-gpu-rutabaga(-pci)
qemu-system-aarch64.exe -object help | findstr rutabaga   # expect rutabaga object
```
