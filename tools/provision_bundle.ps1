<#
.SYNOPSIS
    Provision the bundled QArmDroid runtime into a writable user dir.

.DESCRIPTION
    Used by the Tauri app on first launch of an installed (bundled) build.
    The installer places immutable pieces (custom QEMU + DLLs, kernel,
    initrd, boot images, super.img, pure-Python imgtools/m0_build) under
    the install resources dir. Program Files is read-only, so this script:

      1. mkdir %LOCALAPPDATA%\QArmDroid\qemu   <- copies qemu exe + *.dll
      2. mkdir %LOCALAPPDATA%\QArmDroid\image  <- copies kernel, initrd.img,
                                                   boot/init_boot/vendor_boot/
                                                   vbmeta*.img, super.img
      3. Builds disk.raw in %LOCALAPPDATA%\QArmDroid\image from the bundled
         super.img + boot images (via m0_build.py's pure-Python disk stage —
         ~10-20 min, sparse output, mostly zeros fast).

    After provisioning, launch.ps1 is invoked with
      -BundleRoot %LOCALAPPDATA%\QArmDroid
    which resolves qemu\qemu-system-aarch64.exe, image\kernel,
    image\initrd.img and image\disk.raw from there.

.PARAMETER InstallRoot
    The bundled resources dir (where the installer placed the pieces).
    Default: the directory containing this script's parent "resources".

.PARAMETER RuntimeRoot
    Destination writable dir. Default: %LOCALAPPDATA%\QArmDroid.

.PARAMETER Force
    Re-copy + rebuild even if artifacts already exist.

.PARAMETER SkipDisk
    Only sync qemu/image inputs; do NOT rebuild disk.raw.

.EXAMPLE
    powershell -File provision_bundle.ps1 -InstallRoot C:\Program Files\QArmDroid\resources
#>
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$RuntimeRoot,
    [switch]$Force,
    [switch]$SkipDisk
)

$ErrorActionPreference = "Continue"
if (-not $InstallRoot) { $InstallRoot = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $env:LOCALAPPDATA "QArmDroid"
}

$qemuSrc  = Join-Path $InstallRoot "qemu"
$imgSrc   = Join-Path $InstallRoot "image"
$toolsSrc = Join-Path $InstallRoot "tools"
$qemuDst  = Join-Path $RuntimeRoot "qemu"
$imgDst   = Join-Path $RuntimeRoot "image"
$toolsDst = Join-Path $RuntimeRoot "tools"

foreach ($d in @($qemuDst, $imgDst, $toolsDst)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$imageInputs = @("kernel","initrd.img","boot.img","init_boot.img","vendor_boot.img",
                 "vbmeta.img","vbmeta_system.img","vbmeta_system_dlkm.img",
                 "vbmeta_vendor_dlkm.img","super.img")

$needSync = $Force -or -not (Test-Path (Join-Path $qemuDst "qemu-system-aarch64.exe"))

if ($needSync) {
    Write-Host "== syncing QEMU runtime ==" -ForegroundColor Cyan
    Copy-Item (Join-Path $qemuSrc "qemu-system-aarch64.exe") $qemuDst -Force
    Get-ChildItem $qemuSrc -Filter "*.dll" -ErrorAction SilentlyContinue |
        Copy-Item -Destination $qemuDst -Force

    Write-Host "== syncing image inputs ==" -ForegroundColor Cyan
    foreach ($n in $imageInputs) {
        $s = Join-Path $imgSrc $n
        if (Test-Path $s) { Copy-Item $s (Join-Path $imgDst $n) -Force }
    }

    Write-Host "== syncing tools ==" -ForegroundColor Cyan
    foreach ($n in @("imgtools.py","m0_build.py")) {
        $s = Join-Path $toolsSrc $n
        if (Test-Path $s) { Copy-Item $s (Join-Path $toolsDst $n) -Force }
    }
} else {
    Write-Host "runtime already provisioned (use -Force to re-sync)" -ForegroundColor DarkGray
}

# --------------------------------------------------------------- disk.raw --- #
$disk = Join-Path $imgDst "disk.raw"
if ($SkipDisk -or ((Test-Path $disk) -and -not $Force)) {
    Write-Host "disk.raw present: $disk" -ForegroundColor Green
} else {
    if (-not (Test-Path (Join-Path $imgDst "super.img"))) {
        Write-Error "super.img missing in $imgDst — cannot build disk.raw"
    }
    Write-Host "== building disk.raw (this takes a while) ==" -ForegroundColor Cyan
    Push-Location $toolsDst
    try {
        $py = "python"
        $cmd = @("$toolsDst\m0_build.py", "disk", "QARM_BUNDLE=$RuntimeRoot")
        & $py $cmd
        if ($LASTEXITCODE -ne 0) {
            Write-Error "m0_build disk stage failed (exit $LASTEXITCODE)"
        }
    }
    finally { Pop-Location }
    if (Test-Path $disk) {
        Write-Host "disk.raw built: $((Get-Item $disk).Length/1GB) GB" -ForegroundColor Green
    } else {
        Write-Error "disk.raw not produced"
    }
}

Write-Host "== done ==" -ForegroundColor Green
Write-Host "runtime: $RuntimeRoot" -ForegroundColor DarkGray
Write-Host ("launch:  powershell -File {0}\tools\launch.ps1 -BundleRoot {0} -DisplayMode embedded -GpuMode basic" -f $RuntimeRoot) -ForegroundColor DarkGray