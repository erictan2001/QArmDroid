# Build environment for QEMU gfxstream build under busybox sh.
# Source this with: . .\buildenv.ps1
$root = $PSScriptRoot
$env:BB = "$root\bin"
$msysCands = @($env:MSYS2_ROOT, "C:\msys64", "$env:SystemDrive\msys64")
$msysRoot = ($msysCands | Where-Object { $_ -and (Test-Path (Join-Path $_ "clangarm64\bin")) } | Select-Object -First 1)
$env:CLANG = if ($msysRoot) { Join-Path $msysRoot "clangarm64\bin" } else { "C:\msys64\clangarm64\bin" }
$env:CARGOBIN = Join-Path $env:USERPROFILE ".cargo\bin"
$env:PATH = "$env:BB;$env:CLANG;$env:CARGOBIN;C:\Windows\System32;C:\Windows;$env:PATH"

# Tell pkg-config / build tools where to find msys prefix
$env:MSYSTEM = "CLANGARM64"
$env:PKG_CONFIG = "pkg-config.exe"
$env:CC = "clang.exe"

# Cargo must use git for deps with openssl backend (schannel broken)
$env:CARGO_NET_GIT_FETCH_WITH_CLI = "true"
$env:GIT_SSL_BACKEND = "openssl"   # not honored by git.exe; use -c http.sslBackend per command

Write-Output "PATH set. sh=$(& sh -c 'echo ok')"
