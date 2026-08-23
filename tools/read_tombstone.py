import subprocess

res = subprocess.run([r"C:\platform-tools\adb.exe", "-s", "127.0.0.1:5555", "shell", "cat", "/data/tombstones/tombstone_99"], capture_output=True, text=True)
lines = res.stdout.splitlines()
print("\n".join(lines[:45]))
