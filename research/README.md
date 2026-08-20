# Research Records & Documentation

This directory contains technical research, feasibility studies, reference source code, and scraped documentation gathered while engineering the native ARM64 Android emulator on Windows 11 ARM64 (Snapdragon X Elite).

---

## Directory Overview

* **[`android-on-arm64-pc.md`](./android-on-arm64-pc.md)**:
  Comprehensive technical whitepaper analyzing ARM64 Android execution on Windows ARM64 (WHPX vs KVM vs Waydroid, hypervisor internals, page table differences, device tree configurations, and graphics pipelines).

* **`aosp-src/`**:
  AOSP source reference files (`fs_mgr_fstab.cpp`, `fstab.cpp`, etc.) referenced for partition layout, early mount logic, and fscrypt encryption handling.

* **`docs/`**:
  Saved reference documentation and specs regarding QEMU `virt` machine architecture, WHPX hypervisor support on Windows ARM64, VirtIO GPU, and Cuttlefish device trees.

* **`scripts/`**:
  Python research and documentation retrieval utilities used during the research phase.
