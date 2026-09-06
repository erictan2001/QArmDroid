<#
.SYNOPSIS
    Stage the QArmDroid installer resources (custom QEMU + Android image + tools).

.DESCRIPTION
    Assembles src-tauri\resources\ so `npx tauri build` produces an installer
    that is 100% self-contained and fully functional:

        resources\qemu\qemu-system-aarch64.exe   (+ all runtime DLLs beside it + share\qemu)
        resources\image\kernel, initrd.img, boot.img, init_boot.img,
                      vendor_boot.img, vbmeta*.img, super.img
        resources\tools\launch.ps1, provision_bundle.ps1, m0_build.py,
                      imgtools.py, integrate_play_store.ps1
        resources\python\python.exe (+ stdlib DLLs, Lib, _pth)
        resources\scrcpy\scrcpy.exe (+ scrcpy-server, DLLs)
        resources\platform-tools\adb.exe (+ AdbWinApi.dll, AdbWinUsbApi.dll)

    The 16 GB disk.raw is NOT bundled; provision_bundle.ps1 rebuilds it on
    first run into %LOCALAPPDATA%\QArmDroid from the bundled ~1.5 GB super.img.

.PARAMETER NoQemu
    Skip copying the QEMU binary (already staged); only refresh image/tools.

.PARAMETER AutoDownload
    Automatically download missing external dependencies (AOSP image, Python
    embeddable, Scrcpy, Platform-tools) if not present locally.

.PARAMETER BuildId
    AOSP Cuttlefish build ID for image download (defaults to 15357239).

.PARAMETER Force
    Overwrite staged files even if they already exist in src-tauri\resources.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\stage_bundle.ps1 -AutoDownload
#>
[CmdletBinding()]
param(
    [switch]$NoQemu,
    [switch]$AutoDownload,
    [string]$BuildId = "15357239",
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$ResDir   = Join-Path $RepoRoot "src-tauri\resources"
$ImgDir   = Join-Path $RepoRoot "aosp_cf_arm64_only_phone-img"
$M0Dir    = Join-Path $ImgDir "work\m0"
$QemuBuild= Join-Path $RepoRoot "tools\qemu-gfxstream\qemu\build"

foreach ($d in @("$ResDir\qemu", "$ResDir\image", "$ResDir\tools", "$ResDir\scrcpy", "$ResDir\platform-tools", "$ResDir\python")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

function Download-FileWithRetry {
    param(
        [string]$Url,
        [string]$OutFile,
        [int64]$MinBytes = 1000
    )
    if (Test-Path $OutFile) {
        $len = (Get-Item $OutFile).Length
        if ($len -ge $MinBytes) {
            Write-Host "  Using existing download: $OutFile ($([math]::Round($len / 1MB, 2)) MB)" -ForegroundColor DarkGray
            return $true
        }
    }
    Write-Host "  Downloading: $Url -> $OutFile" -ForegroundColor Yellow
    $parent = Split-Path $OutFile -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail --show-error --retry 3 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $MinBytes)) {
            return $true
        }
    }
    
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $wc.DownloadFile($Url, $OutFile)
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $MinBytes)) {
            return $true
        }
    } catch {
        Write-Warning "Download via WebClient failed: $_"
    }
    
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $MinBytes)) {
            return $true
        }
    } catch {
        Write-Warning "Download via Invoke-WebRequest failed: $_"
    }

    return $false
}

# ---------------------------------------------------------------- scrcpy ---- #
Write-Host "== staging Scrcpy ==" -ForegroundColor Cyan
$scrcpySrc = Join-Path $RepoRoot "tools\scrcpy"
if ((-not (Test-Path (Join-Path $scrcpySrc "scrcpy.exe"))) -and $AutoDownload) {
    Write-Host "  Scrcpy not found; auto-downloading v3.3.4..." -ForegroundColor Yellow
    $scrcpyZip = Join-Path $RepoRoot "tools\scrcpy-win64-v3.3.4.zip"
    $url = "https://github.com/Genymobile/scrcpy/releases/download/v3.3.4/scrcpy-win64-v3.3.4.zip"
    if (Download-FileWithRetry $url $scrcpyZip 5000000) {
        $tmpExtract = Join-Path $RepoRoot "tools\_scrcpy_extract"
        if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract }
        Expand-Archive -Path $scrcpyZip -DestinationPath $tmpExtract -Force
        $inner = Get-ChildItem $tmpExtract -Directory | Select-Object -First 1
        New-Item -ItemType Directory -Force -Path $scrcpySrc | Out-Null
        Copy-Item (Join-Path $inner.FullName "*") $scrcpySrc -Recurse -Force
        Remove-Item -Recurse -Force $tmpExtract -ErrorAction SilentlyContinue
    }
}
if (Test-Path $scrcpySrc) {
    Copy-Item (Join-Path $scrcpySrc "*") (Join-Path $ResDir "scrcpy") -Recurse -Force
    Write-Host "  staged Scrcpy from $scrcpySrc" -ForegroundColor DarkGray
} else {
    Write-Warning "tools\scrcpy not found at $scrcpySrc"
}

