import os
import shutil
import subprocess
import time

candidates = [
    shutil.which("adb"),
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "QArmDroid", "platform-tools", "adb.exe"),
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "QArmDroid", "scrcpy", "adb.exe"),
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "platform-tools", "adb.exe"),
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "scrcpy", "adb.exe"),
    os.path.join(os.environ.get("SystemDrive", "C:"), "platform-tools", "adb.exe"),
    "adb",
]
adb_bin = next((c for c in candidates if c and os.path.exists(c)), "adb")

def adb(cmd):
    return subprocess.run([adb_bin, "-s", "127.0.0.1:5555"] + cmd.split(), capture_output=True, text=True)

print("1. Unlocking device...")
adb("shell input keyevent 82")
time.sleep(1)

print("2. Swiping up/down on home screen...")
for i in range(5):
    adb("shell input swipe 640 600 640 200 150")
    time.sleep(0.5)
    adb("shell input swipe 640 200 640 600 150")
    time.sleep(0.5)

print("3. Launching Settings app...")
adb("shell am start -a android.settings.SETTINGS")
time.sleep(2)

print("4. Scrolling in Settings...")
for i in range(5):
    adb("shell input swipe 640 700 640 300 200")
    time.sleep(0.5)

print("5. Checking logcat for SurfaceFlinger or RenderEngine errors...")
log = adb("logcat -d -t 100")
for line in log.stdout.splitlines():
    if any(k in line for k in ["SurfaceFlinger", "RenderEngine", "GraphicBuffer", "hwcomposer", "fatal", "crash", "died", "ANR", "corrupt", "freeze"]):
        print("  ", line)

print("6. Pulling screenshot...")
adb("shell screencap -p /data/local/tmp/stress_screen.png")
adb("pull /data/local/tmp/stress_screen.png tools/stress_screen.png")
print("Done!")
