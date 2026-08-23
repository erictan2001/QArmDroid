. "$env:QGS\session.ps1"
$env:CC = "C:\msys64\clangarm64\bin\clang.exe"
$env:CXX = "C:\msys64\clangarm64\bin\clang++.exe"
cd "$env:QGS\gfxstream"
meson setup build-host "-Ddecoders=gles,vulkan,composer" "-Dgfxstream-build=host" "-Dplatforms=windows" "-Dlog-level=error" --buildtype=release
if ($LASTEXITCODE -ne 0) { exit 1 }
ninja -C build-host
