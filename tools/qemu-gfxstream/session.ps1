# session.ps1 â€” full build environment for the gfxstream QEMU build.
# Source this at the start of every build step (buildenv + MSVC + rust).
$bk = "C:\Users\erict\OneDrive\Desktop\Arm64AndroidEmulator\tools\qemu-gfxstream"

# 1) Tool PATH: busybox applets (POSIX tools), clangarm64 (compiler/meson/ninja),
#    DIRECT rust toolchain binaries FIRST (before .cargo\bin shims) so rustc
#    never goes through the rustup shim (which tried to download the crates'
#    pinned 1.88 toolchain and failed on the restricted network).
$env:PATH = "$bk\bin;C:\msys64\clangarm64\bin;" +
            "C:\Users\erict\.rustup\toolchains\stable-aarch64-pc-windows-msvc\bin;" +
            "C:\Users\erict\.cargo\bin;" +
            "C:\Windows\System32;C:\Windows;$env:PATH"

# 2) MSVC ARM64 env (LIB / INCLUDE / link.exe) â€” required by rustc -C linker=link
#    and by native linking.
& "$bk\msvcenv.ps1" | Out-Null

# 3) Rust/Cargo settings carried over from the research phase.
#    RUSTUP_TOOLCHAIN overrides the crates' rust-toolchain.toml pin (1.88.0)
#    and stops rustup from attempting a network install; RUSTUP_AUTO_INSTALL=0
#    is belt-and-braces so a bad pin fails fast instead of hanging.
$env:RUSTUP_TOOLCHAIN = "stable-aarch64-pc-windows-msvc"
$env:RUSTUP_AUTO_INSTALL = "0"
$env:RUST_LD = "link"
$env:CARGO_NET_GIT_FETCH_WITH_CLI = "true"
$env:GIT_CONFIG_GLOBAL = "$bk\gitconfig"
$env:MSYSTEM = "CLANGARM64"
$env:PKG_CONFIG = "C:\msys64\clangarm64\bin\pkg-config.exe"

# 4) rutabaga prefix for the pkg-config install (QEMU consumes this)
$env:RUTABAGA_PREFIX = "$bk\rutabaga-prefix"
$env:PKG_CONFIG_PATH = "$bk\rutabaga-prefix\lib\pkgconfig"

Write-Output "session ready:"
Write-Output "  rustc  = $(& rustc --print host 2>&1)"
Write-Output "  clang  = $(& clang --version 2>&1 | Select-Object -First 1)"
Write-Output "  TGT    = $env:VSCMD_ARG_TGT_ARCH / LIB set: $([bool]$env:LIB)"
# 5) Add msys64 lib to LIB so link.exe finds gfxstream_backend.lib
$env:LIB = "$env:LIB;C:\msys64\clangarm64\lib"
