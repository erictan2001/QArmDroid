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
$msysCands = [System.Collections.Generic.List[string]]::new()
if ($env:MSYS2_ROOT) { $msysCands.Add($env:MSYS2_ROOT) }
if ($env:MSYS2_USR_BIN) { $msysCands.Add((Split-Path $env:MSYS2_USR_BIN -Parent)) }
if ($env:CLANGARM64_BIN) { $msysCands.Add((Split-Path $env:CLANGARM64_BIN -Parent)) }
if ($env:RUNNER_TEMP) { $msysCands.Add((Join-Path $env:RUNNER_TEMP "msys64")) }
if ($env:TEMP) { $msysCands.Add((Join-Path $env:TEMP "msys64")) }
$msysCands.Add("C:\msys64")
$msysCands.Add("D:\msys64")
$msysCands.Add("$env:SystemDrive\msys64")

$msysRoot = ($msysCands | Where-Object { $_ -and (Test-Path (Join-Path $_ "clangarm64\bin")) } | Select-Object -First 1)
$clangBin = "C:\msys64\clangarm64\bin"
$msysLib  = "C:\msys64\clangarm64\lib"
$usrBin   = "C:\msys64\usr\bin"
if ($msysRoot) {
    $clangBin = Join-Path $msysRoot "clangarm64\bin"
    $msysLib  = Join-Path $msysRoot "clangarm64\lib"
    $usrBin   = Join-Path $msysRoot "usr\bin"
}

$rustToolchain = Join-Path $env:USERPROFILE ".rustup\toolchains\stable-aarch64-pc-windows-msvc\bin"
$cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"

# If meson or ninja are not on PATH, attempt install via pip
if (-not (Get-Command meson -ErrorAction SilentlyContinue) -or -not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    if (Get-Command python -ErrorAction SilentlyContinue) {
        Write-Host "  Installing meson and ninja via pip..." -ForegroundColor Yellow
        & python -m pip install --upgrade pip meson ninja
    }
}

# Ensure diff program is present (required by QEMU tests/qapi-schema/meson.build)
if (-not (Get-Command diff.exe -ErrorAction SilentlyContinue) -and -not (Get-Command diff -ErrorAction SilentlyContinue)) {
    $pacmanExe = Join-Path $usrBin "pacman.exe"
    if (Test-Path $pacmanExe) {
        Write-Host "  Installing diffutils via pacman..." -ForegroundColor Yellow
        & $pacmanExe -S --noconfirm --needed diffutils mingw-w64-clang-aarch64-diffutils
    }
}

# Clean any broken/shadowing sh.exe or link.exe in GfxDir\bin
$binDir = Join-Path $GfxDir "bin"
if (Test-Path $binDir) {
    Remove-Item -Force (Join-Path $binDir "link.exe") -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $binDir "sh.exe") -ErrorAction SilentlyContinue
}

# MSVC ARM64 environment if available
$msvcScript = Join-Path $GfxDir "msvcenv.ps1"
if (Test-Path $msvcScript) {
    try {
        & $msvcScript
    } catch {
        Write-Warning "msvcenv.ps1 execution failed: $_"
    }
}

# Configure Rust and Cargo settings for MSVC ARM64 target
$env:RUSTUP_TOOLCHAIN = "stable-aarch64-pc-windows-msvc"
$env:RUSTUP_AUTO_INSTALL = "0"
$env:RUST_LD = "link"
$env:RUSTC_LD = "link"
$env:CARGO_NET_GIT_FETCH_WITH_CLI = "true"

# Ensure msysLib is added to LIB so link.exe can resolve gfxstream_backend.lib and mingw libraries
if ($env:LIB) {
    $env:LIB = "$env:LIB;$msysLib"
} else {
    $env:LIB = "$msysLib"
}

