param(
    [string]$DisplayMode = "scrcpy",
    [string]$Memory = "6G",
    [int]$Cores = 6
)

$ErrorActionPreference = "Stop"

$qemuCandidates = @(
    (Join-Path $env:LOCALAPPDATA "QArmDroid\qemu\qemu-system-aarch64.exe"),
    "C:\msys64\clangarm64\bin\qemu-system-aarch64.exe"
)
$QemuBin = ($qemuCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
if (-not $QemuBin) { $QemuBin = "qemu-system-aarch64.exe" }
$ImgDir = Join-Path $env:LOCALAPPDATA "Android\Sdk\system-images\android-34\google_apis\arm64-v8a"
$WorkDir = Join-Path $PSScriptRoot "..\work_sdk"
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

$Kernel = Join-Path $ImgDir "kernel-ranchu"
$Ramdisk = Join-Path $WorkDir "initrd_sdk.img"
$System = Join-Path $ImgDir "system.img"
$Vendor = Join-Path $ImgDir "vendor.img"
$EncryptionKey = Join-Path $ImgDir "encryptionkey.img"
$UserdataSrc = Join-Path $ImgDir "userdata.img"
$UserdataWork = Join-Path $WorkDir "userdata.img"

if (-not (Test-Path $UserdataWork)) {
    Copy-Item $UserdataSrc $UserdataWork
}

# Cleanup existing QEMU
Get-Process -Name qemu-system-aarch64, scrcpy -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

$SerialLog = Join-Path $WorkDir "serial.log"
try { "" | Out-File -FilePath $SerialLog -Encoding ascii -Force -ErrorAction SilentlyContinue } catch {}

$AppendCmdline = "console=ttyAMA0 earlycon=pl011,0x9000000 printk.devkmsg=on audit=0 panic=-1 8250.nr_uarts=4 loop.max_part=7 init=/init androidboot.boot_devices=3f000000.pcie androidboot.hardware=ranchu androidboot.hardware.egl=emulation androidboot.hardware.vulkan=ranchu androidboot.serialno=EMULATOR34 qemu=1 androidboot.qemu=1"

$DisplayArgs = @()
if ($DisplayMode -eq "embedded" -or $DisplayMode -eq "vnc") {
    $DisplayArgs = @("-display", "vnc=127.0.0.1:0,websocket=5901,lossy=off,non-adaptive=on")
} elseif ($DisplayMode -eq "sdl") {
    $DisplayArgs = @("-display", "sdl")
} else {
    $DisplayArgs = @("-display", "none")
}

$QemuArgs = @(
    "-accel", "whpx",
    "-cpu", "host",
    "-machine", "virt,gic-version=3,highmem=on",
    "-m", $Memory,
    "-smp", "$Cores,sockets=1,cores=$Cores,threads=1",
    "-kernel", $Kernel,
    "-initrd", $Ramdisk,
    "-drive", "if=none,id=system,file=$System,format=raw,readonly=on",
    "-device", "virtio-blk-pci,drive=system,addr=01.0,romfile=",
    "-drive", "if=none,id=vendor,file=$Vendor,format=raw,readonly=on",
    "-device", "virtio-blk-pci,drive=vendor,addr=02.0,romfile=",
    "-drive", "if=none,id=metadata,file=$EncryptionKey,format=raw,readonly=on",
    "-device", "virtio-blk-pci,drive=metadata,addr=03.0,romfile=",
    "-drive", "if=none,id=userdata,file=$UserdataWork,format=raw",
    "-device", "virtio-blk-pci,drive=userdata,addr=04.0,romfile=",
    "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:5555-10.0.2.15:5555",
    "-device", "virtio-net-pci,netdev=net0,addr=05.0,romfile=",
    "-device", "virtio-gpu-pci,addr=06.0,xres=1280,yres=800,romfile=",
    "-device", "virtio-tablet-pci",
    "-device", "virtio-keyboard-pci",
    "-serial", "file:$SerialLog",
    "-append", $AppendCmdline
) + $DisplayArgs

Write-Host "=========================================================="
Write-Host " Starting Android 14 ARM64 Google APIs (SDK Ranchu + WHPX)"
Write-Host " Display Mode : $DisplayMode"
Write-Host " RAM / vCPUs  : $Memory / $Cores cores"
Write-Host " ADB Target   : 127.0.0.1:5555"
Write-Host "=========================================================="

& $QemuBin @QemuArgs
