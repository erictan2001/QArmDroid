"""gen_exe_rsp.py: build qemu-system-aarch64.exe.rsp from build.ninja.

The final link is `"cc" @qemu-system-aarch64.exe.rsp` with
rspfile_content = $ARGS -o $out $in $LINK_ARGS.  We reconstruct these vars:
  ARGS = the "  ARGS = ..." binding immediately preceding the exe build edge
  LINK_ARGS = the "  LINK_ARGS = ..." binding (search upwards, nearest)
  $in = object/archive files listed on the build edge
"""
import sys, os, re, shlex

def main():
    build_ninja = sys.argv[1]
    workdir = sys.argv[2]
    lines = open(build_ninja, encoding="utf-8", errors="replace").read().splitlines()

    edge_idx = None
    for i, ln in enumerate(lines):
        if ln.startswith("build qemu-system-aarch64.exe: c_LINKER_RSP"):
            edge_idx = i
            break
    assert edge_idx is not None, "exe edge not found"

    # meson places the edge's variable bindings (indented lines) on the
    # lines FOLLOWING the build line. Scan the indented block after the edge.
    args = None
    link_args = None
    j = edge_idx + 1
    while j < len(lines):
        ln = lines[j]
        if ln and not ln[0].isspace():
            break  # end of this edge's variable block
        m = re.match(r'^\s*ARGS\s*=\s*(.*)$', ln)
        if m and args is None:
            args = m.group(1)
        m2 = re.match(r'^\s*LINK_ARGS\s*=\s*(.*)$', ln)
        if m2 and link_args is None:
            link_args = m2.group(1)
        j += 1
    if link_args is not None:
        link_args = link_args.replace("$:", ":")

    # inputs: on the build edge line after the rule name; stop at '|'/'||'
    edge = lines[edge_idx]
    body = edge[len("build qemu-system-aarch64.exe:"):].strip()
    parts = body.split()
    inputs = []
    for p in parts[1:]:  # skip rule name c_LINKER_RSP
        if p == "|" or p == "||":
            p_idx = parts.index(p)
            inputs = parts[1:p_idx]
            break
        inputs.append(p)
    # unescape ninja '$:' -> ':' (meson escapes colons in Windows paths)
    inputs = [x.replace("$:", ":") for x in inputs]
    in_str = " ".join(inputs)

    # rsp content: $ARGS -o $out $in $LINK_ARGS (ARGS may be empty for link edge)
    args_s = args if args is not None else ""
    rsp = f'{args_s} -o qemu-system-aarch64.exe {in_str} {link_args}\n'
    out_path = os.path.join(workdir, "qemu-system-aarch64.exe.rsp")
    with open(out_path, "w", encoding="utf-8", errors="replace") as f:
        f.write(rsp)
    print(f"wrote {out_path}: {len(rsp)} bytes, {len(inputs)} inputs, LINK_ARGS_len={len(link_args) if link_args else 0}")

if __name__ == "__main__":
    main()
