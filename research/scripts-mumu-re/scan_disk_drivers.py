with open(r"aosp_cf_arm64_only_phone-img\work\m0\disk.raw", "rb") as f:
    # Scan first 200MB of vendor / system
    import re
    # We can search in 50MB chunks
    found = set()
    for chunk_idx in range(40):
        data = f.read(50 << 20)
        if not data: break
        for m in re.finditer(rb"(virgl_dri\.so|libGLES_mesa\.so|libEGL_mesa\.so|vulkan\.venus\.so|vulkan\.freedreno\.so|vulkan\.panfrost\.so)", data):
            found.add(m.group(1).decode('ascii'))
    print("Found GPU drivers in disk.raw:", found)
