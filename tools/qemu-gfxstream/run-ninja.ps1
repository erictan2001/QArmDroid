# Run a command via .NET ProcessStartInfo with redirected stdout/stderr,
# writing output to a log file. This works around an issue where launching
# ninja via pwsh '&' or cmd /c hangs in this sandbox.
param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string]$Args,
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [Parameter(Mandatory=$true)][string]$LogFile
)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.Arguments = $Args
$psi.WorkingDirectory = $WorkDir
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)
$mutex = New-Object System.Threading.Mutex($false)

$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
while (-not $p.WaitForExit(1000)) {
    # flush incremental output
    if ($null -ne $outTask -and $outTask.IsCompleted) { }
}
$out = $outTask.Result
$err = $errTask.Result
Set-Content -Path $LogFile -Value $out -Encoding UTF8
Add-Content -Path $LogFile -Value "=== STDERR ===" -Encoding UTF8
Add-Content -Path $LogFile -Value $err -Encoding UTF8
Write-Output "EXITCODE=$($p.ExitCode)"
