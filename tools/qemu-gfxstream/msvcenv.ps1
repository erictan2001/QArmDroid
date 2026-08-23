# Set up the full MSVC ARM64 environment (LIB/INCLUDE/PATH) by sourcing
# vcvarsall output. Run this in every build session that needs to link
# Rust -msvc code or use link.exe.
param()

$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat'
$lines = cmd /c "`"$vcvars`" x64_arm64 >nul 2>&1 && set" 2>&1
foreach ($l in $lines) {
    if ($l -match '^([^=]+)=(.*)$') {
        $name = $Matches[1]
        $val = $Matches[2]
        if ($name -in @('LIB','INCLUDE','LIBPATH','Path','VSCMD_ARG_HOST_ARCH','VSCMD_ARG_TGT_ARCH','VCINSTALLDIR','UCRTVersion','WindowsSDKVersion','WindowsSdkDir','WindowsSdkBinPath','WindowsLibPath','UNIVERSALCRTSDKDIR')) {
            Set-Item -Path "env:$name" -Value $val
        }
    }
}
Write-Output "MSVC env loaded. TGT_ARCH=$env:VSCMD_ARG_TGT_ARCH"
