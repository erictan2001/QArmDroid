<#
.SYNOPSIS
    Integrate official Google Play Store & Google Play Services into QArmDroid Android 16 guest.

.DESCRIPTION
    Automates connecting to the Android guest via ADB, downloading official NikGapps Core
    for Android 16 ARM64 (Google Play Store Phonesky, Google Play Services GmsCore,
    and Google Services Framework GSF), injecting them as privileged system applications
    (/product/priv-app/), pushing system permission whitelists and configurations,
    and reloading the system framework to activate the official Google Play Store.

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
$gsfInstalled = $false
$gsfId = ""

if ($isConnected) {
    $packages = & $AdbPath -s $Target shell pm list packages -s 2>$null
    if ($packages -match "com\.android\.vending") { $playStoreInstalled = $true }
    if ($packages -match "com\.google\.android\.gms") { $playServicesInstalled = $true }
    if ($packages -match "com\.google\.android\.gsf") { $gsfInstalled = $true }

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
        aurora_store_installed = $false
        gsf_installed          = $gsfInstalled
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
    Emit-Progress 100 "Google Play Store already integrated" "Official Google Play Store and Services detected."
    Write-Host "Official Google Play Store and Services already present on device."
    exit 0
}

$cacheDir = Join-Path $env:LOCALAPPDATA "QArmDroid\playstore_cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

$gappsZip = Join-Path $cacheDir "NikGapps-core-arm64-16.zip"
$localCandidates = @(
    (Join-Path $PSScriptRoot "..\work\gapps\nikgapps-core.zip"),
    (Join-Path $PSScriptRoot "gapps\nikgapps-core.zip"),
    (Join-Path $PSScriptRoot "nikgapps-core.zip"),
    (Join-Path (Get-Location) "work\gapps\nikgapps-core.zip")
)
foreach ($cand in $localCandidates) {
    if ($cand -and (Test-Path $cand)) {
        if (-not (Test-Path $gappsZip) -or ((Get-Item $gappsZip).Length -lt 50000000)) {
            Copy-Item -Force $cand $gappsZip
        }
        break
    }
}

$gappsUrl = "https://downloads.sourceforge.net/project/nikgapps/Releases/Android-16/22-Feb-2026/NikGapps-core-arm64-16-20260222-signed.zip"

if (-not (Test-Path $gappsZip) -or ((Get-Item $gappsZip).Length -lt 50000000)) {
    Emit-Progress 20 "Preparing Google components" "Locating official Google Apps package for Android 16..."
    Emit-Progress 30 "Downloading Google Play Store" "Downloading official NikGapps Core package (134 MB)..."
    
    $downloadSuccess = $false
    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlCmd) {
        Write-Host "Downloading via curl from $gappsUrl..."
        & $curlCmd.Source -L --fail --show-error -o $gappsZip $gappsUrl 2>&1 | Out-Null
        if ((Test-Path $gappsZip) -and ((Get-Item $gappsZip).Length -gt 50000000)) {
            $downloadSuccess = $true
        }
    }
    if (-not $downloadSuccess) {
        try {
            Write-Host "Downloading via Invoke-WebRequest..."
            Invoke-WebRequest -Uri $gappsUrl -OutFile $gappsZip -UseBasicParsing -TimeoutSec 180
            if ((Test-Path $gappsZip) -and ((Get-Item $gappsZip).Length -gt 50000000)) {
                $downloadSuccess = $true
            }
        } catch {
            Write-Warning "Failed to download GApps: $_"
        }
    }
    
    if (-not $downloadSuccess) {
        Emit-Progress 0 "ERROR: Download failed" "Could not download official Google Play Store package."
        Write-Error "Google Play Store package download failed."
        exit 1
    }
}

$extractDir = Join-Path $cacheDir "extracted"
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

