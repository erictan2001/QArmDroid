"""pyninja.py: execute a ninja build by replaying `ninja -v -n` output.

Drives QEMU/rutabaga builds by re-running the topological command list that
`ninja -v -n` prints, using Python subprocess (which is not blocked in this
sandbox, unlike ninja.exe whose CreateProcess hangs).

Usage:
    python pyninja.py <build_dir> <target> [--jobs N] [--dry] [--log PATH]
"""
import subprocess, sys, os, re, time

NINJA = r"C:\msys64\clangarm64\bin\ninja.exe"

def get_commands(build_dir, target):
    p = subprocess.run(
        [NINJA, "-v", "-n", target],
        cwd=build_dir, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    cmds = []
    for ln in p.stdout.splitlines():
        m = re.match(r'^\[\d+/\d+\]\s+(.*)$', ln)
        if m:
            cmds.append(m.group(1))
    return cmds

def main():
    build_dir = os.path.abspath(sys.argv[1])
    target = sys.argv[2]
    jobs = 1
    dry = False
    logpath = None
    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == "--jobs":
            jobs = int(sys.argv[i + 1]); i += 2; continue
        if sys.argv[i] == "--dry":
            dry = True; i += 1; continue
        if sys.argv[i] == "--log":
            logpath = sys.argv[i + 1]; i += 2; continue
        i += 1

    cmds = get_commands(build_dir, target)
    total = len(cmds)
    print(f"pyninja: {total} commands for target `{target}`", flush=True)
    if dry:
        for c in cmds:
            print(c)
        return

    logf = open(logpath, "w", encoding="utf-8", errors="replace") if logpath else None
    def emit(s):
        print(s, flush=True)
        if logf:
            logf.write(s + "\n"); logf.flush()

    t0 = time.time()
    fail = False
    done = 0
    for idx, c in enumerate(cmds):
        emit(f"[{idx+1}/{total}] {c[:130]}")
        r = subprocess.run(
            c, cwd=build_dir, shell=True,
            capture_output=True, text=True,
            encoding="utf-8", errors="replace",
            env=os.environ,
        )
        if logf:
            if r.stdout.strip():
                logf.write("OUT> " + r.stdout[-2000:] + "\n")
            if r.stderr.strip():
                logf.write("ERR> " + r.stderr[-2000:] + "\n")
            logf.flush()
        if r.returncode != 0:
            emit(f"!! FAILED rc={r.returncode}: {c}")
            emit("STDOUT: " + r.stdout[-3000:])
            emit("STDERR: " + r.stderr[-3000:])
            fail = True
            break
        done += 1

    dt = time.time() - t0
    emit(f"pyninja: {done}/{total} done in {dt:.1f}s; fail={fail}")
    if logf:
        logf.close()
    sys.exit(1 if fail else 0)

if __name__ == "__main__":
    main()