# Resolve and verify an MSVC-compatible linker (link.exe or lld-link.exe, never GNU coreutils link)
$realLinkExe = $null
$allLinks = @(Get-Command link.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
foreach ($cand in $allLinks) {
    try {
        $help = & $cand /? 2>&1
        if ($help -like "*Microsoft*" -or $help -like "*LLD*" -or $help -like "*USAGE*") {
            $realLinkExe = $cand
            break
        }
    } catch {}
}

if (-not $realLinkExe) {
    $lldLink = Join-Path $clangBin "lld-link.exe"
    if (Test-Path $lldLink) {
        $realLinkExe = $lldLink
    }
}

$binLink = Join-Path $binDir "link.exe"
if (Test-Path $binLink) {
    Remove-Item -Force $binLink -ErrorAction SilentlyContinue
}

$realLinkDir = $null
if ($realLinkExe) {
    Write-Host "  Using MSVC-compatible linker: $realLinkExe" -ForegroundColor Green
    $realLinkDir = Split-Path $realLinkExe -Parent
} else {
    Write-Warning "  Warning: No MSVC link.exe or lld-link.exe detected!"
}

# Put $realLinkDir first on PATH so genuine MSVC link.exe (with sibling DLLs like mspdbcore.dll) takes precedence over MSYS link.exe.
# Follow with $clangBin (clang, meson, ninja, pkg-config) and $usrBin (sh, bash, POSIX utilities).
if ($realLinkDir) {
    $env:PATH = "$realLinkDir;$clangBin;$usrBin;$rustToolchain;$cargoBin;C:\Windows\System32;C:\Windows;$env:PATH"
} else {
    $env:PATH = "$clangBin;$usrBin;$rustToolchain;$cargoBin;C:\Windows\System32;C:\Windows;$env:PATH"
}
$env:MSYSTEM = "CLANGARM64"
$env:PKG_CONFIG = Join-Path $clangBin "pkg-config.exe"
$env:RUTABAGA_PREFIX = $Prefix
$env:PKG_CONFIG_PATH = Join-Path $Prefix "lib\pkgconfig"
$env:PYTHONPATH = Join-Path $GfxDir "pysite"

# Resolve Meson & Ninja executable helpers
$mObj = Get-Command meson.exe -ErrorAction SilentlyContinue
if (-not $mObj) { $mObj = Get-Command meson -ErrorAction SilentlyContinue }
$mesonCmd = $null
if ($mObj) { $mesonCmd = $mObj.Source }
if (-not $mesonCmd) {
    $cands = @(
        (Join-Path $clangBin "meson.exe"),
        (Join-Path $clangBin "meson"),
        "C:\msys64\clangarm64\bin\meson.exe"
    )
    $mesonCmd = ($cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Invoke-Meson {
    param([Parameter(ValueFromRemainingArguments = $true)]$ArgsList)
    if ($mesonCmd) {
        & $mesonCmd @ArgsList
    } else {
        & python -m mesonbuild.mesonmain @ArgsList
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Meson failed with exit code $LASTEXITCODE"
    }
}

$nObj = Get-Command ninja.exe -ErrorAction SilentlyContinue
if (-not $nObj) { $nObj = Get-Command ninja -ErrorAction SilentlyContinue }
$ninjaCmd = $null
if ($nObj) { $ninjaCmd = $nObj.Source }
if (-not $ninjaCmd) {
    $cands = @(
        (Join-Path $clangBin "ninja.exe"),
        "C:\msys64\clangarm64\bin\ninja.exe"
    )
    $ninjaCmd = ($cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Invoke-Ninja {
    param([Parameter(ValueFromRemainingArguments = $true)]$ArgsList)
    if ($ninjaCmd) {
        & $ninjaCmd @ArgsList
    } else {
        & ninja @ArgsList
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Ninja failed with exit code $LASTEXITCODE"
    }
}

Write-Host "== [3/5] building rutabaga_gfx_ffi ==" -ForegroundColor Cyan
$pcFile = Join-Path $Prefix "lib\pkgconfig\rutabaga_gfx_ffi.pc"
if ($ForceRebuild -or -not (Test-Path $pcFile)) {
    Push-Location $RutabagaDir
    try {
        $ffiBuildDir = Join-Path $RutabagaDir "build-ffi"
        if (Test-Path $ffiBuildDir) {
            Write-Host "  Removing existing $ffiBuildDir for clean configuration..." -ForegroundColor DarkGray
            Remove-Item -Recurse -Force $ffiBuildDir -ErrorAction SilentlyContinue
        }

        # Write rust_native.ini instructing Meson to use MSVC linker for rustc (ASCII / no BOM)
        $rustIni = Join-Path $RutabagaDir "rust_native.ini"
        $iniLink = if ($realLinkExe) { $realLinkExe.Replace('\', '/') } else { 'link' }
        $iniContent = "[binaries]`nrust_ld = '$iniLink'`n"
        [System.IO.File]::WriteAllText($rustIni, $iniContent, [System.Text.Encoding]::ASCII)

        Write-Host "  Configuring rutabaga_gfx_ffi with Meson..." -ForegroundColor Cyan
        Invoke-Meson setup build-ffi -Dffi=true --prefix="$Prefix" --native-file="$rustIni"
        Write-Host "  Installing rutabaga_gfx_ffi with Ninja..." -ForegroundColor Cyan
        Invoke-Ninja -C build-ffi install
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  rutabaga_gfx_ffi already installed at $Prefix" -ForegroundColor DarkGray
}

# Ensure MinGW/LLD compatible import library aliases exist in rutabaga-prefix\lib
$libDir = Join-Path $Prefix "lib"
$binDll = Join-Path $Prefix "bin\rutabaga_gfx_ffi.dll"
if ((Test-Path $binDll) -and -not (Test-Path (Join-Path $libDir "rutabaga_gfx_ffi.dll"))) {
    Copy-Item $binDll (Join-Path $libDir "rutabaga_gfx_ffi.dll") -Force
}

$libCandidates = @(
    (Join-Path $libDir "rutabaga_gfx_ffi.dll.lib"),
    (Join-Path $libDir "rutabaga_gfx_ffi.lib"),
    (Join-Path $RutabagaDir "build-ffi\ffi\rutabaga_gfx_ffi.dll.lib")
)
$sourceLib = ($libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)

if ($sourceLib) {
    Write-Host "  Ensuring MinGW/LLD rutabaga import library aliases from: $sourceLib" -ForegroundColor Green
    foreach ($alias in @("librutabaga_gfx_ffi.dll.a", "rutabaga_gfx_ffi.lib", "librutabaga_gfx_ffi.lib", "librutabaga_gfx_ffi.a")) {
        Copy-Item $sourceLib (Join-Path $libDir $alias) -Force
    }
} else {
    Write-Warning "  rutabaga import library not found in $libDir!"
}

Write-Host "== [4/5] configuring QEMU ==" -ForegroundColor Cyan
$buildNinja = Join-Path $BuildDir "build.ninja"
if ($ForceRebuild -or -not (Test-Path $buildNinja)) {
    Push-Location $QemuDir
    try {
        # Remove existing build directory if force rebuild or incomplete configuration
        if (Test-Path $BuildDir) {
            Write-Host "  Removing build dir $BuildDir for clean configuration..." -ForegroundColor DarkGray
            Remove-Item -Recurse -Force $BuildDir -ErrorAction SilentlyContinue
        }

        # Ensure keycodemapdb is present
        $kdbDir = Join-Path $QemuDir "subprojects\keycodemapdb"
        if (-not (Test-Path (Join-Path $kdbDir "data"))) {
            Write-Host "  Fetching keycodemapdb..." -ForegroundColor DarkGray
            if (Test-Path $kdbDir) { Remove-Item -Recurse -Force $kdbDir -ErrorAction SilentlyContinue }
            git clone --depth 1 https://gitlab.com/qemu-project/keycodemapdb.git $kdbDir
        }

        function ConvertTo-MsysPath([string]$winPath) {
            $p = (Resolve-Path $winPath).Path.Replace('\', '/')
            if ($p -match '^([a-zA-Z]):/(.*)') {
                return "/" + $Matches[1].ToLower() + "/" + $Matches[2]
            }
            return $p
        }

        $bashExe = Join-Path $usrBin "bash.exe"
        if (-not (Test-Path $bashExe)) {
            $bashCmd = Get-Command bash.exe -ErrorAction SilentlyContinue
            if ($bashCmd) { $bashExe = $bashCmd.Source }
        }

        $env:MSYSTEM = "CLANGARM64"
        if ($bashExe -and (Test-Path $bashExe)) {
            Write-Host "  Running QEMU configure using MSYS2 bash: $bashExe..." -ForegroundColor Cyan
            $msysQemu = ConvertTo-MsysPath $QemuDir
            $msysPkg  = ConvertTo-MsysPath (Join-Path $Prefix "lib\pkgconfig")
            $cfgScript = @"
export MSYSTEM=CLANGARM64
export PKG_CONFIG_PATH="$msysPkg":`$PKG_CONFIG_PATH
cd "$msysQemu"
./configure --target-list=aarch64-softmmu --without-default-features --enable-tcg --enable-whpx --enable-sdl --enable-slirp --enable-rutabaga-gfx --enable-vnc --enable-pixman
"@
            & $bashExe -lc $cfgScript
        } else {
            Write-Host "  Running QEMU configure using sh fallback..." -ForegroundColor Cyan
            $cfgArgs = @(
                "./configure",
                "--target-list=aarch64-softmmu",
                "--without-default-features",
                "--enable-tcg",
                "--enable-whpx",
                "--enable-sdl",
                "--enable-slirp",
                "--enable-rutabaga-gfx",
                "--enable-vnc",
                "--enable-pixman"
            )
            & sh @cfgArgs
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Host "=== QEMU configure failed with code $LASTEXITCODE ===" -ForegroundColor Red
            $cfgLog = Join-Path $BuildDir "config.log"
            if (Test-Path $cfgLog) {
                Write-Host "--- Last 100 lines of $cfgLog ---" -ForegroundColor Yellow
                Get-Content $cfgLog -Tail 100
            }
            $mesonLog = Join-Path $BuildDir "meson-logs\meson-log.txt"
            if (Test-Path $mesonLog) {
                Write-Host "--- Last 100 lines of $mesonLog ---" -ForegroundColor Yellow
                Get-Content $mesonLog -Tail 100
            }
            throw "QEMU configure failed with code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  QEMU already configured in $BuildDir" -ForegroundColor DarkGray
}

Write-Host "== [5/5] building qemu-system-aarch64.exe ==" -ForegroundColor Cyan
Push-Location $QemuDir
try {
    # Ensure rutabaga import libraries and DLLs are also present directly in the build directory
    foreach ($fn in @("rutabaga_gfx_ffi.dll", "rutabaga_gfx_ffi.dll.lib", "librutabaga_gfx_ffi.dll.a", "rutabaga_gfx_ffi.lib", "librutabaga_gfx_ffi.lib", "librutabaga_gfx_ffi.a")) {
        foreach ($srcDir in @((Join-Path $Prefix "lib"), (Join-Path $Prefix "bin"), (Join-Path $RutabagaDir "build-ffi\ffi"))) {
            $candidate = Join-Path $srcDir $fn
            if (Test-Path $candidate) {
                Copy-Item $candidate $BuildDir -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }

    Invoke-Ninja -C build qemu-system-aarch64.exe
} catch {
    Write-Host "=== QEMU ninja build failed ===" -ForegroundColor Red
    $mesonLog = Join-Path $BuildDir "meson-logs\meson-log.txt"
    if (Test-Path $mesonLog) {
        Write-Host "--- Last 100 lines of $mesonLog ---" -ForegroundColor Yellow
        Get-Content $mesonLog -Tail 100
    }
    throw
} finally {
    Pop-Location
}

# Copy rutabaga_gfx_ffi.dll and rutabaga libs into build dir if needed
foreach ($sub in @("bin\rutabaga_gfx_ffi.dll", "lib\rutabaga_gfx_ffi.dll")) {
    $dll = Join-Path $Prefix $sub
    if (Test-Path $dll) {
        Copy-Item $dll $BuildDir -Force
        break
    }
}

$exe = Join-Path $BuildDir "qemu-system-aarch64.exe"
if (Test-Path $exe) {
    $sObj = Get-Command strip.exe -ErrorAction SilentlyContinue
    $stripExe = $null
    if ($sObj) { $stripExe = $sObj.Source }
    if (-not $stripExe -and (Test-Path (Join-Path $clangBin "strip.exe"))) {
        $stripExe = Join-Path $clangBin "strip.exe"
    }
    if ($stripExe) {
        & $stripExe $exe
    }
    Write-Host "Custom QEMU build successful: $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Error "Custom QEMU build failed! Executable not found at $exe"
    exit 1
}