$phoneskyApk = Get-ChildItem (Join-Path $extractDir "___priv-app___Phonesky\*.apk") -ErrorAction SilentlyContinue | Select-Object -First 1
$gmsApk = Get-ChildItem (Join-Path $extractDir "___priv-app___PrebuiltGmsCore*\*.apk") -ErrorAction SilentlyContinue | Select-Object -First 1
$gsfApk = Get-ChildItem (Join-Path $extractDir "___priv-app___GoogleServicesFramework\*.apk") -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $phoneskyApk -or -not $gmsApk -or -not $gsfApk) {
    Emit-Progress 55 "Extracting Google Apps" "Unpacking Google Play Store, Play Services, and GSF..."
    $coreSubZips = @("GooglePlayStore.zip", "GmsCore.zip", "GoogleServicesFramework.zip", "ExtraFiles.zip")
    $tarCmd = Get-Command tar.exe -ErrorAction SilentlyContinue

    if ($tarCmd) {
        foreach ($sz in $coreSubZips) {
            & $tarCmd.Source -xf $gappsZip -C $extractDir "AppSet/Core/$sz" 2>$null | Out-Null
            $szPath = Join-Path $extractDir "AppSet\Core\$sz"
            if (Test-Path $szPath) {
                & $tarCmd.Source -xf $szPath -C $extractDir 2>$null | Out-Null
            }
        }
    } else {
        $tempAll = Join-Path $extractDir "all"
        Expand-Archive -Path $gappsZip -DestinationPath $tempAll -Force
        foreach ($sz in $coreSubZips) {
            $sub = Join-Path $tempAll "AppSet\Core\$sz"
            if (Test-Path $sub) {
                Expand-Archive -Path $sub -DestinationPath $extractDir -Force
            }
        }
    }

    $phoneskyApk = Get-ChildItem (Join-Path $extractDir "___priv-app___Phonesky\*.apk") -ErrorAction SilentlyContinue | Select-Object -First 1
    $gmsApk = Get-ChildItem (Join-Path $extractDir "___priv-app___PrebuiltGmsCore*\*.apk") -ErrorAction SilentlyContinue | Select-Object -First 1
    $gsfApk = Get-ChildItem (Join-Path $extractDir "___priv-app___GoogleServicesFramework\*.apk") -ErrorAction SilentlyContinue | Select-Object -First 1
}

if (-not $phoneskyApk -or -not $gmsApk -or -not $gsfApk) {
    Emit-Progress 0 "ERROR: Extraction failed" "One or more core Google APKs missing from package."
    Write-Error "Core Google APKs missing."
    exit 1
}

# Attempt Privileged System App Injection via OverlayFS (adb root + adb remount)
Emit-Progress 70 "Configuring Privileged System Injection" "Requesting root access and remounting..."
& $AdbPath -s $Target root 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $AdbPath connect $Target 2>$null | Out-Null
Start-Sleep -Seconds 1

& $AdbPath -s $Target shell "setprop fs_mgr.overlayfs.data_scratch_size_mb 400" 2>$null
$null = & $AdbPath -s $Target remount product 2>&1
$isWritable = (& $AdbPath -s $Target shell "touch /product/priv-app/.test 2>/dev/null && rm -f /product/priv-app/.test && echo WRITABLE" 2>$null) -match "WRITABLE"
if (-not $isWritable) {
    $null = & $AdbPath -s $Target remount 2>&1
    $isWritable = (& $AdbPath -s $Target shell "touch /product/priv-app/.test 2>/dev/null && rm -f /product/priv-app/.test && echo WRITABLE" 2>$null) -match "WRITABLE"
}
# Ensure /system is unmounted from overlayfs so its reported capacity stays at ~725 MB erofs
# instead of reflecting the scratch filesystem size (which would cause AOSP to round up to 16 GB).
& $AdbPath -s $Target shell "grep -q 'overlay on /system ' /proc/mounts && umount -l /system 2>/dev/null || true" 2>$null | Out-Null

if (-not $isWritable) {
    Emit-Progress 0 "ERROR: System partition not writable" "OverlayFS remount failed. Ensure system is running with root and permissive SELinux."
    Write-Error "System partition not writable."
    exit 1
}

# Clean up legacy Aurora Store if previously present, and any unprivileged user-space Play Store in /data/app
& $AdbPath -s $Target shell "rm -rf /product/priv-app/AuroraStore; pm uninstall com.aurora.store 2>/dev/null; pm list packages -3 | grep -q com.android.vending && pm uninstall com.android.vending 2>/dev/null || true" 2>$null | Out-Null

Emit-Progress 75 "Injecting Privileged Permissions" "Pushing system permission whitelist and configs..."
& $AdbPath -s $Target shell "mkdir -p /product/etc/permissions /product/etc/sysconfig /product/etc/default-permissions /product/framework /product/priv-app/Phonesky /product/priv-app/PrebuiltGmsCore /product/priv-app/GoogleServicesFramework" 2>$null

