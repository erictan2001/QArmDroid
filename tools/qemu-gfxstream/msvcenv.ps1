# Set up the full MSVC ARM64 environment (LIB/INCLUDE/PATH) by sourcing
# vcvarsall output. Run this in every build session that needs to link
# Rust -msvc code or use link.exe.
param()

if ($env:VCINSTALLDIR -and $env:LIB) {
    Write-Output "MSVC env already loaded: $env:VCINSTALLDIR (TGT_ARCH=$env:VSCMD_ARG_TGT_ARCH)"
    return
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -property installationPath
}
if (-not $vsPath) {
    $cands = @(
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Enterprise",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Community",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Professional",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools"
    )
    $vsPath = ($cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

$vcvars = if ($vsPath) { Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat" } else { $null }
if ($vcvars -and (Test-Path $vcvars)) {
    $isArm64Host = [System.Environment]::Is64BitOperatingSystem -and [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
    $archCands = if ($isArm64Host) { @("arm64", "x64_arm64", "amd64_arm64", "x86_arm64") } else { @("x64_arm64", "amd64_arm64", "x86_arm64", "x64") }
    $lines = $null
    $chosenArch = $null
    foreach ($a in $archCands) {
        $testLines = cmd /c "`"$vcvars`" $a >nul 2>&1 && set" 2>&1
        if ($testLines -and ($testLines | Where-Object { $_ -like "LIB=*" })) {
            $lines = $testLines
            $chosenArch = $a
            break
        }
    }
    $oldPath = $env:PATH
    foreach ($l in $lines) {
        if ($l -match '^([^=]+)=(.*)$') {
            $name = $Matches[1]
            $val = $Matches[2]
            if ($name -in @('LIB','INCLUDE','LIBPATH','VSCMD_ARG_HOST_ARCH','VSCMD_ARG_TGT_ARCH','VCINSTALLDIR','UCRTVersion','WindowsSDKVersion','WindowsSdkDir','WindowsSdkBinPath','WindowsLibPath','UNIVERSALCRTSDKDIR')) {
                Set-Item -Path "env:$name" -Value $val
            } elseif ($name -eq 'Path') {
                $env:PATH = "$val;$oldPath"
            }
        }
    }
    Write-Output "MSVC env loaded. TGT_ARCH=$env:VSCMD_ARG_TGT_ARCH"
} else {
    Write-Warning "Visual Studio vcvarsall.bat not found; continuing with system environment."
}
