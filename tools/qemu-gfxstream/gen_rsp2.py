"""gen_rsp2.py: generate ninja rsp files for the final archive/link steps.

Directly extracts the specific build edges for libqemuutil.a,
libqemu-aarch64-softmmu.a and qemu-system-aarch64.exe, and writes their .rsp
files (STATIC_LINKER_RSP rspfile_content=$in -> newline-joined object list).
"""
import sys, os, re

def get_edge(build_ninja, target):
    for ln in open(build_ninja, encoding="utf-8", errors="replace"):
        if ln.startswith(f"build {target}:"):
            return ln.rstrip("\n")
    return None

def main():
    build_ninja = sys.argv[1]
    workdir = sys.argv[2]

    for target in ["libqemuutil.a", "libqemu-aarch64-softmmu.a"]:
        ln = get_edge(build_ninja, target)
        # format: build <out>: RULE <input1> <input2> ...
        body = ln[len(f"build {target}:"):].strip()
        parts = body.split()
        rule = parts[0]
        inputs = [p for p in parts[1:] if not p.endswith(".a") or True]  # keep all inputs (objects)
        # strip rule name; inputs are the object file paths
        inputs = parts[1:]
        rsp_path = os.path.join(workdir, target + ".rsp")
        content = "\n".join(inputs) + "\n"
        with open(rsp_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"wrote {rsp_path}: {len(inputs)} objects ({len(content)} bytes)")

if __name__ == "__main__":
    main()
