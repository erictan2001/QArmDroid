import ctypes
import os

os.environ["PATH"] = r"C:\Program Files\Netease\MuMuPlayer\shell;" + os.environ["PATH"]
dll_path = r"C:\Program Files\Netease\MuMuPlayer\shell\nemu-hcs.dll"

try:
    hcs = ctypes.CDLL(dll_path)
    print("Successfully loaded nemu-hcs.dll!")
    for fn in ["InitVM", "ConfigVM", "StartVM", "StopVM", "ReleaseVM", "GetLastVMError"]:
        if hasattr(hcs, fn):
            print(f"  Found function {fn}: {getattr(hcs, fn)}")
except Exception as e:
    print("Failed to load nemu-hcs.dll:", e)
