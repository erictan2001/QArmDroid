<#
.SYNOPSIS
    Prepare the Cuttlefish ARM64 image directory (aosp_cf_arm64_only_phone-img)
    from a downloaded AOSP Cuttlefish arm64 image, so that m0_build.py and
    reproduce.ps1 can build the boot artifacts.

.DESCRIPTION
    The Android 16 Cuttlefish ARM64 image is NOT in this repo (12 GB+, gitignored).
    This script turns a downloaded Cuttlefish arm64 image into the exact layout
    m0_build.py expects:

        boot.img  init_boot.img  vendor_boot.img  vbmeta*.img  super.img   (from image zip)
        out_init/ramdisk                  <- unpack_bootimg(init_boot.img) -> lz4 -d
        out_vendor/vendor_ramdisk00       <- unpack_bootimg(vendor_boot.img)
        work/init/fs/                     <- cpio extract of init ramdisk (for /init)
        work/vend/fs/                     <- cpio extract of vendor ramdisk (for fstab)
        work/vend/fs/first_stage_ramdisk/system/etc/fstab.cf.ext4.cts
        work/m0/                         <- created by m0_build.py stages

    IMAGE SOURCE (one of):
      1) -ImageZip <path>    : aosp_cf_arm64_only_phone-img-*.zip downloaded manually
                               (unzipped to a temp dir; boot.img/super.img/etc. copied in).
      2) -ImageDir  <path>   : directory already containing the image files
                               (boot.img, init_boot.img, vendor_boot.img, vbmeta*.img,
                               super.img) - typically the unzipped image directory.
      3) -Automated          : attempt ci.android.com fetch_cvd download (see notes).

    After the image files are present, it unconditionally re-runs the unpack
    steps (idempotent) and finishes with "READY" when m0_build.py's preflight
    would pass.

.NOTES
    Requires: python 3 (stdlib only). Uses tools\imgtools.py (pure-Python
    lz4 decompress + cpio extract) - NO msys2 / busybox / lz4.exe needed.
    Run tools\bootstrap_env.ps1 first to verify python, or pass -Python.

.EXAMPLE
    .\tools\setup_image.ps1 -ImageDir C:\Users\me\Downloads\aosp_cf_arm64_only_phone-img-11111111
    .\tools\setup_image.ps1 -ImageZip C:\Users\me\Downloads\aosp_cf_arm64_only_phone-img-11111111.zip
