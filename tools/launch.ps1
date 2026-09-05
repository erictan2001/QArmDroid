<#
.SYNOPSIS
    Launches the Android 16 ARM64 Cuttlefish emulator on Windows 11 ARM64 (Snapdragon X Elite).

.DESCRIPTION
    Single owner of the QEMU invocation (Build-QemuArgs). All other former
    launch scripts (run_vm.bat, launch-detached.bat, boot-gfxstream-vm.ps1,
    launch.sh, launch_hcs_vulkan.ps1) were divergent copies of this command
    line and have been deleted; this file is canonical.

.PARAMETER DisplayMode
    none | scrcpy | headless  -> headless (GUI default; pairs with scrcpy)
    embedded | vnc            -> VNC on 127.0.0.1:5901 (websocket enabled)
    gtk | sdl                 -> native window
    Default: scrcpy (=none).

.PARAMETER GpuMode
    basic     -> plain virtio-gpu-pci (default; works on any QEMU incl. msys2
                 stock and the repo-local custom build).
    gfxstream -> virtio-gpu-rutabaga-pci,gfxstream-vulkan=on (needs the
                 repo-local custom QEMU and a host Vulkan driver with
                 VK_KHR_external_memory_win32 to fully accelerate - falls
                 back to SwiftShader in-guest until Qualcomm ships it).

.PARAMETER Memory / Cores
    Guest RAM (default 6G) and vCPU count (default 6).

.PARAMETER QemuPath
    Defaults to the repo-local custom build. For 'basic' GPU mode you may
    point at C:\msys64\clangarm64\bin\qemu-system-aarch64.exe instead.

.PARAMETER PrintArgs
    Print the resolved QEMU argv (one argument per line) and exit without
    starting the VM. Use for diffing configuration changes safely.
#>

[CmdletBinding()]
param(
    [string]$DisplayMode = "scrcpy",
    [string]$GpuMode = "basic",
    [string]$Memory = "6G",
    [int]$Cores = 6,
    [string]$QemuPath = "",
    [switch]$Headless,
    [switch]$PrintArgs,
    [int]$MonitorPort = 0,
    [string]$GrallockOverride = '',
    [switch]$SdlGl,
    # Bundled (installed) deployment root. When set, the QEMU binary, its
    # runtime DLLs, the kernel/initrd/disk, and adb are resolved under
    # <BundleRoot>\qemu\... / <BundleRoot>\image\... / <BundleRoot>\tools\
    # instead of the source-repo layout. The Tauri installer passes its
    # resource dir here.
    [string]$BundleRoot = ""
)

# ------------------------------------------------------------------ PATH ----
# The custom QEMU links against MSYS2 runtime DLLs (glib-2.0-0.dll, pixman,
# pcre2, zstd, ...). In the source repo they live in C:\msys64\clangarm64\bin;
# in the bundled installer they sit beside the QEMU exe. Bootstrap PATH here
# so launch works from ANY environment.
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$GfxDir   = Join-Path $RepoRoot "tools\qemu-gfxstream"

if ($BundleRoot) {
    # Installed (bundled) layout:
    #   <bundle>\qemu\qemu-system-aarch64.exe + runtime DLLs beside it
    #   <bundle>\image\kernel, initrd.img, disk.raw
    #   <bundle>\tools\ (metric/docs; launch.ps1 itself lives here too)
    $QemuDir = Join-Path $BundleRoot "qemu"
    if (-not $QemuPath) {
        $repoQemu = Join-Path $GfxDir "qemu\build\qemu-system-aarch64.exe"
        $bundleQemu = Join-Path $QemuDir "qemu-system-aarch64.exe"
        if ((Test-Path $repoQemu) -and ((-not (Test-Path $bundleQemu)) -or ((Get-Item $repoQemu).LastWriteTime -gt (Get-Item $bundleQemu).LastWriteTime))) {
            $QemuPath = $repoQemu
        } else {
            $QemuPath = $bundleQemu
        }
    }
    $pathAdditions = @($QemuDir, "C:\msys64\clangarm64\bin")
}
else {
    if (-not $QemuPath) { $QemuPath = Join-Path $GfxDir "qemu\build\qemu-system-aarch64.exe" }
    $pathAdditions = @("C:\msys64\clangarm64\bin")
}

if ($GpuMode -eq "gfxstream" -and -not $BundleRoot) {
    $pathAdditions += @(
        (Join-Path $GfxDir "gfxstream\build-host"),
        (Join-Path $GfxDir "gfxstream\build-host\host")
    )
}
foreach ($p in $pathAdditions) {
    if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) { $env:PATH = "$p;$env:PATH" }
}

