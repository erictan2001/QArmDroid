@echo off
setlocal

if not defined VCVARSALL (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist "%VSWHERE%" (
        for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -property installationPath`) do (
            if exist "%%i\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARSALL=%%i\VC\Auxiliary\Build\vcvarsall.bat"
            if exist "%%i\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe" set "NINJA=%%i\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
        )
    )
)
if not defined VCVARSALL set "VCVARSALL=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
if not defined NINJA set "NINJA=ninja.exe"

if not defined VSCMD_VER (
    if exist "%VCVARSALL%" call "%VCVARSALL%" arm64
)

set "GFXSRC=%~dp0qemu-gfxstream\gfxstream"
set "BUILD=%GFXSRC%\build-msvc-host"
set "SHIM=%GFXSRC%\common\base\windows\includes\minimal"
set "CC=clang-cl"
set "CXX=clang-cl"

set "MESON_BIN=meson"
if exist "C:\msys64\clangarm64\bin\meson.exe" set "MESON_BIN=C:\msys64\clangarm64\bin\meson.exe"

if exist "%BUILD%" rmdir /s /q "%BUILD%"
cd /d "%GFXSRC%"

echo === meson setup (clang-cl) ===
"%MESON_BIN%" setup "%BUILD%" -Dgfxstream-build=host -Ddecoders=gles,vulkan,composer -Dlog-level=info --buildtype=release -Dcpp_std=c++17 -Dc_std=c11 "-Dcpp_args=-I%SHIM% -I%SHIM%\sys -I%SHIM%\dirent -D_WINSOCKAPI_ -DWIN32_LEAN_AND_MEAN" "-Dc_args=-I%SHIM% -I%SHIM%\sys -I%SHIM%\dirent -D_WINSOCKAPI_ -DWIN32_LEAN_AND_MEAN"
if not exist "%BUILD%\build.ninja" ( echo SETUP FAILED & exit /b 1 )

echo === build gfxstream_backend-0.dll (clang-cl) ===
"%NINJA%" -C "%BUILD%" "host/gfxstream_backend-0.dll"
echo === ninja rc=%ERRORLEVEL% ===

echo === RESULT ===
dir "%BUILD%\host\gfxstream_backend-0.dll*" 2>nul
echo === DONE ===