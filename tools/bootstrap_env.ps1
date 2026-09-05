<#
.SYNOPSIS
    Detect + export the minimal toolchain paths the repo needs, with
    machine-independent overrides. Pure-Python build tools (imgtools.py)
    mean NO msys2 / busybox / lz4 / simg2img are required anymore.

.DESCRIPTION
    The only external programs this repo genuinely needs:

      1. Python 3                - m0_build.py / imgtools.py / setup_image.ps1
      2. ADB (platform-tools)     - boot watchdog + verification
      3. QEMU (aarch64)           - to RUN the emulator:
           - custom build at tools\qemu-gfxstream\qemu\build\qemu-system-aarch64.exe
             (needs msys2 DLLs on PATH - see -QemuMsysPath)
           - OR any stock aarch64 QEMU (e.g. msys2 pacman package) for
             -GpuMode basic

    This script finds each on the system, resolves a canonical
    tools\env.json, and prints a machine-readable summary. reproduce.ps1
    consumes env.json so all paths live in ONE place and are editable.

    Output file (repo-local, gitignored):
        tools\env.json   { python, adb, qemu, qemu_msys_path, image_dir }

.PARAMETER Python
.PARAMETER Adb
.PARAMETER Qemu
.PARAMETER ImageDir
    Override individual paths (default: auto-detect).

.PARAMETER Print
    Print the resolved environment as JSON without writing env.json.
#>
[CmdletBinding()]
param(
    [string]$Python,
    [string]$Adb,
    [string]$Qemu,
    [string]$ImageDir,
    [switch]$Print
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$EnvFile  = Join-Path $PSScriptRoot "env.json"

# ------------------------------------------------------------ discovery ---- #
function Find-Python {
    if ($Python) { return $Python }
    foreach ($cand in @("python", "python3", "py")) {
        $cmd = Get-Command $cand -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return ""
}

function Find-Adb {
    if ($Adb) { return $Adb }
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    foreach ($cand in @(
        "$env:LOCALAPPDATA\QArmDroid\platform-tools\adb.exe",
        "$env:LOCALAPPDATA\QArmDroid\scrcpy\adb.exe",
        "$PSScriptRoot\platform-tools\adb.exe",
        "$PSScriptRoot\scrcpy\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$sysDrive\platform-tools\adb.exe",
        "$sysDrive\Android\platform-tools\adb.exe"
    )) { if ($cand -and (Test-Path $cand)) { return $cand } }
    $cmd = Get-Command "adb" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

function Find-Qemu {
    if ($Qemu) { return $Qemu }
    # Single source of truth: repo-local custom build
    $custom = Join-Path $RepoRoot "tools\qemu-gfxstream\qemu\build\qemu-system-aarch64.exe"
    if (Test-Path $custom) { return $custom }
    $bundled = Join-Path $env:LOCALAPPDATA "QArmDroid\qemu\qemu-system-aarch64.exe"
    if (Test-Path $bundled) { return $bundled }
    return ""
}

function Find-MsysBin {
    $cands = @("C:\msys64\clangarm64\bin", "$env:SystemDrive\msys64\clangarm64\bin")
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return ""
}

$env = [ordered]@{
    python       = Find-Python
    adb          = Find-Adb
    qemu         = Find-Qemu
    qemu_msys    = Find-MsysBin
    image_dir    = if ($ImageDir) { $ImageDir } else { Join-Path $RepoRoot "aosp_cf_arm64_only_phone-img" }
}

if ($Print) {
    $env | ConvertTo-Json
    return
}

$env | ConvertTo-Json | Set-Content -Path $EnvFile -Encoding UTF8
Write-Host "== environment resolved ==" -ForegroundColor Cyan
foreach ($k in $env.Keys) {
    $v = $env[$k]
    $ok = if ($k -eq "image_dir") { Test-Path $v } else { $v -ne "" -and (Test-Path $v) }
    $mark = if ($ok) { "OK " } else { "MISS" }
    Write-Host "  [$mark] $k = $v" -ForegroundColor $(if ($ok) {"Green"} else {"Yellow"})
}
Write-Host ""
Write-Host "Written to $EnvFile" -ForegroundColor DarkGray
if (-not $env.python) { Write-Host "PYTHON NOT FOUND - install Python 3 and re-run." -ForegroundColor Red }
if (-not $env.adb)    { Write-Host "ADB NOT FOUND - install platform-tools (or pass -Adb)." -ForegroundColor Yellow }
if (-not $env.qemu)   { Write-Host "QEMU NOT FOUND - build custom QEMU or install msys2 qemu (or pass -Qemu)." -ForegroundColor Yellow }