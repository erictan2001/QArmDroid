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
         super.img + boot images (via m0_build.py's pure-Python disk stage -
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
    [switch]$SkipDisk,
    [switch]$RebuildDisk,
    [int]$DiskSizeGB = 8,
    [string]$FsFormat = "ext4"
)

# Validate + normalize the user-selected image configuration so the disk
# builder (m0_build.py) and the UI stay in agreement.
if ($DiskSizeGB -lt 4) { $DiskSizeGB = 4 }
if ($DiskSizeGB -gt 256) { $DiskSizeGB = 256 }
$FsFormat = $FsFormat.Trim().ToLower()
if ($FsFormat -ne "f2fs") { $FsFormat = "ext4" }

# Structured progress line consumed by the Rust host (QArmDroid) and rendered
# as a real progress bar in the UI. Format: PROGRESS <percent> <stage>
function Emit-Progress {
    param([int]$Percent, [string]$Stage)
    Write-Host ("PROGRESS {0} {1}" -f $Percent, $Stage)
}

if (-not $InstallRoot) { 
    # Try to find the install root from the script location
    $scriptDir = Split-Path $PSScriptRoot -Parent
    if ((Split-Path $scriptDir -Leaf) -eq "tools") {
        $InstallRoot = Split-Path $scriptDir -Parent
    } else {
        $InstallRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    }
}
if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $env:LOCALAPPDATA "QArmDroid"
}

# Source dirs: the immutable installer inputs (QEMU, image, tools) live under
# the install resources dir. In a bundled install this is the Program Files
# "resources" directory shipped by the installer; InstallRoot is passed in by
# the Rust host. If InstallRoot was not supplied, fall back to the same
# directory that holds this script's parent "tools" (i.e. assume the inputs
# sit alongside the runtime tools - covers dev-repo layouts).
if (-not $InstallRoot) {
    $scriptDir = Split-Path $PSScriptRoot -Parent
    if ((Split-Path $scriptDir -Leaf) -eq "tools") {
        $InstallRoot = Split-Path $scriptDir -Parent
    } else {
        $InstallRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    }
}

$qemuSrc  = Join-Path $InstallRoot "qemu"
$imgSrc   = Join-Path $InstallRoot "image"
$toolsSrc = Join-Path $InstallRoot "tools"

# ---------------------------------------------------------------- python ------ #
    Emit-Progress 5 "Syncing Python runtime"
    Write-Host "== syncing Python ==" -ForegroundColor Cyan
    $pythonSrc = Join-Path $InstallRoot "python"
    $pythonDst = Join-Path $RuntimeRoot "python"
    if (-not (Test-Path $pythonDst)) {
        if (-not (Test-Path $pythonSrc)) {
            Emit-Progress 0 ("ERROR: Python runtime not found in installer resources ($pythonSrc). Reinstall the app.")
            Write-Error "Python runtime missing at $pythonSrc - cannot build disk.raw"
            exit 1
        }
        Copy-Item $pythonSrc -Recurse -Destination $pythonDst -Force
    }

    Emit-Progress 12 "Copying QEMU binary"
    Write-Host "== syncing QEMU runtime ==" -ForegroundColor Cyan
$qemuDst   = Join-Path $RuntimeRoot "qemu"
$imgDst    = Join-Path $RuntimeRoot "image"
$toolsDst  = Join-Path $RuntimeRoot "tools"
$scrcpyDst = Join-Path $RuntimeRoot "scrcpy"
$ptDst     = Join-Path $RuntimeRoot "platform-tools"

