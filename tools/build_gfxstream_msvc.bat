@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" arm64
if errorlevel 1 ( echo VCVARSALL FAILED & exit /b 1 )

set "PATH=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\ARM64\bin;%PATH%"
set "GFXSRC=C:\Users\erict\OneDrive\Desktop\Arm64AndroidEmulator\tools\qemu-gfxstream\gfxstream"
set "BUILD=%GFXSRC%\build-msvc-host"
set "NINJA=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
set "SHIM=%GFXSRC%\common\base\windows\includes\minimal"
set "CC=clang-cl"
set "CXX=clang-cl"

if exist "%BUILD%" rmdir /s /q "%BUILD%"
cd /d "%GFXSRC%"

echo === meson setup (clang-cl) ===
"C:\msys64\clangarm64\bin\meson.exe" setup "%BUILD%" -Dgfxstream-build=host -Ddecoders=gles,vulkan,composer -Dlog-level=info --buildtype=release -Dcpp_std=c++17 -Dc_std=c11 "-Dcpp_args=-I%SHIM% -I%SHIM%\sys -I%SHIM%\dirent -D_WINSOCKAPI_ -DWIN32_LEAN_AND_MEAN" "-Dc_args=-I%SHIM% -I%SHIM%\sys -I%SHIM%\dirent -D_WINSOCKAPI_ -DWIN32_LEAN_AND_MEAN"
if not exist "%BUILD%\build.ninja" ( echo SETUP FAILED & exit /b 1 )

echo === build gfxstream_backend-0.dll (clang-cl) ===
"%NINJA%" -C "%BUILD%" "host/gfxstream_backend-0.dll"
echo === ninja rc=%ERRORLEVEL% ===

echo === RESULT ===
dir "%BUILD%\host\gfxstream_backend-0.dll*" 2>nul
echo === DONE ===