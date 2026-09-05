$bk = if ($env:QGS) { $env:QGS } else { $PSScriptRoot }
. "$bk\session.ps1"
$env:CC = Join-Path $clangBin "clang.exe"
$env:CXX = Join-Path $clangBin "clang++.exe"
Push-Location "$bk\gfxstream"
meson setup build-host "-Ddecoders=gles,vulkan,composer" "-Dgfxstream-build=host" "-Dplatforms=windows" "-Dlog-level=error" --buildtype=release
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }
ninja -C build-host
Pop-Location