#>
[CmdletBinding()]
param(
    [string]$ImageZip,
    [string]$ImageDir,
    [switch]$Automated,
    [string]$BuildId  = "15357239",
    [switch]$ForceDownload,
    [string]$Python   = "python"
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$ImgDir   = Join-Path $RepoRoot "aosp_cf_arm64_only_phone-img"
$Tools    = Join-Path $RepoRoot "tools"

if (-not (Test-Path "$Tools\mkbootimg\unpack_bootimg.py")) { Write-Error "unpack_bootimg.py missing" }
if (-not (Test-Path "$Tools\imgtools.py")) { Write-Error "imgtools.py missing" }

New-Item -ItemType Directory -Force -Path $ImgDir | Out-Null
# Image files (boot.img, super.img, ...) must live at the ImgDir ROOT -
# m0_build.py reads them as $IMG\boot.img etc. (see disk stage lines 470-485).
$img = $ImgDir

function Get-ImageFiles {
    # returns $true if the standard image files are present in $img
    $need = @("boot.img","init_boot.img","vendor_boot.img","vbmeta.img","super.img")
    $ok = $true
    foreach ($n in $need) { if (-not (Test-Path (Join-Path $img $n))) { $ok = $false } }
    return $ok
}

# ------------------------------------------------------------- image source #
if ($ImageZip) {
    if (-not (Test-Path $ImageZip)) { Write-Error "ImageZip not found: $ImageZip" }
    Write-Host "== unzipping $ImageZip ==" -ForegroundColor Cyan
    $tmp = Join-Path $ImgDir "_unzip"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Expand-Archive -Path $ImageZip -DestinationPath $tmp -Force
    # find the directory holding boot.img / super.img
    $src = Get-ChildItem -Path $tmp -Recurse -Filter boot.img -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty DirectoryName
    if (-not $src) { Write-Error "no boot.img found inside the zip - is this really the CF arm64 image zip?" }
    Write-Host "   image files in: $src" -ForegroundColor DarkGray
    $ImageDir = $src
}
elseif ($ImageDir) {
    if (-not (Test-Path (Join-Path $ImageDir "boot.img"))) {
        # maybe user pointed at a parent dir; search
        $src = Get-ChildItem -Path $ImageDir -Recurse -Filter boot.img -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty DirectoryName
        if ($src) { $ImageDir = $src } else { Write-Error "boot.img not found under $ImageDir" }
    }
}
elseif ($Automated -or $ForceDownload -or (-not (Get-ImageFiles))) {
    Write-Host "== automated AOSP Cuttlefish ARM64 download (Build ID: $BuildId) ==" -ForegroundColor Cyan
    $zipName = "aosp_cf_arm64_only_phone-img-$BuildId.zip"
    $downloadZip = Join-Path $ImgDir $zipName
    $url = "https://ci.android.com/builds/submitted/$BuildId/aosp_cf_arm64_only_phone-userdebug/latest/raw/$zipName"

    if ($ForceDownload -or -not (Test-Path $downloadZip) -or ((Get-Item $downloadZip).Length -lt 500000000)) {
        Write-Host "Downloading from $url..." -ForegroundColor Yellow
        $downloadSuccess = $false
        $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curlCmd) {
            Write-Host "Downloading via curl..."
            & $curlCmd.Source -L --fail --show-error -o $downloadZip $url
            if ($LASTEXITCODE -eq 0 -and (Test-Path $downloadZip) -and ((Get-Item $downloadZip).Length -gt 500000000)) {
                $downloadSuccess = $true
            }
        }
        if (-not $downloadSuccess) {
            Write-Host "Downloading via WebClient..."
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                $wc.DownloadFile($url, $downloadZip)
                if ((Test-Path $downloadZip) -and ((Get-Item $downloadZip).Length -gt 500000000)) {
                    $downloadSuccess = $true
                }
            } catch {
                Write-Warning "WebClient download failed: $_"
            }
        }
        if (-not $downloadSuccess) {
            Write-Error "Failed to download AOSP Cuttlefish ARM64 image from $url"
            exit 1
        }
    }

    Write-Host "== unzipping $downloadZip ==" -ForegroundColor Cyan
    $tmp = Join-Path $ImgDir "_unzip"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Expand-Archive -Path $downloadZip -DestinationPath $tmp -Force
    $src = Get-ChildItem -Path $tmp -Recurse -Filter boot.img -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty DirectoryName
    if (-not $src) { Write-Error "no boot.img found inside downloaded zip" }
    Write-Host "   image files in: $src" -ForegroundColor DarkGray
    $ImageDir = $src
}
elseif (Get-ImageFiles) {
    Write-Host "== reusing existing image files in $ImgDir ==" -ForegroundColor Green
    $ImageDir = $ImgDir
}
else {
    Write-Error "No image source: pass -ImageZip, -ImageDir, or -Automated."
}

Write-Host "== copying image files ==" -ForegroundColor Cyan
$copy = @("boot.img","init_boot.img","vendor_boot.img","vbmeta.img","vbmeta_system.img",
          "vbmeta_system_dlkm.img","vbmeta_vendor_dlkm.img","super.img","android-info.txt")
foreach ($n in $copy) {
    $s = Join-Path $ImageDir $n
    if (Test-Path $s) { Copy-Item $s (Join-Path $img $n) -Force }
    else { Write-Host "   (optional/absent: $n)" -ForegroundColor DarkGray }
}

if (-not (Get-ImageFiles)) {
    Write-Host "Missing required image files after copy. Have:" -ForegroundColor Red
    Get-ChildItem $img | Select-Object Name
    Write-Error "Image incomplete - see README for the correct CF arm64 image."
}

# --------------------------------------------------------- unpack boot img  #
# boot.img -> out_boot (kernel, ramdisk)
$outBoot = Join-Path $ImgDir "out_boot"
New-Item -ItemType Directory -Force -Path $outBoot | Out-Null
Write-Host "== unpack boot.img ==" -ForegroundColor Cyan
& $Python "$Tools\mkbootimg\unpack_bootimg.py" --boot_img (Join-Path $img "boot.img") --out $outBoot 2>&1 | Out-Null

$outKernelDir = Join-Path $ImgDir "out"
New-Item -ItemType Directory -Force -Path $outKernelDir | Out-Null
$bootKernel = Join-Path $outBoot "kernel"
if (Test-Path $bootKernel) {
    Copy-Item $bootKernel (Join-Path $outKernelDir "kernel") -Force
    Write-Host "   staged kernel -> out/kernel" -ForegroundColor DarkGray
} else {
    Write-Error "unpack_bootimg did not produce out_boot/kernel"
}

