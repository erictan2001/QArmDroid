import os, shutil, subprocess

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
res = subprocess.run([adb_bin, "-s", "127.0.0.1:5555", "shell", "cat", "/data/tombstones/tombstone_99"], capture_output=True, text=True)
lines = res.stdout.splitlines()
print("\n".join(lines[:45]))
