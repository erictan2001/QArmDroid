import subprocess, shutil, os
adb = shutil.which("adb") or os.path.join(os.environ.get("SystemDrive", "C:"), "platform-tools", "adb.exe")
out = subprocess.check_output([adb, "-s", "127.0.0.1:5555", "shell", "dumpsys SurfaceFlinger"], timeout=5).decode('utf-8', errors='ignore')
for line in out.splitlines():
    if any(k in line for k in ["RenderEngine", "GLES", "Vulkan", "OpenGL", "Backend", "version"]):
        print(line)
