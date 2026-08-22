<#
.SYNOPSIS
    Launches the Android 16 ARM64 Cuttlefish emulator on Windows 11 ARM64 (Snapdragon X Elite).

.DESCRIPTION
    Runs QEMU with WHPX hypervisor acceleration, native virtio devices, and SDL graphical display.

.PARAMETER DisplayMode
    Display backend for QEMU. Default is 'sdl'. Set to 'none' for headless background/ADB execution.

.PARAMETER Memory
    Guest RAM allocation. Default is '6G'.

.PARAMETER Cores
    Number of virtual CPU cores. Default is 6 (the guest renders UI with
    SwiftShader in software, which scales with vCPUs; the old default of 4
    made the scrcpy UI stream CPU-bound at ~11 FPS).

.PARAMETER QemuPath
    Path to the aarch64 QEMU binary. Default is 'C:\msys64\clangarm64\bin\qemu-system-aarch64.exe'.

.PARAMETER Headless
    Switch to run in headless mode (equivalent to -DisplayMode 'none').

.EXAMPLE
    .\tools\launch.ps1
    Launches the emulator with native SDL GUI window.

.EXAMPLE
    .\tools\launch.ps1 -Headless
    Launches the emulator in headless mode for background ADB debugging.
#>

[CmdletBinding()]
param(
    [string]$DisplayMode = "scrcpy",
    [string]$Memory = "6G",
    [int]$Cores = 6,
    [string]$QemuPath = "C:\msys64\clangarm64\bin\qemu-system-aarch64.exe",
    [switch]$Headless
)

$ErrorActionPreference = "Stop"

if ($Headless) {
    $DisplayMode = "none"
}

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$ImgDir   = Join-Path $RepoRoot "aosp_cf_arm64_only_phone-img"
$M0Dir    = Join-Path $ImgDir "work\m0"

$KernelPath = Join-Path $ImgDir "out\kernel"
$InitrdPath = Join-Path $M0Dir "initrd.img"
$DiskPath   = Join-Path $M0Dir "disk.raw"
$LogcatPath = Join-Path $RepoRoot "logcat_serial.log"
$SerialLog  = Join-Path $M0Dir "serial.log"

# Pre-flight validation
if (-not (Test-Path $QemuPath)) {
    Write-Error "QEMU executable not found at: $QemuPath`nPlease ensure clangarm64 QEMU is installed."
}
if (-not (Test-Path $KernelPath)) {
    Write-Error "Kernel image not found at: $KernelPath"
}
if (-not (Test-Path $InitrdPath)) {
    Write-Error "Initrd image not found at: $InitrdPath`nRun 'python tools/m0_build.py initrd' first."
}
if (-not (Test-Path $DiskPath)) {
    Write-Error "Disk raw image not found at: $DiskPath`nRun 'python tools/m0_build.py disk' first."
}

# Clean up any stale QEMU instances or port forwards first to release file locks and prevent hostfwd port collisions
Get-Process -Name "qemu-system-aarch64", "scrcpy" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
try {
    & "C:\platform-tools\adb.exe" forward --remove-all 2>&1 | Out-Null
} catch {}
Start-Sleep -Milliseconds 500

# Ensure serial log directory exists and reset serial log
if (-not (Test-Path $M0Dir)) {
    New-Item -ItemType Directory -Path $M0Dir -Force | Out-Null
}
$AppendCmdline = "console=ttyAMA0 earlycon=pl011,0x9000000 quiet loglevel=0 printk.devkmsg=on audit=0 panic=-1 8250.nr_uarts=4 binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig"

$DisplayArgs = @()
$InputArgs = @()

# Input attach note (2026-08): virtio-keyboard-pci DID NOT register a QEMU
# input handler in the msys2 clangarm64 QEMU 11 build â€” keys died in QEMU.
# ALSO the virtio-tablet receives BROKEN multitouch slot events from the
# window frontend ("qemu: warning: Unexpected touch slot number: N >= 10")
# which QEMU drops â€” so clicks/moves from the window do nothing. Both are
# fixed by using USB HID devices (nec-usb-xhci + usb-kbd + usb-tablet):
# proper handlers, plain ABS/key events, verified end-to-end via getevent.