# --- GPU selection for gfxstream (CRITICAL) ---
# ANDROID_EMU_VK_SELECT_GPU="1" selects GPU1 = Mesa Dozen (D3D12→Vulkan)
# which has VK_KHR_external_memory_win32. GPU0 = native Adreno LACKS it.
# MUST use integer index, NOT name substring ("Direct3D12" matches WARP too!)
$env:ANDROID_EMU_VK_SELECT_GPU = "1"

# Native Qualcomm Vulkan driver — DO NOT SET VK_DRIVER_FILES to only this ICD!
# Setting it restricts Vulkan loader to ONLY native Adreno, hiding Mesa Dozen
# (D3D12) device which HAS VK_KHR_external_memory_win32 needed for gfxstream.
# Let the loader enumerate ALL ICDs so our scoring can pick Dozen.
# $NewIcd = 'C:\Windows\System32\DriverStore\FileRepository\qcdx8380.inf_arm64_97b66cecb1490986\qcvk_icd_arm64x.json'
# if (Test-Path $NewIcd) { $env:VK_DRIVER_FILES = $NewIcd }

# ------------------------------------------------- binary/display resolver --
# The repo-local custom QEMU in tools\qemu-gfxstream\qemu\build supports
# headless (none), VNC (embedded), and SDL (native window).
function Get-QemuDisplayCaps {
    param([string]$Exe)
    $help = (& $Exe -display help 2>&1 | Out-String)
    $types = @()
    foreach ($line in ($help -split "`n")) {
        if ($line -match '^\s*([a-z][a-z0-9-]+)\s*$') { $types += $Matches[1] }
    }
    if ($types.Count -eq 0) { $types = @("none") }
    if ((-not $types.Contains("vnc"))) {
        $vncHelp = (& $Exe -vnc help 2>&1 | Out-String)
        if ($vncHelp -match "vnc|display") { $types += "vnc" }
    }
    return $types
}

$caps     = Get-QemuDisplayCaps -Exe $QemuPath
$reqType  = switch -Regex ($DisplayMode) {
                '^(embedded|vnc)$'      { "vnc"; break }
                '^(scrcpy|none|headless)$' { "none"; break }
                '^gtk$'                 { "gtk"; break }
                '^sdl$'                 { "sdl"; break }
                default                 { $DisplayMode }
            }

if ($reqType -ne "none" -and $caps -notcontains $reqType) {
    if ($reqType -eq "vnc") {
        Write-Host "[launch] WARNING: QEMU does not support vnc; degrading DisplayMode to none." -ForegroundColor Yellow
        $DisplayMode = "none"
    }
    else {
        Write-Error "Requested display '$reqType' unsupported by custom QEMU at $QemuPath."
    }
}

# ------------------------------------------------------------- display ----- #
$ErrorActionPreference = "Continue"   # never Stop: PS5.1 + native stderr = instant death
if ($Headless) { $DisplayMode = "none" }

if ($BundleRoot) {
    $ImgDir     = Join-Path $BundleRoot "image"
    $M0Dir      = $ImgDir        # bundled: kernel/initrd/disk live flat under image\
} else {
    $ImgDir    = Join-Path $RepoRoot "aosp_cf_arm64_only_phone-img"
    $M0Dir     = Join-Path $ImgDir "work\m0"
}
$KernelPath = Join-Path $ImgDir "out\kernel"
if ($BundleRoot) { $KernelPath = Join-Path $ImgDir "kernel" }
# initrd selection by GPU mode:
#  - basic / SwiftShader: use the ORIGINAL initrd.img (pastel/angle config)
#  - gfxstream (ranchu):  use initrd_gpu.img (vulkan=ranchu passthrough config)
$InitrdPath = Join-Path $M0Dir "initrd.img"
if (-not (Test-Path $InitrdPath)) { Write-Error "Initrd not found: $InitrdPath (run: python tools/m0_build.py initrd)" }
if ($GpuMode -eq "gfxstream") {
    $InitrdGpu = Join-Path $M0Dir "initrd_gpu.img"
    if (Test-Path $InitrdGpu) { $InitrdPath = $InitrdGpu }
}
$DiskPath   = Join-Path $M0Dir "disk.raw"
$SerialLog  = Join-Path $M0Dir "serial.log"

# ------------------------------------------------------------ preflight ---- #
if    (-not (Test-Path $QemuPath))  { Write-Error "QEMU not found: $QemuPath" }
if    (-not (Test-Path $KernelPath)) { Write-Error "Kernel image not found: $KernelPath" }
if    (-not (Test-Path $InitrdPath)) { Write-Error "Initrd not found: $InitrdPath (run: python tools/m0_build.py initrd)" }
if    (-not (Test-Path $DiskPath))   { Write-Error "Disk not found: $DiskPath (run: python tools/m0_build.py disk)" }