foreach ($d in @($qemuDst, $imgDst, $toolsDst, $scrcpyDst, $ptDst)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$imageInputs = @("kernel","initrd.img","boot.img","init_boot.img","vendor_boot.img",
                 "vbmeta.img","vbmeta_system.img","vbmeta_system_dlkm.img",
                 "vbmeta_vendor_dlkm.img","super.img")

$qemuSrcExe = Join-Path $qemuSrc "qemu-system-aarch64.exe"
$qemuDstExe = Join-Path $qemuDst "qemu-system-aarch64.exe"
$needSync = $Force -or -not (Test-Path $qemuDstExe) -or ((Test-Path $qemuSrcExe) -and ((Get-Item $qemuSrcExe).LastWriteTime -gt (Get-Item $qemuDstExe).LastWriteTime))

if ($needSync) {
    Emit-Progress 18 "Copying QEMU binary"
    Write-Host "== syncing QEMU runtime ==" -ForegroundColor Cyan
    Copy-Item (Join-Path $qemuSrc "qemu-system-aarch64.exe") $qemuDst -Force
    Get-ChildItem $qemuSrc -Filter "*.dll" -ErrorAction SilentlyContinue |
        Copy-Item -Destination $qemuDst -Force
    # QEMU data dir (share\qemu, incl. keymaps + ROMs) - ship into the runtime
    # so end-user machines without msys2 can launch (-L points here).
    if (Test-Path (Join-Path $qemuSrc "share\qemu")) {
        $fwDst = Join-Path $qemuDst "share\qemu"
        New-Item -ItemType Directory -Force -Path $fwDst | Out-Null
        Copy-Item (Join-Path $qemuSrc "share\qemu\*") $fwDst -Recurse -Force
    }

    Emit-Progress 30 "Copying Scrcpy mirror & ADB tools"
    Write-Host "== syncing Scrcpy & ADB ==" -ForegroundColor Cyan
    $scrcpySrc = Join-Path $InstallRoot "scrcpy"
    if (-not (Test-Path $scrcpySrc)) {
        $scrcpySrc = Join-Path $InstallRoot "tools\scrcpy"
    }
    if (-not (Test-Path $scrcpySrc)) {
        $scrcpySrc = Join-Path $PSScriptRoot "scrcpy"
    }
    if (Test-Path $scrcpySrc) {
        Copy-Item (Join-Path $scrcpySrc "*") $scrcpyDst -Recurse -Force
        # Also ensure adb and scrcpy are accessible under tools\scrcpy for backward compat
        $toolsScrcpy = Join-Path $toolsDst "scrcpy"
        New-Item -ItemType Directory -Force -Path $toolsScrcpy | Out-Null
        Copy-Item (Join-Path $scrcpySrc "*") $toolsScrcpy -Recurse -Force
    }

    # Platform-tools (ADB standalone)
    $ptSrc = Join-Path $InstallRoot "platform-tools"
    if (-not (Test-Path $ptSrc)) {
        $ptSrc = Join-Path $InstallRoot "tools\platform-tools"
    }
    if (-not (Test-Path $ptSrc)) {
        $ptSrc = Join-Path $PSScriptRoot "platform-tools"
    }
    if (Test-Path $ptSrc) {
        Copy-Item (Join-Path $ptSrc "*") $ptDst -Recurse -Force
        $toolsPt = Join-Path $toolsDst "platform-tools"
        New-Item -ItemType Directory -Force -Path $toolsPt | Out-Null
        Copy-Item (Join-Path $ptSrc "*") $toolsPt -Recurse -Force
    } elseif (Test-Path (Join-Path $scrcpyDst "adb.exe")) {
        # Fallback: extract adb binaries from scrcpy into platform-tools
        foreach ($f in @("adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll")) {
            $sf = Join-Path $scrcpyDst $f
            if (Test-Path $sf) {
                Copy-Item $sf (Join-Path $ptDst $f) -Force
            }
        }
    }

    Emit-Progress 40 "Copying Android image inputs"
    Write-Host "== syncing image inputs ==" -ForegroundColor Cyan
    foreach ($n in $imageInputs) {
        $s = Join-Path $imgSrc $n
        if (Test-Path $s) { Copy-Item $s (Join-Path $imgDst $n) -Force }
    }

    Emit-Progress 50 "Copying build tools"
    Write-Host "== syncing tools ==" -ForegroundColor Cyan
    # Copy the full tools dir (imgtools.py, m0_build.py, launch.ps1 and THIS
    # script) so the runtime is self-contained and the Rust host can re-invoke
    # provision_bundle.ps1 / launch.ps1 from %LOCALAPPDATA%\QArmDroid\tools.
    if (Test-Path $toolsSrc) {
        Copy-Item (Join-Path $toolsSrc "*") $toolsDst -Recurse -Force
    }

    # --------------------------------------------------------------- disk.raw --- #
} else {
    Write-Host "runtime already provisioned (use -Force to re-sync)" -ForegroundColor DarkGray
}

# Synchronize tools from source only if destination file is missing or source is strictly newer
if (Test-Path $toolsSrc) {
    Get-ChildItem -Path $toolsSrc -Include *.ps1, *.py | ForEach-Object {
        $dst = Join-Path $toolsDst $_.Name
        if (-not (Test-Path $dst) -or ($_.LastWriteTime -gt (Get-Item $dst).LastWriteTime)) {
            Copy-Item $_.FullName $dst -Force -ErrorAction SilentlyContinue
        }
    }
}

# --------------------------------------------------------------- disk.raw & userdata.raw --- #
$disk = Join-Path $imgDst "disk.raw"
$userdataDisk = Join-Path $imgDst "userdata.raw"
$superImg = Join-Path $imgDst "super.img"

$needOsDiskBuild = $false
$needUserdataBuild = $false

if ($SkipDisk) {
    # do nothing
} elseif ($Force) {
    $needOsDiskBuild = $true
    $needUserdataBuild = $true
    Write-Host "Force rebuild requested -> rebuilding both OS disk and userdata" -ForegroundColor Cyan
} elseif ($RebuildDisk) {
    # User requested rebuild of userdata disk
    $needUserdataBuild = $true
    # Also check if OS disk needs upgrade/rebuild (if missing or old > 10GB composite)
    if (-not (Test-Path $disk) -or ((Get-Item $disk).Length -gt 10GB) -or ((Get-Item $disk).Length -lt 8GB)) {
        $needOsDiskBuild = $true
    }
} else {
    # Check OS disk (expected ~8.9 GB)
    if (-not (Test-Path $disk) -or ((Get-Item $disk).Length -gt 10GB) -or ((Get-Item $disk).Length -lt 8GB)) {
        Write-Host "OS disk.raw missing or requires update -> building standalone OS disk" -ForegroundColor Yellow
        $needOsDiskBuild = $true
    }
    # Check userdata disk
    if (-not (Test-Path $userdataDisk)) {
        $needUserdataBuild = $true
    } else {
        $uLen = (Get-Item $userdataDisk).Length
        $partBytes = [Math]::Max([int64]1000000000, [int64]$DiskSizeGB * 1000000000 - 800000000)
        $expectedU = 2048 * 512 + $partBytes + 2048 * 512
        if ([Math]::Abs($uLen - $expectedU) -gt 200MB) {
            Write-Host "userdata.raw length ($([Math]::Round($uLen/1GB, 2)) GB) differs from target ($DiskSizeGB GB) -> rebuilding" -ForegroundColor Yellow
            $needUserdataBuild = $true
        }
    }
    # Also check userdata.fstype
    $fsTypeFile = Join-Path $imgDst "userdata.fstype"
    if (Test-Path $fsTypeFile) {
        $curFs = (Get-Content $fsTypeFile -Raw).Trim().ToLower()
        if ($curFs -and $curFs -ne $FsFormat) {
            Write-Host "userdata.raw fstype ($curFs) differs from target ($FsFormat) -> rebuilding" -ForegroundColor Yellow
            $needUserdataBuild = $true
        }
    }
}

if (-not $needOsDiskBuild -and -not $needUserdataBuild) {
    Write-Host "Disks present with matching config ($DiskSizeGB GB, $FsFormat): $disk and $userdataDisk" -ForegroundColor Green
    Emit-Progress 100 "Image already provisioned"
} else {
    Push-Location $toolsDst
    try {
        $py = Join-Path $toolsDst "..\python\python.exe"
        $env:QARM_DISK_GB = "$DiskSizeGB"
        $env:QARM_FS = "$FsFormat"

        if ($needOsDiskBuild) {
            if (-not (Test-Path $superImg) -and (Test-Path (Join-Path $imgSrc "super.img"))) {
                Copy-Item (Join-Path $imgSrc "super.img") $superImg -Force
            }
            if (-not (Test-Path $superImg)) {
                Emit-Progress 0 "ERROR: super.img missing"
                Write-Error "super.img missing in $imgDst (and $imgSrc) - cannot build disk.raw"
                exit 1
            }
            Emit-Progress 60 "Building OS disk (super + boot partitions)"
            Write-Host "== building OS disk.raw ==" -ForegroundColor Cyan
            $cmd = @("$toolsDst\m0_build.py", "disk", "QARM_BUNDLE=$RuntimeRoot")
            & $py $cmd
            if ($LASTEXITCODE -ne 0) {
                Emit-Progress 0 ("ERROR: m0_build disk failed (exit $LASTEXITCODE)")
                Write-Error "m0_build disk stage failed (exit $LASTEXITCODE)"
                exit 1
            }
        }

        if ($needUserdataBuild) {
            Emit-Progress 90 ("Building dedicated userdata.raw ($DiskSizeGB GB, $FsFormat)")
            Write-Host "== building dedicated userdata.raw ($DiskSizeGB GB, $FsFormat) ==" -ForegroundColor Cyan
            $cmd = @("$toolsDst\m0_build.py", "userdata", "QARM_BUNDLE=$RuntimeRoot")
            & $py $cmd
            if ($LASTEXITCODE -ne 0) {
                Emit-Progress 0 ("ERROR: m0_build userdata failed (exit $LASTEXITCODE)")
                Write-Error "m0_build userdata stage failed (exit $LASTEXITCODE)"
                exit 1
            }
        }
    }
    finally { Pop-Location }

    $diskOk = (Test-Path $disk) -and ((Get-Item $disk).Length -gt 0)
    $userdataOk = (Test-Path $userdataDisk) -and ((Get-Item $userdataDisk).Length -gt 0)

    if ($diskOk -and $userdataOk) {
        Emit-Progress 100 ("Disks ready: OS disk $([Math]::Round((Get-Item $disk).Length/1GB, 2)) GB, Userdata $([Math]::Round((Get-Item $userdataDisk).Length/1GB, 2)) GB")
        Write-Host "Disks built successfully" -ForegroundColor Green
    } else {
        Emit-Progress 0 "ERROR: virtual disk not produced or empty"
        Write-Error "Virtual disk not produced or empty"
        exit 1
    }
}

# Persist the selected image configuration so the UI can reflect it.
# Only mark the image provisioned when disk.raw was actually produced.
$cfgPath = Join-Path $RuntimeRoot "image_config.json"
$cfg = @{}
if (Test-Path $cfgPath) {
    try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json -AsHashtable } catch { $cfg = @{} }
}
$cfg["userdata_size_gb"] = $DiskSizeGB
$cfg["userdata_fs"] = $FsFormat
$cfg["provisioned"] = (Test-Path $disk)
$cfg | ConvertTo-Json -Compress | Set-Content -Path $cfgPath -Force

Write-Host "== done ==" -ForegroundColor Green
Write-Host "runtime: $RuntimeRoot" -ForegroundColor DarkGray
Write-Host ("launch: powershell -File {0}\tools\launch.ps1 -BundleRoot {0} -DisplayMode embedded -GpuMode basic" -f $RuntimeRoot) -ForegroundColor DarkGray



