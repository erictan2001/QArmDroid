param(
    [string]$Target = "127.0.0.1:5555",
    [int]$MaxFps = 30,
    [int]$MaxSize = 960,
    [string]$BitRate = "2M"
)

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScrcpyExe = Join-Path $PSScriptRoot "scrcpy\scrcpy.exe"

if (-not (Test-Path $ScrcpyExe)) {
    Write-Error "Scrcpy binary not found at $ScrcpyExe"
    exit 1
}

# 30 fps / 2M: the guest's software H264 encoder saturates around 11-13 fps
# at 60fps/4M (112 vs 115 frames per 10s measured) — capping the target and
# bitrate keeps the stream stable instead of bursty, which reads as smoother.
Write-Host "Connecting Scrcpy to $Target (Direct3D 11 / ${MaxSize}p / ${MaxFps}fps)..." -ForegroundColor Green

& $ScrcpyExe -s $Target --max-fps=$MaxFps -m $MaxSize -b $BitRate --video-codec=h264 --render-driver=direct3d11 --window-title="Android 16 Native ARM64" --no-audio
