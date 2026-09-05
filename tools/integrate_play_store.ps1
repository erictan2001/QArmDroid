<#
.SYNOPSIS
    Integrate Google Play Store & Google Play Services into QArmDroid Android 16 guest.

.DESCRIPTION
    Automates connecting to the Android guest via ADB, downloading Google Play
    compatible components (microG GmsCore, Phonesky Play Store companion, and
    Aurora Store Play Store client), pushing/installing them via adb install,
    granting necessary permissions, and verifying installation.

.PARAMETER AdbPath
    Path to adb executable. If empty, auto-detects from bundled directories or PATH.

.PARAMETER Target
    ADB target serial (default: 127.0.0.1:5555).

.PARAMETER CheckOnly
    Only check installation status and output JSON, do not install anything.

.PARAMETER Force
    Force re-download and re-installation even if already detected.
#>
[CmdletBinding()]
param(
    [string]$AdbPath = "",
    [string]$Target = "127.0.0.1:5555",
    [switch]$CheckOnly,
    [switch]$Force
)

$ErrorActionPreference = "Continue"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Emit-Progress {
    param([int]$Percent, [string]$Stage, [string]$Message = "")
    if ($Message) {
        Write-Host ("PROGRESS {0} {1} :: {2}" -f $Percent, $Stage, $Message)
    } else {
        Write-Host ("PROGRESS {0} {1}" -f $Percent, $Stage)
    }
}

# 1. Resolve ADB
if (-not $AdbPath -or -not (Test-Path $AdbPath)) {
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    $cands = @(
        (Join-Path $PSScriptRoot "..\platform-tools\adb.exe"),
        (Join-Path $PSScriptRoot "platform-tools\adb.exe"),
        (Join-Path $PSScriptRoot "..\scrcpy\adb.exe"),
        (Join-Path $PSScriptRoot "scrcpy\adb.exe"),
        (Join-Path $env:LOCALAPPDATA "QArmDroid\platform-tools\adb.exe"),
        (Join-Path $env:LOCALAPPDATA "QArmDroid\scrcpy\adb.exe"),
        (Join-Path $sysDrive "platform-tools\adb.exe")
    )
    foreach ($c in $cands) {
        if ($c -and (Test-Path $c)) {
            $AdbPath = (Resolve-Path $c).Path
            break
        }
    }
    if (-not $AdbPath) {
        $cmd = Get-Command adb -ErrorAction SilentlyContinue
        if ($cmd) { $AdbPath = $cmd.Source }
        else { $AdbPath = "adb" }
    }
}

# 2. Check ADB connection
& $AdbPath connect $Target 2>$null | Out-Null
$state = (& $AdbPath -s $Target get-state 2>$null)
if ($state -ne "device") {
    Start-Sleep -Seconds 1
    & $AdbPath connect $Target 2>$null | Out-Null
    $state = (& $AdbPath -s $Target get-state 2>$null)
}

$isConnected = ($state -eq "device")

# 3. Check existing package installations
$playStoreInstalled = $false
$playServicesInstalled = $false
$auroraStoreInstalled = $false
$gsfId = ""

