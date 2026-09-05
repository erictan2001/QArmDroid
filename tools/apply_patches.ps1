<#
.SYNOPSIS
    Apply the repo's QEMU/gfxstream patches to fresh clones of the nested
    source trees (tools/qemu-gfxstream/qemu, tools/qemu-gfxstream/gfxstream).

.DESCRIPTION
    The nested repos are gitlinks pinned to upstream commits. All custom
    changes (gfxstream ExternalBlob renderer-features property, SDL color
    format mapping, USB HID fix, gfxstream Windows bincompat + POSIX shim
    headers) live in tools/qemu-gfxstream/patches/ in this repo.

    This script:
      1. Ensures the nested repos are cloned (git submodule update --init
         or warns how to clone them manually).
      2. Applies the qemu patch to tools/qemu-gfxstream/qemu.
      3. Applies the gfxstream patch + copies shim headers / gles_compat.h
         into tools/qemu-gfxstream/gfxstream.

    It is idempotent: re-running skips already-applied patches (checked via
    `git apply --check`).

.PARAMETER QemuDir
    Path to the QEMU source tree (default tools/qemu-gfxstream/qemu).

.PARAMETER GfxstreamDir
    Path to the gfxstream source tree (default tools/qemu-gfxstream/gfxstream).
#>
[CmdletBinding()]
param(
    [string]$QemuDir,
    [string]$GfxstreamDir
)

$ErrorActionPreference = "Continue"
$RepoRoot  = (Resolve-Path "$PSScriptRoot\..").Path
$GfxDir    = Join-Path $RepoRoot "tools\qemu-gfxstream"
$PatchRoot = Join-Path $GfxDir "patches"
if (-not $QemuDir)      { $QemuDir      = Join-Path $GfxDir "qemu" }
if (-not $GfxstreamDir) { $GfxstreamDir = Join-Path $GfxDir "gfxstream" }

# ------------------------------------------------------------ helpers ----- #
function Test-Patched($repoDir, $marker, $targetRelPath = $null) {
    # marker: a string that exists ONLY after our patch is applied
    if (-not (Test-Path $repoDir)) { return $false }
    if ($targetRelPath) {
        $targetFile = Join-Path $repoDir $targetRelPath
        if (Test-Path $targetFile) {
            return (Select-String -Path $targetFile -Pattern $marker -SimpleMatch -Quiet -ErrorAction SilentlyContinue)
        }
    }
    $hit = Get-ChildItem -Path $repoDir -Recurse -Include *.c,*.cpp,*.h -ErrorAction SilentlyContinue |
        Select-String -Pattern $marker -SimpleMatch -List -ErrorAction SilentlyContinue
    return ($null -ne $hit)
}

function Apply-GitPatch($repoDir, $patchFile, $label) {
    if (-not (Test-Path $patchFile)) { Write-Warning "${label}: patch missing $patchFile"; return }
    if (-not (Test-Path (Join-Path $repoDir ".git"))) {
        Write-Warning "${label}: $repoDir is not a git repo - clone it first (see README / bootstrap_env.ps1)"
        return
    }
    # First try clean apply; if the working tree is dirty with CRLF noise,
    # fall back to --ignore-space-change (applies the real hunks only).
    Push-Location $repoDir
    try {
        $check = git apply --check $patchFile 2>&1
        if ($LASTEXITCODE -eq 0) {
            git apply $patchFile 2>&1
            Write-Host "[patch] $label applied (git apply)." -ForegroundColor Green
        } else {
            Write-Host "[patch] $label clean apply failed - trying --ignore-space-change..." -ForegroundColor Yellow
            $check2 = git apply --check --ignore-space-change $patchFile 2>&1
            if ($LASTEXITCODE -eq 0) {
                git apply --ignore-space-change $patchFile 2>&1
                Write-Host "[patch] $label applied (--ignore-space-change)." -ForegroundColor Green
            } else {
                Write-Warning "${label}: patch could NOT be applied cleanly. Check repo state."
                Write-Host $check2 -ForegroundColor Red
            }
        }
    }
    finally { Pop-Location }
}

# ------------------------------------------------------------ submodules --- #
foreach ($sub in @(
    @{ Path = $QemuDir; Rel = "tools/qemu-gfxstream/qemu"; Name = "qemu" },
    @{ Path = $GfxstreamDir; Rel = "tools/qemu-gfxstream/gfxstream"; Name = "gfxstream" }
)) {
    if (-not (Test-Path (Join-Path $sub.Path ".git"))) {
        Write-Host "[submodule] $($sub.Name) not initialized - running git submodule update..." -ForegroundColor Cyan
        git -C $RepoRoot submodule update --init --recursive $sub.Rel
    }
}

# ------------------------------------------------------------ qemu patch --- #
Write-Host "== QEMU patches ==" -ForegroundColor Cyan
$qemuPatch = Join-Path $PatchRoot "qemu\0001-gfxstream-sdl-color-hid.patch"
if (Test-Patched $QemuDir "renderer-features" "hw\display\virtio-gpu-rutabaga.c") {
    Write-Host "[qemu] already patched (renderer-features present) - skipping." -ForegroundColor DarkGray
} else {
    Apply-GitPatch $QemuDir $qemuPatch "qemu"
}

# --------------------------------------------------------- gfxstream ------ #
Write-Host "== gfxstream patches ==" -ForegroundColor Cyan
$gfxPatch  = Join-Path $PatchRoot "gfxstream\0001-windows-bincompat.patch"
$shimsSrc  = Join-Path $PatchRoot "gfxstream\windows-shims"
$glesHdr   = Join-Path $PatchRoot "gfxstream\gles_compat.h"
$glesHdr2  = Join-Path $PatchRoot "gfxstream\host\gles_compat.h"   # (subpath copy)

if (Test-Patched $GfxstreamDir "gles_compat" "host\frame_buffer.h") {
    Write-Host "[gfxstream] already patched (gles_compat.h present) - skipping." -ForegroundColor DarkGray
} else {
    Apply-GitPatch $GfxstreamDir $gfxPatch "gfxstream"

    # Untracked Windows POSIX shim headers (needed by meson clang-cl build)
    if (Test-Path $shimsSrc) {
        $shimDst = Join-Path $GfxstreamDir "common\base\windows\includes\minimal"
        New-Item -ItemType Directory -Force -Path $shimDst | Out-Null
        Copy-Item -Recurse -Force (Join-Path $shimsSrc "*") $shimDst
        Write-Host "[gfxstream] copied Windows shim headers -> common/base/windows/includes/minimal" -ForegroundColor Green
    }
    # host/gles_compat.h + host/include/gfxstream/host/gles_compat.h
    foreach ($dstRel in @("host\gles_compat.h", "host\include\gfxstream\host\gles_compat.h")) {
        $dst = Join-Path $GfxstreamDir $dstRel
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item -Force $glesHdr $dst
    }
    Write-Host "[gfxstream] copied gles_compat.h" -ForegroundColor Green
}

Write-Host "== done ==" -ForegroundColor Green
Write-Host "QEMU:      $QemuDir" -ForegroundColor DarkGray
Write-Host "gfxstream: $GfxstreamDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next: run tools\reproduce.ps1 (or build QEMU per tools\qemu-gfxstream\BUILD_LOG.md)." -ForegroundColor Yellow