Get-ChildItem (Join-Path $extractDir "___etc___permissions\*.xml") -ErrorAction SilentlyContinue | ForEach-Object {
    & $AdbPath -s $Target push $_.FullName "/product/etc/permissions/$($_.Name)" 2>&1 | Out-Null
}
Get-ChildItem (Join-Path $extractDir "___etc___sysconfig\*.xml") -ErrorAction SilentlyContinue | ForEach-Object {
    & $AdbPath -s $Target push $_.FullName "/product/etc/sysconfig/$($_.Name)" 2>&1 | Out-Null
}
Get-ChildItem (Join-Path $extractDir "___etc___default-permissions\*.xml") -ErrorAction SilentlyContinue | ForEach-Object {
    & $AdbPath -s $Target push $_.FullName "/product/etc/default-permissions/$($_.Name)" 2>&1 | Out-Null
}
$mapsJar = Join-Path $extractDir "___framework\com.google.android.maps.jar"
if (Test-Path $mapsJar) {
    & $AdbPath -s $Target push $mapsJar "/product/framework/com.google.android.maps.jar" 2>&1 | Out-Null
}

Emit-Progress 80 "Injecting Google Services Framework" "Pushing GoogleServicesFramework to /product/priv-app..."
& $AdbPath -s $Target push $gsfApk.FullName "/product/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk" 2>&1 | Out-Null

Emit-Progress 85 "Injecting Google Play Services" "Pushing PrebuiltGmsCore to /product/priv-app..."
& $AdbPath -s $Target push $gmsApk.FullName "/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk" 2>&1 | Out-Null

Emit-Progress 90 "Injecting Google Play Store" "Pushing Phonesky to /product/priv-app..."
& $AdbPath -s $Target push $phoneskyApk.FullName "/product/priv-app/Phonesky/Phonesky.apk" 2>&1 | Out-Null

Emit-Progress 93 "Applying Security Contexts" "Configuring permissions and SELinux..."
& $AdbPath -s $Target shell "chmod 755 /product/priv-app/* && chmod 644 /product/priv-app/*/*.apk /product/etc/permissions/* /product/etc/sysconfig/* /product/etc/default-permissions/* /product/framework/* 2>/dev/null && chown -R root:root /product/priv-app /product/etc /product/framework && restorecon -R /product/priv-app /product/etc /product/framework && sync" 2>$null

Emit-Progress 96 "Activating Google Play Services" "Reloading system framework to register official Play Store..."
& $AdbPath -s $Target shell "setprop ctl.restart zygote" 2>&1 | Out-Null

# Wait for boot completion after zygote reload
$bootSuccess = $false
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 2
    & $AdbPath connect $Target 2>$null | Out-Null
    $b = (& $AdbPath -s $Target shell getprop sys.boot_completed 2>$null).Trim()
    if ($b -eq "1") {
        $bootSuccess = $true
        break
    }
}
& $AdbPath -s $Target shell "grep -q 'overlay on /system ' /proc/mounts && umount -l /system 2>/dev/null || true" 2>$null | Out-Null

Emit-Progress 98 "Configuring system permissions" "Granting background and runtime permissions..."
& $AdbPath -s $Target shell pm grant com.google.android.gms android.permission.ACCESS_FINE_LOCATION 2>$null | Out-Null
& $AdbPath -s $Target shell pm grant com.google.android.gms android.permission.ACCESS_COARSE_LOCATION 2>$null | Out-Null
& $AdbPath -s $Target shell pm grant com.google.android.gms android.permission.POST_NOTIFICATIONS 2>$null | Out-Null
& $AdbPath -s $Target shell pm grant com.android.vending android.permission.POST_NOTIFICATIONS 2>$null | Out-Null

& $AdbPath -s $Target shell dumpsys deviceidle whitelist +com.google.android.gms 2>$null | Out-Null
& $AdbPath -s $Target shell dumpsys deviceidle whitelist +com.android.vending 2>$null | Out-Null

$finalPackages = & $AdbPath -s $Target shell pm list packages 2>$null
$hasVending = ($finalPackages -match "com\.android\.vending")
$hasGms = ($finalPackages -match "com\.google\.android\.gms")

if ($hasVending -and $hasGms) {
    & $AdbPath -s $Target shell sync 2>$null | Out-Null
    Emit-Progress 100 "Google Play Store integration complete!" "Official Google Play Store, Google Play Services, and GSF are active!"
    Write-Host "Integration succeeded!" -ForegroundColor Green
    exit 0
} else {
    Emit-Progress 0 "ERROR: Installation verification failed" "Google Play Store was not detected in package manager."
    Write-Error "Verification failed."
    exit 1
}