if ($isConnected) {
    $packages = & $AdbPath -s $Target shell pm list packages 2>$null
    if ($packages -match "com\.android\.vending") { $playStoreInstalled = $true }
    if ($packages -match "com\.google\.android\.gms" -or $packages -match "org\.microg\.gms") { $playServicesInstalled = $true }
    if ($packages -match "com\.aurora\.store") { $auroraStoreInstalled = $true }

    try {
        $gsfQuery = & $AdbPath -s $Target shell "content query --uri content://com.google.android.gsf.gservices --where `"name='android_id'`"" 2>$null
        if ($gsfQuery -match "value=([0-9a-fA-F]+)") {
            $gsfId = $Matches[1]
        }
    } catch {}
}

if ($CheckOnly) {
    $result = [PSCustomObject]@{
        connected              = $isConnected
        play_store_installed   = $playStoreInstalled
        play_services_installed= $playServicesInstalled
        aurora_store_installed = $auroraStoreInstalled
        installed              = ($playStoreInstalled -and $playServicesInstalled)
        gsf_id                 = $gsfId
    }
    $result | ConvertTo-Json -Compress
    exit 0
}

# ----------------- Installation Mode -----------------
if (-not $isConnected) {
    Emit-Progress 0 "ERROR: Android guest not connected" "Please launch the emulator first (ADB at $Target not responding)."
    Write-Error "Android guest not reachable at $Target."
    exit 1
}

Emit-Progress 10 "Checking boot status" "Verifying guest system services..."
$bootCompleted = ""
for ($i = 0; $i -lt 15; $i++) {
    $bootCompleted = (& $AdbPath -s $Target shell getprop sys.boot_completed 2>$null).Trim()
    if ($bootCompleted -eq "1") { break }
    Start-Sleep -Seconds 2
}

if ($bootCompleted -ne "1") {
    Emit-Progress 0 "ERROR: Android guest still booting" "Wait for Android to fully boot to home screen before integrating Play Store."
    Write-Error "Android guest boot not completed."
    exit 1
}

if ($playStoreInstalled -and $playServicesInstalled -and -not $Force) {
    Emit-Progress 100 "Google Play Store already integrated" "Play Store and Services detected."
    Write-Host "Play Store and Google Play Services already present on device."
    exit 0
}

$cacheDir = Join-Path $env:LOCALAPPDATA "QArmDroid\playstore_cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

Emit-Progress 25 "Preparing Google components" "Fetching component download links..."

$gmsApk = Join-Path $cacheDir "com.google.android.gms.apk"
$gmsUrl = "https://github.com/microg/GmsCore/releases/download/v0.3.16.252432/com.google.android.gms-252432032.apk"

$vendingApk = Join-Path $cacheDir "com.android.vending.apk"
$vendingUrl = "https://github.com/microg/GmsCore/releases/download/v0.3.16.252432/com.android.vending-84022632.apk"

$auroraApk = Join-Path $cacheDir "com.aurora.store.apk"
$auroraUrl = "https://f-droid.org/repo/com.aurora.store_63.apk"

$downloads = @(
    @{ Name = "Google Play Services (microG GmsCore)"; Path = $gmsApk; Url = $gmsUrl; Pct = 35 },
    @{ Name = "Google Play Store Companion (Phonesky)"; Path = $vendingApk; Url = $vendingUrl; Pct = 50 },
    @{ Name = "Google Play Store Client (Aurora Store)"; Path = $auroraApk; Url = $auroraUrl; Pct = 65 }
)

foreach ($item in $downloads) {
    if ($Force -or -not (Test-Path $item.Path) -or ((Get-Item $item.Path).Length -lt 100000)) {
        Emit-Progress $item.Pct "Downloading $($item.Name)" "Fetching $($item.Name)..."
        try {
            Invoke-WebRequest -Uri $item.Url -OutFile $item.Path -UseBasicParsing -TimeoutSec 60
        } catch {
            Write-Warning "Failed to download $($item.Name): $_"
        }
    }
}

if (-not (Test-Path $gmsApk) -or ((Get-Item $gmsApk).Length -lt 100000)) {
    Emit-Progress 0 "ERROR: Download failed" "Could not download Google Play Services APK."
    Write-Error "Google Play Services APK missing."
    exit 1
}

Emit-Progress 70 "Installing Google Play Services" "Installing microG GmsCore (com.google.android.gms)..."
$installGms = & $AdbPath -s $Target install -r -d -g $gmsApk 2>&1
Write-Host "GMS Install output: $installGms"

if (Test-Path $vendingApk) {
    Emit-Progress 80 "Installing Play Store Companion" "Installing Phonesky (com.android.vending)..."
    $installVending = & $AdbPath -s $Target install -r -d -g $vendingApk 2>&1
    Write-Host "Vending Install output: $installVending"
}

if (Test-Path $auroraApk) {
    Emit-Progress 88 "Installing Google Play Store Client" "Installing Aurora Store client..."
    $installAurora = & $AdbPath -s $Target install -r -d -g $auroraApk 2>&1
    Write-Host "Aurora Store Install output: $installAurora"
}

Emit-Progress 94 "Configuring system permissions" "Granting background and location permissions..."
& $AdbPath -s $Target shell pm grant com.google.android.gms android.permission.ACCESS_FINE_LOCATION 2>$null | Out-Null
& $AdbPath -s $Target shell pm grant com.google.android.gms android.permission.ACCESS_COARSE_LOCATION 2>$null | Out-Null
& $AdbPath -s $Target shell pm grant com.google.android.gms android.permission.POST_NOTIFICATIONS 2>$null | Out-Null
& $AdbPath -s $Target shell pm grant com.android.vending android.permission.POST_NOTIFICATIONS 2>$null | Out-Null
& $AdbPath -s $Target shell pm grant com.aurora.store android.permission.POST_NOTIFICATIONS 2>$null | Out-Null

& $AdbPath -s $Target shell dumpsys deviceidle whitelist +com.google.android.gms 2>$null | Out-Null
& $AdbPath -s $Target shell dumpsys deviceidle whitelist +com.android.vending 2>$null | Out-Null
& $AdbPath -s $Target shell dumpsys deviceidle whitelist +com.aurora.store 2>$null | Out-Null

& $AdbPath -s $Target shell am broadcast -a org.microg.gms.settings.CHECK_SETTINGS 2>$null | Out-Null

$finalPackages = & $AdbPath -s $Target shell pm list packages 2>$null
$isGms = ($finalPackages -match "com\.google\.android\.gms" -or $finalPackages -match "org\.microg\.gms")

if ($isGms) {
    Emit-Progress 100 "Google Play Store integration complete!" "Google Play Services and Store components successfully installed."
    Write-Host "Integration succeeded!" -ForegroundColor Green
    exit 0
} else {
    Emit-Progress 0 "ERROR: Installation verification failed" "Google Play Services was not detected in package manager."
    Write-Error "Verification failed."
    exit 1
}