# -------------------------------------------------------- platform-tools (ADB) ---- #
Write-Host "== staging ADB platform-tools ==" -ForegroundColor Cyan
$ptSrc = Join-Path $RepoRoot "tools\platform-tools"
if ((-not (Test-Path (Join-Path $ptSrc "adb.exe"))) -and $AutoDownload) {
    Write-Host "  Platform-tools not found; auto-downloading from Google repository..." -ForegroundColor Yellow
    $ptZip = Join-Path $RepoRoot "tools\platform-tools.zip"
    $url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
    if (Download-FileWithRetry $url $ptZip 5000000) {
        $tmpExtract = Join-Path $RepoRoot "tools\_pt_extract"
        if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract }
        Expand-Archive -Path $ptZip -DestinationPath $tmpExtract -Force
        $inner = Join-Path $tmpExtract "platform-tools"
        New-Item -ItemType Directory -Force -Path $ptSrc | Out-Null
        Copy-Item (Join-Path $inner "*") $ptSrc -Recurse -Force
        Remove-Item -Recurse -Force $tmpExtract -ErrorAction SilentlyContinue
    }
}

$ptDst = Join-Path $ResDir "platform-tools"
$adbCandidates = @(
    $ptSrc,
    (Join-Path $RepoRoot "tools\scrcpy"),
    (Join-Path $ResDir "scrcpy"),
    "$env:SystemDrive\platform-tools"
)
$foundAdbDir = ($adbCandidates | Where-Object { $_ -and (Test-Path (Join-Path $_ "adb.exe")) } | Select-Object -First 1)
if (-not $foundAdbDir -and (Get-Command adb.exe -ErrorAction SilentlyContinue)) {
    $foundAdbDir = Split-Path (Get-Command adb.exe).Source -Parent
}