# ------------------------------------------------------- Build-QemuArgs ---- #
# THE single source of the QEMU command line. Returns string[] argv.
function Build-QemuArgs {
    [CmdletBinding()]
    param(
        [string]$DisplayMode, [string]$GpuMode, [string]$Memory,
        [int]$Cores, [string]$Kernel, [string]$Initrd, [string]$Disk,
        [string]$SerialLog
    )

    # Kernel cmdline (canonical - matches init_wrapper expectations:
    # 4 UARTs, quiet console, binder rust impl, firmware from vendor/etc)
    # video=virtio-fb:1280x800@60 tells guest kernel framebuffer matches virtio-gpu device
    # androidboot.lcd_density=240 sets display density before SurfaceFlinger starts (hdpi for 1280x800)
    $append = "console=ttyAMA0 earlycon=pl011,0x9000000 quiet loglevel=0 " +
              "printk.devkmsg=on audit=0 panic=-1 8250.nr_uarts=4 " +
              "video=virtio-fb:1280x800@60 " +
              "androidboot.lcd_density=240 " +
              "androidboot.hardware.gltransport=virtio-gpu-pipe binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ " +
              "loop.max_part=7 init=/init bootconfig"
    # Optional gralloc override (e.g. 'default' fixes R/B-swap on plain
    # virtio-gpu scanout by using the CPU gralloc instead of minigbm).
    # Appended LAST: androidboot last-wins for duplicate keys.
    if ($GrallockOverride) {
        $append += " androidboot.hardware.gralloc=$GrallockOverride"
    }

    # Display backend + whether windowed input devices attach.
    # Input note (verified via getevent, 2026-08): virtio-keyboard/tablet are
    # broken in every frontend we tried (no QEMU handler / broken MT slots);
    # USB HID (nec-usb-xhci + usb-kbd + usb-mouse) is the only working pair.
    switch -Regex ($DisplayMode) {
        '^(embedded|vnc)$' {
            $display = @("-display", "vnc=127.0.0.1:0,websocket=5901,lossy=off,non-adaptive=on"); $windowed = $true }
        '^gtk$'   { $display = @("-display", "gtk"); $windowed = $true }
        '^sdl$'   { $d = if ($SdlGl) { "sdl,gl=on" } else { "sdl" }; $display = @("-display", $d); $windowed = $true }
        '^(scrcpy|none|headless)$' {
            $display = @("-display", "none"); $windowed = $false }
        default   { $display = @("-display", $DisplayMode); $windowed = $true }
    }

    # GPU device
    switch ($GpuMode) {
        'basic' {
            $gpu = @("-device", "virtio-gpu-pci,xres=1280,yres=800") }
        default {   # gfxstream (hostmem required for blob mapping!)
            $gpu = @("-device", "virtio-gpu-rutabaga-pci,addr=03.0,gfxstream-vulkan=on,hostmem=8G,xres=1280,yres=800,renderer-features=ExternalBlob:enabled") }
    }

    $inputDev = @()
    if ($windowed) {
        # USB HID (nec-usb-xhci + usb-kbd + usb-tablet): the tablet is an
        # ABSOLUTE device. Window->guest conversion in QEMU (ui/sdl2.c) now
        # mirrors SDL's RenderSetLogicalSize letterbox exactly, so a click/
        # drag lands precisely where the cursor is regardless of window size.
        # (A relative usb-mouse floats a cursor by accumulated deltas - taps
        # land wherever the cursor drifted, i.e. "wrong coordinates" after
        # any resize. Only the absolute tablet gives true position.)
        $inputDev = @("-device","nec-usb-xhci","-device","usb-kbd","-device","usb-tablet")
    }

    # Audio: virtio-sound (guest kernel has virtio_snd driver)
    $audioDev = @("-device", "virtio-sound-pci")

    # virtio consoles hvc0..15 - init_wrapper.c mknods /dev/hvc0..15 and
    # PROJECT_REPORT.md documents HAL crash-loops when these are absent.
    $hvc = @()
    for ($n = 0; $n -lt 16; $n++) {
        $hvc += @("-chardev", "null,id=hvc$n", "-device", "virtconsole,chardev=hvc$n")
    }

    # Assemble: machine/base -> storage -> net -> gpu -> consoles -> input ->
    # display -> serial/monitor -> cmdline. Order groups mirror historical
    # working invocations (see docs/history/BUILD_LOG.md).
    # Firmware/ROM data dir. The bundled (custom) QEMU defaults to its
    # compile-time datadir (C:\msys64\clangarm64\share\qemu), which end-user
    # machines lack -> "failed to find romfile efi-virtio.rom" at launch.
    # Point -L at the firmware shipped next to the qemu binary, or fall back
    # to the msys2 share when running from the dev repo.
    $fwDir = Join-Path (Split-Path $QemuPath -Parent) "share\qemu"
    if (-not (Test-Path (Join-Path $fwDir "efi-virtio.rom"))) {
        $fwDir = "C:\msys64\clangarm64\share\qemu"
    }
    $arr = @(
        "-accel", "whpx",
        "-cpu", "host",
        "-L", $fwDir,
        "-machine", "virt,gic-version=3,highmem=on",
        "-m", $Memory,
        "-smp", "$Cores,sockets=1,cores=$Cores,threads=1",
        "-object", "iothread,id=iothread0",
        "-kernel", $Kernel,
        "-initrd", $Initrd,
        "-drive", "file=$Disk,format=raw,if=none,id=disk,cache=writeback,aio=threads",
        "-device", "virtio-blk-pci,drive=disk,addr=01.0,iothread=iothread0,num-queues=4",
        "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:5555-10.0.2.15:5555,hostfwd=tcp:127.0.0.1:6666-10.0.2.15:6666",
        "-device", "virtio-net-pci,netdev=net0,addr=02.0"
    ) + $gpu + @(
        "-device", "virtio-serial-pci,addr=04.0,max_ports=16"
    ) + $hvc + $audioDev + $inputDev + $display + @(
        "-chardev", "file,id=char0,path=$SerialLog",
        "-serial", "chardev:char0",
        "-serial", "null",
        "-serial", "null",
        "-serial", "null",
        "-no-reboot",
        "-append", $append
    )
    if ($MonitorPort -gt 0) {
        $arr += @("-chardev", "socket,id=mon0,host=127.0.0.1,port=$MonitorPort,server=on,wait=off",
                  "-mon", "chardev=mon0,mode=readline")
    } else {
        $arr += @("-monitor", "none")
    }
    return $arr
}

