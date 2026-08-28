<#
.SYNOPSIS
    Reproduce the WORKING Android 16 ARM64 emulator state from repo artifacts.

.DESCRIPTION
    Minimal end-to-end reproduction of the verified working configuration
    (SDL window + SwiftShader guest GPU):
      1. Rebuild bootconfig + initrd (ORDER MATTERS: bootconfig first, initrd
         reads the existing bootconfig.bin).
      2. Rebuild the GPT disk if absent (disk.raw 16 GB sparse).
      3. Launch QEMU with -DisplayMode sdl -GpuMode basic.
      4. Wait for ADB, then apply runtime display fixes (wm size/density) and
         report boot completion.

    This is the SUPPORTED configuration. gfxstream/ranchu GPU passthrough is
    documented but BLOCKED (see README "GPU passthrough" section).

.PARAMETER RebuildDisk
    Force rebuild of disk.raw (slow, ~10-15 min; skip if disk.raw exists).
    Without it, an existing disk.raw is reused.

.PARAMETER Memory / Cores
    Guest RAM (default 6G) and vCPU count (default 6).

.PARAMETER NoLaunch
    Build artifacts only; do not start the emulator.

.EXAMPLE
    # Full reproduce: build + launch (reuses existing disk.raw)
    .\tools\reproduce.ps1

    # Fresh disk + full build + launch
    .\tools\reproduce.ps1 -RebuildDisk
#>
[CmdletBinding()]
param(
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
$Adb      = "C:\platform-tools\adb.exe"

# ------------------------------------------------------------ preflight ---- #
Write-Host "== preflight ==" -ForegroundColor Cyan
foreach ($p in @($ImgDir, $M0Dir)) {
    if (-not (Test-Path $p)) { Write-Error "Missing directory: $p" }
}
# Source image pieces needed by m0_build.py
$need = @(
    (Join-Path $ImgDir "boot.img"),
    (Join-Path $ImgDir "init_boot.img"),
    (Join-Path $ImgDir "vendor_boot.img"),
    (Join-Path $ImgDir "vbmeta.img"),
    (Join-Path $ImgDir "super.img"),
    (Join-Path $ImgDir "out_init\ramdisk"),
    (Join-Path $ImgDir "out_vendor\vendor_ramdisk00")
)
$missing = $need | Where-Object { -not (Test-Path $_) }
if ($missing) {
    Write-Host "Missing source image pieces (need to extract/untar the Cuttlefish image):" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "    $_" }
    Write-Error "Source image incomplete"
}
if (-not (Test-Path $Adb)) { Write-Host "ADB not found at $Adb — install platform-tools" -ForegroundColor Yellow }

# --------------------------------------------------- build artifacts ------ #
Write-Host "== build: bootconfig ==" -ForegroundColor Cyan
Push-Location $RepoRoot
try {
    & $Py "tools\m0_build.py" bootconfig
    if ($LASTEXITCODE -ne 0) { throw "bootconfig stage failed" }

    Write-Host "== build: initrd ==" -ForegroundColor Cyan
    & $Py "tools\m0_build.py" initrd
    if ($LASTEXITCODE -ne 0) { throw "initrd stage failed" }

    if ($RebuildDisk -or -not (Test-Path (Join-Path $M0Dir "disk.raw"))) {
        Write-Host "== build: disk (this takes a while) ==" -ForegroundColor Cyan
        & $Py "tools\m0_build.py" disk
        if ($LASTEXITCODE -ne 0) { throw "disk stage failed" }
    } else {
        Write-Host "== disk.raw exists — reusing ==" -ForegroundColor DarkGray
    }

    # Verify the density fix made it into the built bootconfig (regression guard)
    $raw = [System.IO.File]::ReadAllBytes((Join-Path $M0Dir "bootconfig.bin"))
    $txt = [System.Text.Encoding]::ASCII.GetString($raw)
    if ($txt -notmatch "lcd_density=240") {
        Write-Host "WARNING: bootconfig.bin missing lcd_density=240 — display may be cut off" -ForegroundColor Yellow
    } else {
        Write-Host "OK: bootconfig has lcd_density=240" -ForegroundColor Green
    }
}
finally { Pop-Location }

if ($NoLaunch) {
    Write-Host "== artifacts built; -NoLaunch set, not starting VM ==" -ForegroundColor Green
    return
}

# -------------------------------------------------------------- launch ---- #
Write-Host "== launch (SDL + basic) ==" -ForegroundColor Cyan
$launch = Join-Path $RepoRoot "tools\launch.ps1"
& $launch -DisplayMode sdl -GpuMode basic -Memory $Memory -Cores $Cores

# ------------------------------------------------------- boot watchdog ---- #
Write-Host "== waiting for boot (ADB) ==" -ForegroundColor Cyan
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
    Write-Host "TIMEOUT waiting for boot — check $M0Dir\serial.log" -ForegroundColor Red
}