if ($foundAdbDir) {
    foreach ($f in @("adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll")) {
        $srcFile = Join-Path $foundAdbDir $f
        if (Test-Path $srcFile) {
            Copy-Item $srcFile (Join-Path $ptDst $f) -Force
            Copy-Item $srcFile (Join-Path $ResDir "scrcpy\$f") -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  staged ADB from $foundAdbDir" -ForegroundColor DarkGray
} else {
    Write-Warning "ADB not found to stage into platform-tools"
}

# ---------------------------------------------------------------- python ------ #
Write-Host "== staging Python embeddable ==" -ForegroundColor Cyan
$pyZipCandidates = @(
    (Join-Path $RepoRoot "tools\python-3.12-embed-arm64.zip"),
    (Join-Path $RepoRoot "tools\python-3.12.8-embed-arm64.zip")
)
$pyZip = ($pyZipCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
if (-not $pyZip -and $AutoDownload) {
    Write-Host "  Python embeddable not found; auto-downloading 3.12.8 ARM64..." -ForegroundColor Yellow
    $pyZip = Join-Path $RepoRoot "tools\python-3.12-embed-arm64.zip"
    $url = "https://www.python.org/ftp/python/3.12.8/python-3.12.8-embed-arm64.zip"
    $ok = Download-FileWithRetry $url $pyZip 8000000
    if (-not $ok) { Write-Error "Failed to download Python embeddable" }
}

if ($pyZip -and (Test-Path $pyZip)) {
    $pyDir = Join-Path $ResDir "python"
    New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
    Expand-Archive -Force -Path $pyZip -DestinationPath $pyDir
    $pysiteSrc = Join-Path $RepoRoot "tools\qemu-gfxstream\pysite"
    if (Test-Path $pysiteSrc) { Copy-Item -Recurse -Force $pysiteSrc (Join-Path $pyDir "pysite") }
    $pth = Join-Path $pyDir "python312._pth"
    if (Test-Path $pth) {
        $c = Get-Content $pth -Raw
        if ($c -notmatch "Lib\\") { Add-Content $pth "Lib\" }
        if ($c -notmatch "\.") { Add-Content $pth "." }
    }
    Write-Host "  staged Python embeddable from $pyZip" -ForegroundColor DarkGray
} else {
    Write-Warning "Python embeddable zip not found: $pyZip"
}

# ---------------------------------------------------------------- image ----- #
Write-Host "== staging image inputs ==" -ForegroundColor Cyan
$kernel = Join-Path $ImgDir "out\kernel"
$initrd = Join-Path $M0Dir "initrd.img"
$super  = Join-Path $ImgDir "super.img"

if ((-not (Test-Path $kernel)) -or (-not (Test-Path $initrd)) -or (-not (Test-Path $super))) {
    if ($AutoDownload) {
        Write-Host "  Image inputs missing; running setup_image.ps1 -Automated..." -ForegroundColor Yellow
        & (Join-Path $RepoRoot "tools\setup_image.ps1") -Automated -BuildId $BuildId
    } else {
        Write-Host "  Image inputs missing; running setup_image.ps1..." -ForegroundColor Yellow
        & (Join-Path $RepoRoot "tools\setup_image.ps1") -BuildId $BuildId
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "setup_image.ps1 failed with exit code $LASTEXITCODE"
        exit 1
    }
}

if (-not (Test-Path $kernel)) { Write-Error "kernel not found: $kernel" }
Copy-Item $kernel (Join-Path $ResDir "image\kernel") -Force

if (-not (Test-Path $initrd)) { Write-Error "initrd.img not found: $initrd (run python tools/m0_build.py bootconfig; initrd)" }
Copy-Item $initrd (Join-Path $ResDir "image\initrd.img") -Force

foreach ($n in @("boot.img","init_boot.img","vendor_boot.img","vbmeta.img",
                 "vbmeta_system.img","vbmeta_system_dlkm.img","vbmeta_vendor_dlkm.img","super.img")) {
    $s = Join-Path $ImgDir $n
    if (Test-Path $s) { Copy-Item $s (Join-Path $ResDir "image") -Force }
    else { Write-Host "  (missing optional: $n)" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- QEMU ------ #
if (-not $NoQemu) {
    Write-Host "== staging QEMU (custom self-built) ==" -ForegroundColor Cyan
    $msysCandidates = [System.Collections.Generic.List[string]]::new()
    if ($env:MSYS2_ROOT) { $msysCandidates.Add($env:MSYS2_ROOT) }
    if ($env:CLANGARM64_BIN) { $msysCandidates.Add((Split-Path $env:CLANGARM64_BIN -Parent)) }
    if ($env:RUNNER_TEMP) { $msysCandidates.Add((Join-Path $env:RUNNER_TEMP "msys64")) }
    if ($env:TEMP) { $msysCandidates.Add((Join-Path $env:TEMP "msys64")) }
    $msysCandidates.Add("C:\msys64")
    $msysCandidates.Add("D:\msys64")
    $msysCandidates.Add("$env:SystemDrive\msys64")

    $msysRoot = ($msysCandidates | Where-Object { $_ -and (Test-Path (Join-Path $_ "clangarm64\bin")) } | Select-Object -First 1)
    $msysBin = "C:\msys64\clangarm64\bin"
    $fwSrc   = "C:\msys64\clangarm64\share\qemu"
    if ($msysRoot) {
        $msysBin = Join-Path $msysRoot "clangarm64\bin"
        $fwSrc   = Join-Path $msysRoot "clangarm64\share\qemu"
    }

    $qemuExe = Join-Path $QemuBuild "qemu-system-aarch64.exe"

    if (-not (Test-Path $qemuExe) -and $AutoDownload) {
        Write-Host "  Custom QEMU not found at $qemuExe; attempting to build via build_custom_qemu.ps1..." -ForegroundColor Yellow
        $buildScript = Join-Path $RepoRoot "tools\build_custom_qemu.ps1"
        if (Test-Path $buildScript) {
            & $buildScript
        }
    }

    if (-not (Test-Path $qemuExe)) {
        # Check LocalAppData runtime copy if present from earlier install
        $localAppQemu = Join-Path $env:LOCALAPPDATA "QArmDroid\qemu\qemu-system-aarch64.exe"
        if (Test-Path $localAppQemu) {
            Write-Host "  Found custom QEMU in LocalAppData runtime: $localAppQemu" -ForegroundColor Green
            $qemuExe = $localAppQemu
        }
    }

    if (-not (Test-Path $qemuExe)) {
        Write-Error "Custom self-built QEMU not found at $qemuExe! Stock MSYS2 QEMU cannot be used as it lacks the required custom patches (touchscreen HID digitizer, rutabaga ExternalBlob renderer-features, SDL letterbox, and VNC websocket support). Run tools\build_custom_qemu.ps1 to build it."
        exit 1
    }

    Write-Host "  staged custom QEMU: $qemuExe" -ForegroundColor Green
    $qemuDst = Join-Path $ResDir "qemu"
    Copy-Item $qemuExe (Join-Path $qemuDst "qemu-system-aarch64.exe") -Force

    $qemuImg = Join-Path (Split-Path $qemuExe -Parent) "qemu-img.exe"
    if (Test-Path $qemuImg) {
        Copy-Item $qemuImg (Join-Path $qemuDst "qemu-img.exe") -Force
    }

    # Copy all custom build DLLs from the build directory
    if (Test-Path $QemuBuild) {
        Get-ChildItem $QemuBuild -Filter "*.dll" | Copy-Item -Destination $qemuDst -Force
    }

    # Pixman, zstd, SDL2, libslirp, glib runtime DLLs from MSYS2
    foreach ($dll in @("libpixman-1-0.dll","libzstd-1.dll","SDL2.dll","libslirp-0.dll","zlib1.dll","libfdt-1.dll","libglib-2.0-0.dll","libwinpthread-1.dll","libintl-8.dll","libiconv-2.dll","libpcre2-8-0.dll")) {
        $s = Join-Path $msysBin $dll
        if (Test-Path $s) { Copy-Item $s $qemuDst -Force }
    }

    # QEMU data dir (share\qemu: ROMs + keymaps + dtb + firmware)
    $fwDst = Join-Path $ResDir "qemu\share\qemu"
    New-Item -ItemType Directory -Force -Path $fwDst | Out-Null
    if (Test-Path $fwSrc) {
        # Copy everything EXCEPT edk2 UEFI images to prevent exceeding installer size limits
        Copy-Item (Join-Path $fwSrc "*") $fwDst -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $fwDst -Recurse -Filter "edk2*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Host "  staged QEMU share/qemu data dir" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------- tools ------ #
Write-Host "== staging tools scripts ==" -ForegroundColor Cyan
foreach ($n in @("launch.ps1","provision_bundle.ps1","m0_build.py","imgtools.py","integrate_play_store.ps1")) {
    $s = Join-Path (Join-Path $RepoRoot "tools") $n
    if (Test-Path $s) { Copy-Item $s (Join-Path $ResDir "tools") -Force }
}

# -------------------------------------------------------------- summary ---- #
Write-Host ""
Write-Host "== bundle verification ==" -ForegroundColor Cyan
$critical = @(
    "qemu\qemu-system-aarch64.exe",
    "image\kernel",
    "image\initrd.img",
    "image\super.img",
    "python\python.exe",
    "scrcpy\scrcpy.exe",
    "platform-tools\adb.exe",
    "tools\provision_bundle.ps1",
    "tools\launch.ps1"
)
$allOk = $true
foreach ($item in $critical) {
    $fullPath = Join-Path $ResDir $item
    $exists = Test-Path $fullPath
    if (-not $exists) {
        Write-Host "  MISSING: $item" -ForegroundColor Red
        $allOk = $false
    } else {
        $sizeMb = (Get-Item $fullPath).Length / 1MB
        Write-Host ("  OK: {0,-35} ({1,7:N1} MB)" -f $item, $sizeMb) -ForegroundColor Green
    }
}

if (-not $allOk) {
    Write-Error "Bundle staging incomplete - missing critical components above!"
    exit 1
}

Write-Host ""
Write-Host "== resources staged summary ==" -ForegroundColor Green
$total = 0
Get-ChildItem $ResDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Replace("$ResDir\", "")
    $mb = $_.Length / 1MB
    $total += $_.Length
}
Write-Host ("  Total bundle size: {0:N1} MB" -f ($total/1MB)) -ForegroundColor Cyan
Write-Host ""
Write-Host "Ready! Next: npx tauri build" -ForegroundColor Green