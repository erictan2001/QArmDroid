<#
.SYNOPSIS
    ONE-SHOT reproduce: turn a fresh clone into a WORKING Android 16 ARM64
    emulator (SDL window + SwiftShader guest GPU) on Windows ARM64.

.DESCRIPTION
    Orchestrates the full pipeline from a clean clone:

      1. bootstrap_env.ps1   - detect python / adb / qemu (writes tools\env.json)
      2. apply_patches.ps1   - apply custom QEMU/gfxstream patches to the
                               nested source trees (idempotent)
      3. setup_image.ps1     - unpack the Cuttlefish image pieces into the
                               layout m0_build.py expects (pass -ImageZip or
                               -ImageDir the first time; afterwards it reuses
                               the existing image dir)
      4. Build boot artifacts - python tools\m0_build.py bootconfig
                               (ORDER MATTERS: bootconfig -> initrd)
                               python tools\m0_build.py initrd
                               python tools\m0_build.py disk   (if missing)
      5. Launch QEMU           - -DisplayMode sdl -GpuMode basic
      6. Boot watchdog         - wait for sys.boot_completed=1, re-assert
                                 wm size/density, print resolved display.

    Pure-Python image tools (tools\imgtools.py) mean NO msys2 lz4/simg2img or
    busybox cpio are needed to build the boot artifacts. The only external
    programs required are Python 3, ADB, and an aarch64 QEMU.

.PARAMETER ImageZip
    Path to the Cuttlefish arm64 image zip (first run). Ignored if the image
    dir already has the pieces.

.PARAMETER ImageDir
    Path to the already-unpacked Cuttlefish arm64 image directory.

.PARAMETER RebuildDisk
    Force rebuild of disk.raw (slow, ~10-15 min; skip if disk.raw exists).

.PARAMETER Memory / Cores
    Guest RAM (default 6G) and vCPU count (default 6).

.PARAMETER NoLaunch
    Build artifacts only; do not start the emulator.

.EXAMPLE
    # First run (needs the image zip):
    .\tools\reproduce.ps1 -ImageZip C:\Users\me\Downloads\aosp_cf_arm64_only_phone-img-22222.zip
    # After that:
    .\tools\reproduce.ps1
#>
[CmdletBinding()]
param(
    [string]$ImageZip,
    [string]$ImageDir,
    [switch]$RebuildDisk,
    [string]$Memory = "6G",
    [int]$Cores = 6,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$ImgDir   = Join-Path $RepoRoot "aosp_cf_arm64_only_phone-img"
$M0Dir    = Join-Path $ImgDir "work\m0"
$Py       = "python"

# ---------------------------------------------------------- environment ---- #
Write-Host "== [1/6] environment ==" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "bootstrap_env.ps1")
$envFile = Join-Path $PSScriptRoot "env.json"
if (Test-Path $envFile) {
    $envJson = Get-Content $envFile -Raw | ConvertFrom-Json
    if ($envJson.python) { $Py = $envJson.python }
}

# --------------------------------------------------------------- patches --- #
Write-Host "== [2/6] patches (custom QEMU/gfxstream) ==" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "apply_patches.ps1")

# ------------------------------------------------------------ image setup -- #
Write-Host "== [3/6] image ==" -ForegroundColor Cyan
$imgArgs = @()
if ($ImageZip)  { $imgArgs += @("-ImageZip", $ImageZip) }
if ($ImageDir)  { $imgArgs += @("-ImageDir", $ImageDir) }
if ($imgArgs.Count -eq 0 -and -not (Test-Path (Join-Path $ImgDir "super.img"))) {
    Write-Host "No image present and none given. You MUST download the Cuttlefish" -ForegroundColor Red
    Write-Host "ARM64 image and pass -ImageZip or -ImageDir. See README 'Image download'." -ForegroundColor Red
    Write-Error "missing image (see README)"
}
if ($imgArgs.Count -gt 0) {
    & (Join-Path $PSScriptRoot "setup_image.ps1") @imgArgs
} else {
    Write-Host "  reusing existing image dir: $ImgDir" -ForegroundColor DarkGray
}

