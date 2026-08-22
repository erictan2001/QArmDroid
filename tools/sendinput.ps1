# sendinput.ps1 — drive the real host mouse/keyboard into the QEMU GTK window.
# Verifies the *window* input path (the one users actually use), unlike QMP
# injection. Moves the cursor to the window center, clicks to focus, then
# types keys. Requires qemu window focus; run from an interactive session.
param(
    [int]$X = 640,
    [int]$Y = 400,
    [string]$Keys = "hello",
    [switch]$NoClick
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Input {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@

$q = Get-Process qemu-system-aarch64 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $q -or $q.MainWindowHandle -eq 0) {
    Write-Host "no qemu window found"
    exit 1
}
[Win32Input]::SetForegroundWindow($q.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 300
[Win32Input]::SetCursorPos($X, $Y) | Out-Null
Start-Sleep -Milliseconds 200
if (-not $NoClick) {
    [Win32Input]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)  # left down
    Start-Sleep -Milliseconds 80
    [Win32Input]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)  # left up
}
Start-Sleep -Milliseconds 300
foreach ($ch in $Keys.ToCharArray()) {
    $vk = [int][char]::ToUpper($ch)  # VK codes are uppercase A-Z (0x41-0x5A)
    [Win32Input]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [Win32Input]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
}
Write-Host "sent mouse to ($X,$Y) + click + keys '$Keys' (foreground=$([Win32Input]::GetForegroundWindow()))"