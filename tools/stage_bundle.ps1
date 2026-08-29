<#
.SYNOPSIS
    Stage the QArmDroid installer resources (custom QEMU + Android image).

.DESCRIPTION
    Assembles src-tauri\resources\ from the repo's verified working state so
    `npx tauri build` produces an installer that is self-contained:

        resources\qemu\qemu-system-aarch64.exe   (+ runtime DLLs beside it)
        resources\image\kernel, initrd.img, boot.img, init_boot.img,
                      vendor_boot.img, vbmeta*.img, super.img
        resources\tools\launch.ps1, provision_bundle.ps1, m0_build.py,
                      imgtools.py

    The 16 GB disk.raw is NOT bundled; provision_bundle.ps1 rebuilds it on
    first run into %LOCALAPPDATA%\QArmDroid from the ~1.5 GB super.img.

    Output goes to src-tauri\resources\ (referenced by tauri.conf.json
    bundle.resources). Runs from any cwd.

.PARAMETER NoQemu
    Skip copying the QEMU binary (already staged); only refresh image/tools.

.EXAMPLE
    powershell -File tools\stage_bundle.ps1
#>
[CmdletBinding()]
param([switch]$NoQemu)

$ErrorActionPreference = "Continue"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$ResDir   = Join-Path $RepoRoot "src-tauri\resources"
$ImgDir   = Join-Path $RepoRoot "aosp_cf_arm64_only_phone-img"
$M0Dir    = Join-Path $ImgDir "work\m0"
$QemuBuild= Join-Path $RepoRoot "tools\qemu-gfxstream\qemu\build"

foreach ($d in @("$ResDir\qemu", "$ResDir\image", "$ResDir\tools")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# ---------------------------------------------------------------- QEMU ------ #
if (-not $NoQemu) {
    Write-Host "== staging QEMU ==" -ForegroundColor Cyan
    $exe = Join-Path $QemuBuild "qemu-system-aarch64.exe"
    if (-not (Test-Path $exe)) { Write-Error "custom QEMU not found: $exe (build first per BUILD_LOG)" }
    Copy-Item $exe (Join-Path $ResDir "qemu") -Force
    Get-ChildItem $QemuBuild -Filter "*.dll" | Copy-Item -Destination (Join-Path $ResDir "qemu") -Force
    # pixman + other msys2 runtime DLLs the custom build needs (live in msys64 bin)
    foreach ($dll in @("libpixman-1-0.dll","libzstd-1.dll")) {
        $s = Join-Path "C:\msys64\clangarm64\bin" $dll
        if (Test-Path $s) { Copy-Item $s (Join-Path $ResDir "qemu") -Force }
    }
}

# ---------------------------------------------------------------- image ----- #
Write-Host "== staging image inputs ==" -ForegroundColor Cyan
$kernel = Join-Path $ImgDir "out\kernel"
if (-not (Test-Path $kernel)) { Write-Error "kernel not found: $kernel" }
Copy-Item $kernel (Join-Path $ResDir "image\kernel") -Force

$initrd = Join-Path $M0Dir "initrd.img"
if (-not (Test-Path $initrd)) { Write-Error "initrd.img not found: $initrd (run python tools/m0_build.py bootconfig; initrd)" }
Copy-Item $initrd (Join-Path $ResDir "image\initrd.img") -Force

foreach ($n in @("boot.img","init_boot.img","vendor_boot.img","vbmeta.img",
                 "vbmeta_system.img","vbmeta_system_dlkm.img","vbmeta_vendor_dlkm.img","super.img")) {
    $s = Join-Path $ImgDir $n
    if (Test-Path $s) { Copy-Item $s (Join-Path $ResDir "image") -Force }
    else { Write-Host "  (missing optional: $n)" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- tools ----- #
Write-Host "== staging tools ==" -ForegroundColor Cyan
foreach ($n in @("launch.ps1","provision_bundle.ps1","m0_build.py","imgtools.py")) {
    $s = Join-Path (Join-Path $RepoRoot "tools") $n
    if (Test-Path $s) { Copy-Item $s (Join-Path $ResDir "tools") -Force }
}

# -------------------------------------------------------------- summary ---- #
Write-Host ""
Write-Host "== resources staged ==" -ForegroundColor Green
$total = 0
Get-ChildItem $ResDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Replace("$ResDir\", "")
    $mb = $_.Length / 1MB
    $total += $_.Length
    Write-Host ("  {0,8:N1} MB  {1}" -f $mb, $rel)
}
Write-Host ("  --------  TOTAL {0:N1} MB" -f ($total/1MB)) -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: npx tauri build   (embeds resources into the installer)" -ForegroundColor Yellow