if ($DisplayMode -eq "embedded" -or $DisplayMode -eq "vnc") {
    $DisplayArgs = @("-display", "vnc=127.0.0.1:0,websocket=5901,lossy=off,non-adaptive=on")
    $GpuDevice   = @("-device", "virtio-gpu-rutabaga-pci,addr=03.0,gfxstream-vulkan=on,xres=1280,yres=800")
    $InputArgs   = @("-device", "nec-usb-xhci", "-device", "usb-kbd", "-device", "usb-mouse")
} elseif ($DisplayMode -eq "gtk") {
    $DisplayArgs = @("-display", "gtk")
    $GpuDevice   = @("-device", "virtio-gpu-rutabaga-pci,addr=03.0,gfxstream-vulkan=on,xres=1280,yres=800")
    $InputArgs   = @("-device", "nec-usb-xhci", "-device", "usb-kbd", "-device", "usb-mouse")
} elseif ($DisplayMode -eq "sdl") {
    $DisplayArgs = @("-display", "sdl")
    $GpuDevice   = @("-device", "virtio-gpu-rutabaga-pci,addr=03.0,gfxstream-vulkan=on,xres=1280,yres=800")
    $InputArgs   = @("-device", "nec-usb-xhci", "-device", "usb-kbd", "-device", "usb-mouse")
} elseif ($DisplayMode -eq "scrcpy" -or $DisplayMode -eq "none" -or $DisplayMode -eq "headless") {
    $DisplayArgs = @("-display", "none")
    $GpuDevice   = @("-device", "virtio-gpu-rutabaga-pci,addr=03.0,gfxstream-vulkan=on,xres=1280,yres=800")
    $InputArgs   = @()
} else {
    $DisplayArgs = @("-display", $DisplayMode)
    $GpuDevice   = @("-device", "virtio-gpu-rutabaga-pci,addr=03.0,gfxstream-vulkan=on,xres=1280,yres=800")
    $InputArgs   = @("-device", "nec-usb-xhci", "-device", "usb-kbd", "-device", "usb-mouse")
}

$QemuArgs = @(
    "-accel", "whpx",
    "-cpu", "host",
    "-machine", "virt,gic-version=3,highmem=on",
    "-m", $Memory,
    "-smp", "$Cores,sockets=1,cores=$Cores,threads=1",
    "-object", "iothread,id=iothread0",
    "-kernel", $KernelPath,
    "-initrd", $InitrdPath,
    "-drive", "file=$DiskPath,format=raw,if=none,id=disk,cache=writeback,aio=threads",
    "-device", "virtio-blk-pci,drive=disk,addr=01.0,iothread=iothread0,num-queues=4",
    "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:5555-10.0.2.15:5555,hostfwd=tcp:127.0.0.1:6666-10.0.2.15:6666",
    "-device", "virtio-net-pci,netdev=net0,addr=02.0"
) + $GpuDevice + @(
    "-device", "virtio-serial-pci,addr=04.0,max_ports=16",
    "-chardev", "null,id=hvc0", "-device", "virtconsole,chardev=hvc0",
    "-chardev", "null,id=hvc1", "-device", "virtconsole,chardev=hvc1",
    "-chardev", "null,id=hvc2", "-device", "virtconsole,chardev=hvc2",
    "-chardev", "null,id=hvc3", "-device", "virtconsole,chardev=hvc3",
    "-chardev", "null,id=hvc4", "-device", "virtconsole,chardev=hvc4",
    "-chardev", "null,id=hvc5", "-device", "virtconsole,chardev=hvc5",
    "-chardev", "null,id=hvc6", "-device", "virtconsole,chardev=hvc6",
    "-chardev", "null,id=hvc7", "-device", "virtconsole,chardev=hvc7",
    "-chardev", "null,id=hvc8", "-device", "virtconsole,chardev=hvc8",
    "-chardev", "null,id=hvc9", "-device", "virtconsole,chardev=hvc9",
    "-chardev", "null,id=hvc10", "-device", "virtconsole,chardev=hvc10",
    "-chardev", "null,id=hvc11", "-device", "virtconsole,chardev=hvc11",
    "-chardev", "null,id=hvc12", "-device", "virtconsole,chardev=hvc12",
    "-chardev", "null,id=hvc13", "-device", "virtconsole,chardev=hvc13",
    "-chardev", "null,id=hvc14", "-device", "virtconsole,chardev=hvc14",
    "-chardev", "null,id=hvc15", "-device", "virtconsole,chardev=hvc15"
) + $InputArgs + $DisplayArgs + @(
    "-chardev", "file,id=char0,path=$SerialLog",
    "-serial", "chardev:char0",
    "-serial", "null",
    "-serial", "null",
    "-serial", "null",
    "-monitor", "none",
    "-no-reboot",
    "-append", $AppendCmdline
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Starting Android 16 ARM64 Emulator (QEMU + WHPX)" -ForegroundColor Green
Write-Host " Display Mode : $DisplayMode" -ForegroundColor Yellow
Write-Host " RAM / vCPUs  : $Memory / $Cores cores" -ForegroundColor Yellow
Write-Host " ADB Target   : 127.0.0.1:5555" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

# Start a background watchdog to ensure all serial services are stopped and UI animations optimized upon boot
Start-Job -ScriptBlock {
    do {
        Start-Sleep -Seconds 2
        $s = & "C:\platform-tools\adb.exe" -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>$null
    } until ($s -match "1")
    & "C:\platform-tools\adb.exe" -s 127.0.0.1:5555 shell "setprop ctl.stop seriallogging; setprop ctl.stop console; dmesg -n 1; wm size 1280x800; settings put global window_animation_scale 0.5; settings put global transition_animation_scale 0.5; settings put global animator_duration_scale 0.5" 2>$null
} | Out-Null

& $QemuPath $QemuArgs