# ------------------------------------------------------ build artifacts ---- #
Write-Host "== [4/6] build bootconfig + initrd ==" -ForegroundColor Cyan
Push-Location $RepoRoot
try {
    & $Py "tools\m0_build.py" bootconfig
    if ($LASTEXITCODE -ne 0) { throw "bootconfig stage failed" }
    & $Py "tools\m0_build.py" initrd
    if ($LASTEXITCODE -ne 0) { throw "initrd stage failed" }

    if ($RebuildDisk -or -not (Test-Path (Join-Path $M0Dir "disk.raw"))) {
        Write-Host "== build: disk (this takes a while) ==" -ForegroundColor Cyan
        & $Py "tools\m0_build.py" disk
        if ($LASTEXITCODE -ne 0) { throw "disk stage failed" }
    } else {
        Write-Host "== disk.raw exists - reusing ==" -ForegroundColor DarkGray
    }

    # Regression guard: the density fix must be in the built bootconfig
    $raw = [System.IO.File]::ReadAllBytes((Join-Path $M0Dir "bootconfig.bin"))
    $txt = [System.Text.Encoding]::ASCII.GetString($raw)
    if ($txt -notmatch "lcd_density=240") {
        Write-Host "WARNING: bootconfig.bin missing lcd_density=240 - display may be cut off" -ForegroundColor Yellow
    } else {
        Write-Host "OK: bootconfig has lcd_density=240" -ForegroundColor Green
    }
}
finally { Pop-Location }

if ($NoLaunch) {
    Write-Host "== artifacts built; -NoLaunch set, not starting VM ==" -ForegroundColor Green
    return
}

# ----------------------------------------------------------------- launch -- #
Write-Host "== [5/6] launch (SDL + basic) ==" -ForegroundColor Cyan
$launch = Join-Path $RepoRoot "tools\launch.ps1"
& $launch -DisplayMode sdl -GpuMode basic -Memory $Memory -Cores $Cores

# ------------------------------------------------------- boot watchdog ---- #
$sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
$Adb = if ($envJson -and $envJson.adb -and (Test-Path $envJson.adb)) {
    $envJson.adb
} elseif (Test-Path (Join-Path $env:LOCALAPPDATA "QArmDroid\platform-tools\adb.exe")) {
    Join-Path $env:LOCALAPPDATA "QArmDroid\platform-tools\adb.exe"
} elseif (Test-Path (Join-Path $env:LOCALAPPDATA "QArmDroid\scrcpy\adb.exe")) {
    Join-Path $env:LOCALAPPDATA "QArmDroid\scrcpy\adb.exe"
} elseif (Test-Path "$PSScriptRoot\platform-tools\adb.exe") {
    "$PSScriptRoot\platform-tools\adb.exe"
} elseif (Test-Path "$PSScriptRoot\scrcpy\adb.exe") {
    "$PSScriptRoot\scrcpy\adb.exe"
} elseif (Get-Command adb -ErrorAction SilentlyContinue) {
    (Get-Command adb).Source
} elseif (Test-Path "$sysDrive\platform-tools\adb.exe") {
    "$sysDrive\platform-tools\adb.exe"
} else {
    "adb"
}
$deadline = (Get-Date).AddMinutes(10)
$booted = $false
& $Adb connect 127.0.0.1:5555 2>$null | Out-Null
while ((Get-Date) -lt $deadline) {
    $s = & $Adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>$null
    if ($s -match "1") { $booted = $true; break }
    Start-Sleep -Seconds 5
}
if ($booted) {
    Write-Host "boot_completed=1" -ForegroundColor Green
    & $Adb -s 127.0.0.1:5555 shell "wm size; wm density" 2>$null
} else {
    Write-Host "TIMEOUT waiting for boot - check $M0Dir\serial.log" -ForegroundColor Red
}