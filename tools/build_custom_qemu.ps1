<#
.SYNOPSIS
    Build the custom-patched QEMU ARM64 binary with rutabaga, touchscreen HID,
    SDL letterbox, and VNC websocket support.

.DESCRIPTION
    Builds tools/qemu-gfxstream/qemu/build/qemu-system-aarch64.exe from the
    nested submodule source tree after applying our custom patches.
    Produces the exact custom binary expected by QArmDroid.
#>
[CmdletBinding()]
param(
    [switch]$ForceRebuild
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$GfxDir   = Join-Path $RepoRoot "tools\qemu-gfxstream"
$QemuDir  = Join-Path $GfxDir "qemu"
$BuildDir = Join-Path $QemuDir "build"
$RutabagaDir = Join-Path $GfxDir "rutabaga_gfx"
$Prefix   = Join-Path $GfxDir "rutabaga-prefix"

$targetExe = Join-Path $BuildDir "qemu-system-aarch64.exe"
if (-not $ForceRebuild -and (Test-Path $targetExe) -and ((Get-Item $targetExe).Length -gt 10000000)) {
    Write-Host "Custom QEMU is already built: $targetExe ($([math]::Round((Get-Item $targetExe).Length / 1MB, 1)) MB)" -ForegroundColor Green
    return
}

Write-Host "== [1/5] ensuring submodules & applying patches ==" -ForegroundColor Cyan
git config --global core.protectNTFS false
git -C $RepoRoot submodule update --init --depth 1 tools/qemu-gfxstream/qemu tools/qemu-gfxstream/rutabaga_gfx tools/qemu-gfxstream/gfxstream
& (Join-Path $RepoRoot "tools\apply_patches.ps1")

Write-Host "== [2/5] configuring build environment ==" -ForegroundColor Cyan
$msysCands = @($env:MSYS2_ROOT, "C:\msys64", "$env:SystemDrive\msys64")
$msysRoot = ($msysCands | Where-Object { $_ -and (Test-Path (Join-Path $_ "clangarm64\bin")) } | Select-Object -First 1)
$clangBin = if ($msysRoot) { Join-Path $msysRoot "clangarm64\bin" } else { "C:\msys64\clangarm64\bin" }
$msysLib = if ($msysRoot) { Join-Path $msysRoot "clangarm64\lib" } else { "C:\msys64\clangarm64\lib" }

$rustToolchain = Join-Path $env:USERPROFILE ".rustup\toolchains\stable-aarch64-pc-windows-msvc\bin"
$cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"

$env:PATH = "$GfxDir\bin;$clangBin;$rustToolchain;$cargoBin;C:\Windows\System32;C:\Windows;$env:PATH"
$env:MSYSTEM = "CLANGARM64"
$env:PKG_CONFIG = Join-Path $clangBin "pkg-config.exe"
$env:RUTABAGA_PREFIX = $Prefix
$env:PKG_CONFIG_PATH = Join-Path $Prefix "lib\pkgconfig"

# MSVC ARM64 environment if available
$msvcScript = Join-Path $GfxDir "msvcenv.ps1"
if (Test-Path $msvcScript) {
    & $msvcScript | Out-Null
}

Write-Host "== [3/5] building rutabaga_gfx_ffi ==" -ForegroundColor Cyan
$pcFile = Join-Path $Prefix "lib\pkgconfig\rutabaga_gfx_ffi.pc"
if ($ForceRebuild -or -not (Test-Path $pcFile)) {
    Push-Location $RutabagaDir
    try {
        $ffiBuildDir = Join-Path $RutabagaDir "build-ffi"
        if (-not (Test-Path $ffiBuildDir)) {
            & meson setup build-ffi -Dffi=true --prefix="$Prefix"
        }
        & ninja -C build-ffi install
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  rutabaga_gfx_ffi already installed at $Prefix" -ForegroundColor DarkGray
}

Write-Host "== [4/5] configuring QEMU ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$buildNinja = Join-Path $BuildDir "build.ninja"
if ($ForceRebuild -or -not (Test-Path $buildNinja)) {
    Push-Location $QemuDir
    try {
        # Configure QEMU with all required features: WHPX, TCG, SDL, Pixman, Slirp, Rutabaga, VNC
        $mesonArgs = @(
            "setup", "build",
            "--target-list=aarch64-softmmu",
            "-Dauto_features=disabled",
            "-Dwhpx=enabled",
            "-Dtcg=enabled",
            "-Dsdl=enabled",
            "-Dpixman=enabled",
            "-Dslirp=enabled",
            "-Drutabaga_gfx=enabled",
            "-Dvnc=enabled"
        )
        if (Test-Path (Join-Path $BuildDir "meson-info")) {
            $mesonArgs = @("setup", "build", "--reconfigure", "-Dvnc=enabled", "-Dpixman=enabled", "-Drutabaga_gfx=enabled")
        }
        & meson @mesonArgs
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  QEMU already configured in $BuildDir" -ForegroundColor DarkGray
}

Write-Host "== [5/5] building qemu-system-aarch64.exe ==" -ForegroundColor Cyan
Push-Location $QemuDir
try {
    & ninja -C build qemu-system-aarch64.exe
} finally {
    Pop-Location
}

# Copy rutabaga_gfx_ffi.dll and rutabaga libs into build dir if needed
$rutabagaDll = Join-Path $Prefix "bin\rutabaga_gfx_ffi.dll"
if (Test-Path $rutabagaDll) {
    Copy-Item $rutabagaDll $BuildDir -Force
}

$exe = Join-Path $BuildDir "qemu-system-aarch64.exe"
if (Test-Path $exe) {
    Write-Host "Custom QEMU build successful: $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Error "Custom QEMU build failed! Executable not found at $exe"
    exit 1
}
