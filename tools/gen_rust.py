#!/usr/bin/env python3
"""Sync helper for the hcs_engine Rust crate.

The source of truth is tools/hcs_engine/src/*.rs (hand-written, reviewed
code). This script verifies every expected source file exists and reports
the crate layout — it no longer regenerates the sources from embedded
templates (the old behaviour clobbered fixes and drifted out of sync).

Usage:  python tools/gen_rust.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(HERE, "hcs_engine", "src")

EXPECTED = [
    "lib.rs",
    "main.rs",
    "ctrl.rs",
    "hcs.rs",
    "shm_ring.rs",
    "vulkan_host.rs",
    "dispatch.rs",
]

def main() -> int:
    missing = [f for f in EXPECTED if not os.path.isfile(os.path.join(SRC_DIR, f))]
    if missing:
        print("ERROR: hcs_engine is missing source files: " + ", ".join(missing))
        return 1

    sizes = {f: os.path.getsize(os.path.join(SRC_DIR, f)) for f in EXPECTED}
    total = sum(sizes.values())
    for f in EXPECTED:
        print(f"  ok  {f:24s} {sizes[f]:8d} bytes")
    print(f"hcs_engine sources verified ({total} bytes total). Build with:")
    print("  cargo build --release --manifest-path tools/hcs_engine/Cargo.toml")
    return 0

if __name__ == "__main__":
    sys.exit(main())