# init_boot.img -> out_init/ramdisk (lz4 cpio)
$outInit = Join-Path $ImgDir "out_init"
New-Item -ItemType Directory -Force -Path $outInit | Out-Null
Write-Host "== unpack init_boot.img ==" -ForegroundColor Cyan
& $Python "$Tools\mkbootimg\unpack_bootimg.py" --boot_img (Join-Path $img "init_boot.img") --out $outInit 2>&1 | Out-Null
if (-not (Test-Path (Join-Path $outInit "ramdisk"))) {
    Write-Error "unpack_bootimg did not produce out_init/ramdisk"
}

# vendor_boot.img -> out_vendor/vendor_ramdisk00 (v4 header lists it by name)
$outVend = Join-Path $ImgDir "out_vendor"
New-Item -ItemType Directory -Force -Path $outVend | Out-Null
Write-Host "== unpack vendor_boot.img ==" -ForegroundColor Cyan
& $Python "$Tools\mkbootimg\unpack_bootimg.py" --boot_img (Join-Path $img "vendor_boot.img") --out $outVend 2>&1 | Out-Null
if (-not (Test-Path (Join-Path $outVend "vendor_ramdisk00"))) {
    Write-Error "unpack_bootimg did not produce out_vendor/vendor_ramdisk00"
}

# ---------------------------------------------------- cpio extract ramdisks #
function Expand-Ramdisk($lz4File, $destDir) {
    # Pure-Python: lz4-decompress (legacy/standard) + newc cpio extract.
    $script = @"
import sys
sys.path.insert(0, r'$Tools')
import imgtools, os
data = open(r'$lz4File', 'rb').read()
raw = imgtools.lz4_decompress(data)
files = imgtools.cpio_newc_extract(raw, r'$destDir')
print('extracted %d entries' % len(files))
"@
    & $Python -c $script 2>&1 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Write-Error "ramdisk extract failed for $lz4File" }
}

# work/init/fs  (for /init -> swapped for init_wrapper.elf)
$initFs = Join-Path $ImgDir "work\init\fs"
New-Item -ItemType Directory -Force -Path $initFs | Out-Null
Write-Host "== extract init ramdisk -> work/init/fs ==" -ForegroundColor Cyan
Expand-Ramdisk (Join-Path $outInit "ramdisk") $initFs
if (-not (Test-Path (Join-Path $initFs "init"))) {
    Write-Host "WARNING: work/init/fs/init not found - check ramdisk layout" -ForegroundColor Yellow
}

# work/vend/fs  (for fstab.cf.ext4.cts)
$vendFs = Join-Path $ImgDir "work\vend\fs"
New-Item -ItemType Directory -Force -Path $vendFs | Out-Null
Write-Host "== extract vendor ramdisk -> work/vend/fs ==" -ForegroundColor Cyan
Expand-Ramdisk (Join-Path $outVend "vendor_ramdisk00") $vendFs

$fstab = Join-Path $vendFs "first_stage_ramdisk\system\etc\fstab.cf.ext4.cts"
if (-not (Test-Path $fstab)) {
    # try alternate locations under work\vend
    $searchDir = Join-Path $ImgDir "work\vend"
    $alt = Get-ChildItem -Path $searchDir -Recurse -Filter "fstab.cf.ext4.cts" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($alt) {
        Write-Host "   fstab found at: $alt" -ForegroundColor DarkGray
        New-Item -ItemType Directory -Force -Path (Split-Path $fstab) | Out-Null
        Copy-Item $alt $fstab -Force
    } else {
        Write-Host "WARNING: fstab.cf.ext4.cts not found - m0_build initrd stage will fail." -ForegroundColor Red
    }
}

# ------------------------------------------------ build boot artifacts ----- #
Write-Host "== building bootconfig and initrd ==" -ForegroundColor Cyan
& $Python (Join-Path $Tools "m0_build.py") bootconfig
if ($LASTEXITCODE -ne 0) { Write-Error "m0_build.py bootconfig failed"; exit 1 }
& $Python (Join-Path $Tools "m0_build.py") initrd
if ($LASTEXITCODE -ne 0) { Write-Error "m0_build.py initrd failed"; exit 1 }

# --------------------------------------------------------------- final check #
Write-Host ""
Write-Host "== summary ==" -ForegroundColor Green
foreach ($p in @("boot.img","super.img","init_boot.img","vendor_boot.img",
                 "out\kernel","work\m0\bootconfig.bin","work\m0\initrd.img",
                 "work\vend\fs\first_stage_ramdisk\system\etc\fstab.cf.ext4.cts")) {
    $full = Join-Path $ImgDir $p
    Write-Host "  $p : $(Test-Path $full)" -ForegroundColor $(if (Test-Path $full) {"Green"} else {"Yellow"})
}
Write-Host ""
Write-Host "Ready! You can now run tools\stage_bundle.ps1 to prepare installer resources." -ForegroundColor Green