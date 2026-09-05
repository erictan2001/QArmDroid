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

foreach ($d in @("$ResDir\qemu", "$ResDir\image", "$ResDir\tools", "$ResDir\scrcpy")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# ---------------------------------------------------------------- scrcpy ---- #
Write-Host "== staging Scrcpy ==" -ForegroundColor Cyan
$scrcpySrc = Join-Path $RepoRoot "tools\scrcpy"
if (Test-Path $scrcpySrc) {
    Copy-Item (Join-Path $scrcpySrc "*") (Join-Path $ResDir "scrcpy") -Recurse -Force
} else {
    Write-Warning "tools\scrcpy not found at $scrcpySrc"
}

# ---------------------------------------------------------------- QEMU ------ #
if (-not $NoQemu) {
    Write-Host "== staging QEMU ==" -ForegroundColor Cyan
    $exe = Join-Path $QemuBuild "qemu-system-aarch64.exe"
    if (-not (Test-Path $exe)) { Write-Error "custom QEMU not found: $exe (build first per BUILD_LOG)" }
    Copy-Item $exe (Join-Path $ResDir "qemu") -Force
    Get-ChildItem $QemuBuild -Filter "*.dll" | Copy-Item -Destination (Join-Path $ResDir "qemu") -Force
    # pixman + other msys2 runtime DLLs the custom build needs (live in msys64 bin).
    # SDL2.dll (display window) and libslirp-0.dll (user-mode networking) are
    # imported by qemu-system-aarch64.exe but absent from the build dir; without
    # them the bundled QEMU fails with STATUS_DLL_NOT_FOUND at launch.
    foreach ($dll in @("libpixman-1-0.dll","libzstd-1.dll","SDL2.dll","libslirp-0.dll")) {
        $s = Join-Path "C:\msys64\clangarm64\bin" $dll
        if (Test-Path $s) { Copy-Item $s (Join-Path $ResDir "qemu") -Force }
    }

    # QEMU data dir (share\qemu): the custom build defaults to its compile-time
    # datadir (C:\msys64\...\share\qemu) which end-user machines lack. Without
    # it QEMU fails at launch ("failed to find romfile efi-virtio.rom", "could
    # not find keymap file for language 'en-us'"). Ship the whole data dir
    # (ROMs + keymaps + dtb + firmware) under qemu\share\qemu and point -L at
    # it in launch.ps1.
    $fwSrc = "C:\msys64\clangarm64\share\qemu"
    $fwDst = Join-Path $ResDir "qemu\share\qemu"
    New-Item -ItemType Directory -Force -Path $fwDst | Out-Null
    if (Test-Path $fwSrc) {
        # Copy everything EXCEPT edk2 UEFI images: the emulator boots via
        # -kernel/-initrd direct boot, so UEFI firmware is never loaded. The
        # edk2-*.fd blobs (~250 MB) would push the NSIS installer past its
        # 2 GB mmap limit ("Internal compiler error #12345").
        Copy-Item (Join-Path $fwSrc "*") $fwDst -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $fwDst -Recurse -Filter "edk2*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
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

# ---------------------------------------------------------------- python ------ #
Write-Host "== staging Python embeddable ==" -ForegroundColor Cyan
$pyDir = Join-Path $ResDir "python"
New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
$zip = "tools\python-3.12-embed-arm64.zip"
if (-not (Test-Path $zip)) { Write-Error "Python embeddable zip not found: $zip" }
Expand-Archive -Force -Path $zip -DestinationPath $pyDir
# pysite for tempfile fix
$pysiteSrc = Join-Path $RepoRoot "tools\qemu-gfxstream\pysite"
if (Test-Path $pysiteSrc) { Copy-Item -Recurse -Force $pysiteSrc (Join-Path $pyDir "pysite") }
# python312._pth already includes .\ and .\Lib; ensure it includes Lib\ and .
$pth = Join-Path $pyDir "python312._pth"
if (Test-Path $pth) {
    $c = Get-Content $pth -Raw
    if ($c -notmatch "Lib\\") { Add-Content $pth "Lib\" }
}
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