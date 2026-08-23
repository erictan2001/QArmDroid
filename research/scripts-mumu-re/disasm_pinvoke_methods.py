import struct

with open(r"C:\Program Files\Netease\MuMuPlayer\shell\nemux-shell-winui.dll", "rb") as f:
    data = f.read()

# Let's search in #Blob stream for signatures corresponding to InitVM, ConfigVM, etc.
# In ECMA-335, MethodDef signature begins with calling convention byte (e.g. 0x00 = DEFAULT, 0x05 = VARARG, etc.)
# Followed by ParamCount, ReturnType, ParamTypes...

strings_off = 0x8BA6C
blob_off = 0x953F8

# Let's parse ImplMap (Table 0x1C)
# Let's find all rows in ImplMap where ImportName points to "InitVM", "ConfigVM", "StartVM", "StopVM", "ReleaseVM"
for target in ["InitVM", "ConfigVM", "StartVM", "StopVM", "ReleaseVM", "GetLastVMError"]:
    pos = 0
    while True:
        idx = data.find(target.encode('utf-8') + b"\x00", strings_off + pos)
        if idx == -1: break
        str_idx = idx - strings_off
        print(f"Found string '{target}' at string index 0x{str_idx:X}")
        pos = idx - strings_off + len(target) + 1
