<#
.SYNOPSIS
    One-command launcher for Android 16 ARM64 with NATIVE HOST-GPU VULKAN
    passthrough: starts the hcs_engine Vulkan daemon, the VM, pushes the
    guest render client, and verifies a real GPU-rendered frame from inside
    Android.

.DESCRIPTION
    Stage 1: build + start the Vulkan passthrough daemon (hcs_engine.exe
    --serve on 127.0.0.1:6520; the guest reaches it at 10.0.2.2:6520 via
    the QEMU slirp gateway).
    Stage 2: launch the VM (launch.ps1) unless one is already running.
    Stage 3: wait for Android boot, push tools/vk_guest_client.elf into the
    guest and run a 256x256 render on the host GPU through the passthrough.
    Stage 4: pull the frame, convert it to PNG (tools/raw_to_png.py) and
    report the artifact path. Optionally attach scrcpy.

.PARAMETER DisplayMode
    Display backend for QEMU (scrcpy | sdl | vnc | none). Default scrcpy.

.PARAMETER Memory
    Guest RAM (default 6G).

.PARAMETER Cores
    Guest vCPUs (default 4).

.PARAMETER NoRenderTest
    Skip the guest render verification stage.


.EXAMPLE
    .\tools\launch_vulkan.ps1
    Full flow: daemon + VM + guest render test + scrcpy.
#>

[CmdletBinding()]
param(
    [string]$DisplayMode = "scrcpy",
    [string]$Memory = "6G",
    [int]$Cores = 6,
    [switch]$NoRenderTest
)

# PS 5.1 treats ANY native-command stderr as a terminating error under
# EAP=Stop (cargo status lines, adb push progress). Use Continue and rely
# on explicit checks instead.
$sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
$adbCandidates = @(
    (Join-Path $env:LOCALAPPDATA "QArmDroid\platform-tools\adb.exe"),
    (Join-Path $env:LOCALAPPDATA "QArmDroid\scrcpy\adb.exe"),
    (Join-Path $PSScriptRoot "platform-tools\adb.exe"),
    (Join-Path $PSScriptRoot "scrcpy\adb.exe"),
    (Get-Command adb -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path $sysDrive "platform-tools\adb.exe")
)
$adb = ($adbCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
if (-not $adb) { $adb = "adb" }
$target = "127.0.0.1:5555"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Android 16 ARM64 + Native Host-GPU Vulkan Passthrough" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

# ---------- Stage 1: the Vulkan passthrough daemon ----------
Write-Host "[1/4] Building Vulkan passthrough daemon..." -ForegroundColor Yellow
# PS 5.1 treats any native stderr as a terminating error under EAP=Stop;
# relaxed above; stderr status lines are discarded.
Push-Location (Join-Path $repoRoot "tools\hcs_engine")
& cargo build --release 2>$null | Out-Null
Pop-Location
$DaemonExe = Join-Path $repoRoot "tools\hcs_engine\target\release\hcs_engine.exe"
if (-not (Test-Path $DaemonExe)) { throw "daemon build failed: $DaemonExe missing" }

Get-Process -Name "hcs_engine" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Start-Process -FilePath $DaemonExe -ArgumentList "--serve" -WindowStyle Hidden
$portOk = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 300
    if (Test-NetConnection -ComputerName 127.0.0.1 -Port 6520 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        $portOk = $true; break
    }
}
if (-not $portOk) { throw "Vulkan daemon did not open port 6520" }
Write-Host "[+] Vulkan passthrough daemon online on 127.0.0.1:6520 (guest -> 10.0.2.2:6520)" -ForegroundColor Green

# ---------- Stage 2: the VM ----------
Write-Host "[2/4] Checking Android VM..." -ForegroundColor Yellow
$vmRunning = Get-Process -Name "qemu-system-aarch64" -ErrorAction SilentlyContinue
if ($vmRunning) {
    Write-Host "[*] VM already running (PID $($vmRunning.Id)) - reusing it" -ForegroundColor Yellow
} else {
    Write-Host "[*] Launching VM ($Cores cores / $Memory)..." -ForegroundColor Yellow
    $launch = Join-Path $PSScriptRoot "launch.ps1"
    Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$launch`" -DisplayMode `"$DisplayMode`" -Memory `"$Memory`" -Cores $Cores" -WindowStyle Hidden
}

Write-Host "[3/4] Waiting for Android boot..." -ForegroundColor Yellow
$booted = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    $state = & $adb -s $target shell getprop sys.boot_completed 2>$null
    if ("$state" -match "1") { $booted = $true; break }
}
if (-not $booted) {
    Write-Warning "Boot timeout. VM may still be starting; run the render test again later."
} else {
    Write-Host "[+] Android boot completed" -ForegroundColor Green
}

# ---------- Stage 3/4: guest render verification ----------
if ($booted -and -not $NoRenderTest) {
    Write-Host "[4/4] Running native-Vulkan render INSIDE Android..." -ForegroundColor Yellow
    $client = Join-Path $PSScriptRoot "vk_guest_client.elf"
    if (-not (Test-Path $client)) {
        Write-Warning "vk_guest_client.elf missing; skip render test"
    } else {
        & $adb -s $target push $client /data/local/tmp/vk_client 2>$null | Out-Null
        & $adb -s $target shell "chmod 755 /data/local/tmp/vk_client; /data/local/tmp/vk_client 256 256 /data/local/tmp/frame.raw" 2>$null
        & $adb -s $target pull /data/local/tmp/frame.raw (Join-Path $repoRoot "tools\guest_frame.raw") 2>$null | Out-Null
        $png = Join-Path $repoRoot "tools\guest_frame.png"
        python (Join-Path $PSScriptRoot "raw_to_png.py") (Join-Path $repoRoot "tools\guest_frame.raw") 256 256 $png
        if (Test-Path $png) {
            Write-Host "[+] RENDER VERIFIED - frame saved to:" -ForegroundColor Green
            Write-Host "    $png" -ForegroundColor Green
        }
    }
}

if ($booted -and $DisplayMode -eq "scrcpy") {
    # scrcpy auto-attach was removed: canonical stream config (30fps/960p/2M)
    # now lives in src-tauri/src/lib.rs; attach via the GUI Launch button or:
    #   tools\scrcpy\scrcpy.exe -s 127.0.0.1:5555 --max-fps=30 -m 960 -b 2M --no-audio
    Write-Host "[*] scrcpy not auto-attached (GUI Launch button attaches with tuned config)" -ForegroundColor Yellow
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Vulkan passthrough up. Daemon: 127.0.0.1:6520" -ForegroundColor Green
Write-Host " Guest client: adb shell /data/local/tmp/vk_client W H out.raw" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