$QemuArgs = Build-QemuArgs -DisplayMode $DisplayMode -GpuMode $GpuMode `
    -Memory $Memory -Cores $Cores -Kernel $KernelPath -Initrd $InitrdPath `
    -Disk $DiskPath -SerialLog $SerialLog

if ($PrintArgs) {
    Write-Output "--qemu-path--"; Write-Output $QemuPath
    Write-Output "--args--";      $QemuArgs | ForEach-Object { $_ }
    return
}

# --------------------------------------------------------- stale process --- #
Get-Process -Name "qemu-system-aarch64", "scrcpy" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
$Adb = if (Test-Path "C:\platform-tools\adb.exe") {
    "C:\platform-tools\adb.exe"
} elseif (Get-Command adb -ErrorAction SilentlyContinue) {
    (Get-Command adb).Source
} elseif (Test-Path "$PSScriptRoot\scrcpy\adb.exe") {
    "$PSScriptRoot\scrcpy\adb.exe"
} else {
    "adb"
}
try { & $Adb forward --remove-all 2>&1 | Out-Null } catch {}
Start-Sleep -Milliseconds 500
if (-not (Test-Path $M0Dir)) { New-Item -ItemType Directory -Path $M0Dir -Force | Out-Null }

# ------------------------------------------------------------- watchdog ---- #
Start-Job -ScriptBlock {
    param($AdbExe)
    do {
        Start-Sleep -Seconds 2
        & $AdbExe connect 127.0.0.1:5555 2>$null | Out-Null
        $s = & $AdbExe -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>$null
    } until ($s -match "1")
    # Set both size AND density to match 1280x800 display (hdpi ~240 for tablet)
    & $AdbExe -s 127.0.0.1:5555 shell "setprop ctl.stop seriallogging; setprop ctl.stop console; dmesg -n 1; wm size 1280x800; wm density 240; settings put global window_animation_scale 0.5; settings put global transition_animation_scale 0.5; settings put global animator_duration_scale 0.5" 2>$null
} -ArgumentList $Adb | Out-Null

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Starting Android 16 ARM64 Emulator (QEMU + WHPX)" -ForegroundColor Green
Write-Host " Display Mode : $DisplayMode    GPU Mode : $GpuMode" -ForegroundColor Yellow
Write-Host " RAM / vCPUs  : $Memory / $Cores cores" -ForegroundColor Yellow
Write-Host " ADB Target   : 127.0.0.1:5555" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

& $QemuPath $QemuArgs


