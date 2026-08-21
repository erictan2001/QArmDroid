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
    Number of virtual CPU cores. Default is 6.

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
    [string]$DisplayMode = "sdl",
    [string]$Memory = "8G",
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

# Ensure serial log directory exists
if (-not (Test-Path $M0Dir)) {
    New-Item -ItemType Directory -Path $M0Dir -Force | Out-Null
}
"" | Out-File -FilePath $SerialLog -Encoding ascii -Force

# Clean up any stale QEMU instances or port forwards to prevent hostfwd port collisions
Get-Process -Name "qemu-system-aarch64" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

$AppendCmdline = "console=ttyAMA0 earlycon=pl011,0x9000000 printk.devkmsg=on audit=0 panic=-1 8250.nr_uarts=4 binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig"

$DisplayArgs = @()
$InputArgs = @()

if ($DisplayMode -eq "embedded" -or $DisplayMode -eq "vnc") {
    $DisplayArgs = @("-vnc", "127.0.0.1:0,websocket=5901,lossy=off,non-adaptive=on")
    $InputArgs   = @("-device", "virtio-tablet-pci", "-device", "virtio-mouse-pci", "-device", "virtio-keyboard-pci")
} elseif ($DisplayMode -eq "sdl") {
    $DisplayArgs = @("-display", "sdl")
    $InputArgs   = @("-device", "virtio-tablet-pci", "-device", "virtio-mouse-pci", "-device", "virtio-keyboard-pci")
} else {
    $DisplayArgs = @("-display", $DisplayMode)
    $InputArgs   = @("-device", "virtio-tablet-pci", "-device", "virtio-mouse-pci", "-device", "virtio-keyboard-pci")
}

$QemuArgs = @(
    "-accel", "whpx",
    "-cpu", "host",
    "-machine", "virt,gic-version=3,highmem=on",
    "-m", $Memory,
    "-smp", "$Cores,sockets=1,cores=$Cores,threads=1",
    "-kernel", $KernelPath,
    "-initrd", $InitrdPath,
    "-drive", "file=$DiskPath,format=raw,if=none,id=disk",
    "-device", "virtio-blk-pci,drive=disk,addr=01.0",
    "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:5555-10.0.2.15:5555,hostfwd=tcp:127.0.0.1:6666-10.0.2.15:6666",
    "-device", "virtio-net-pci,netdev=net0,addr=02.0",
    "-device", "virtio-gpu-pci,addr=03.0"
) + $InputArgs + $DisplayArgs + @(
    "-serial", "stdio",
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

& $QemuPath $QemuArgs
