# Making Android Bootable and Running on ARM64 PCs

Research note for the **ARM64 Android Emulator** project (Snapdragon X Elite / Windows ARM64 host).
Every factual claim below carries a link to its primary source; where a claim could not be
verified against a primary source this session, it is labeled as such and moved to
[§7 Open questions](#7-open-questions--risks).

Local copies of AOSP sources referenced here live in `research/aosp-src/`; raw page dumps from
earlier research rounds live in `research/raw/`.

---

## 1. Executive summary

There are exactly two sane ways to "boot and run Android" on an ARM64 computer today, and they
depend on the host OS:

1. **Hypervisor VM (the only option on consumer Windows ARM64 PCs).** Google's official
   Cuttlefish tooling only runs on Linux + KVM, and consumer Snapdragon X Elite machines do not
   expose an open native-boot path in practice (OEM firmware policy — no verifiable primary doc
   this session, see §7). QEMU with the WHPX accelerator is the documented, working way to run
   an ARM64 guest on an ARM64 Windows host — this repo's current approach. See
   [§2](#2-options-matrix) and [§5](#5-qemu--whpx-on-windows-arm64).
2. **Linux + KVM host (the official Cuttlefish path).** If the host OS can be Linux (e.g. a
   Snapdragon Dev Kit or Raspberry Pi 5 class machine), Google's own `launch_cvd` + crosvm/QEMU
   + KVM stack is the supported way to run AOSP Cuttlefish images, and Waydroid adds a
   container option. See [§2](#2-options-matrix).

Native boot of Android directly on an ARM64 **PC** (SystemReady SR/ES) is not achievable on
consumer Snapdragon X Elite hardware today; it only works on open ARM64 SBCs and dev boards
(GloDroid, Android-on-Raspberry-Pi). Windows Subsystem for Android is dead (removed from the
Microsoft Store on **March 5, 2025**).

**Recommendation for this project:** keep QEMU + WHPX on Windows ARM64 as the primary path; it is
the only supported-by-its-own-docs option on this class of hardware. Treat "Linux ARM64 + KVM +
`launch_cvd`" as the reference implementation to keep borrowing config from, and as the fallback
if the host OS constraint ever lifts.

---

## 2. Options matrix

| Path | Host | Mechanism | Status today | Primary source |
|---|---|---|---|---|
| **QEMU + WHPX** (this repo) | Windows ARM64 | QEMU `-accel whpx`, `-machine virt`, Cuttlefish image, hand-rolled initrd/bootconfig | **Works; documented by QEMU** | [QEMU WHPX doc](https://www.qemu.org/docs/master/system/whpx.html) |
| Android Studio emulator | ARM64 hosts | Emulator + KVM/WHPX, arm64-v8a system images (API 21+) | ARM64-host support is documented for **Linux (KVM)** and **Apple silicon**; **Windows ARM64 hosts are not in the supported-processor list** | [emulator-acceleration](https://developer.android.com/studio/run/emulator-acceleration), [emulator release notes](https://developer.android.com/studio/releases/emulator) |
| crosvm + WHPX | Windows ARM64 | crosvm hypervisor backend `whpx` | Exists but **"Tested upstream: no"** | [crosvm book — Hypervisors](https://crosvm.dev/book/hypervisors.html) |
| WSA | Windows ARM64 | Microsoft's Hyper-V-based Android VM | **Discontinued** — removed from Microsoft Store Mar 5, 2025 | [Microsoft Learn — WSA](https://learn.microsoft.com/en-us/windows/android/wsa/) |
| WSL2 + KVM | Windows ARM64 | Nested virtualization inside WSL2 | **Unreliable on ARM64** — "[Nested virtualization is not supported on arm based machines]" ([#13796](https://github.com/microsoft/WSL/issues/13796)); custom kernels "[not supported on ARM64]" ([#8821](https://github.com/microsoft/WSL/issues/8821)) | [microsoft/WSL issues](https://github.com/microsoft/WSL/issues) |
| **Cuttlefish (`launch_cvd`) + KVM** | Linux ARM64 | crosvm or QEMU + KVM, official host packages | **Official supported path** | [Cuttlefish — Get started](https://source.android.com/docs/devices/cuttlefish/get-started) |
| Waydroid | Linux ARM64 | LXC container around Android system image | Active project | [Waydroid docs](https://docs.waydro.id) |
| Native boot (SystemReady) | ARM64 PC (bare metal) | UEFI + ACPI firmware boots Android directly | **Not viable on consumer Snapdragon X PCs in practice** (firmware policy; normative specs unverified — §7); viable on open SBCs | [SystemReady program page](https://www.arm.com/architecture/system-architectures/systemready-certification-program) |
| GloDroid / Android-on-RPi | ARM64 SBCs | UEFI/U-Boot + AOSP port | Active community projects | [GloDroid](https://glodroid.github.io) |

---

## 3. Android boot chain on ARM64

The minimal chain that must work before Android userspace starts (all ARM64 Android devices
follow it, physical or virtual):

1. **Bootloader** loads the GKI kernel plus its ramdisks. On real devices this is ABL/U-Boot/
   EDK2 reading `boot.img` / `vendor_boot.img`; under QEMU the equivalent is `-kernel` +
   `-initrd` or firmware. AOSP docs: [Bootloader overview](https://source.android.com/docs/core/architecture/bootloader),
   [Boot image header](https://source.android.com/docs/core/architecture/bootloader/boot-image-header),
   [Partitions](https://source.android.com/docs/core/architecture/partitions). The kernel is a
   [GKI](https://source.android.com/docs/core/architecture/kernel/generic-kernel-image) image
   (one binary + loadable modules; mandatory for devices shipping kernel ≥5.10 since Android 12).
   On ARM64, hardware description is **DeviceTree**, not ACPI — see
   [Device tree overlays](https://source.android.com/docs/core/architecture/dto); QEMU's `virt`
   board auto-generates the DTB, which is why Android-on-`virt` is DT-based.
2. **Bootconfig** — `androidboot.*` key/value pairs appended to the initramfs with a
   checksummed `#BOOTCONFIG` trailer. First-stage init consumes them as read-only
   `ro.boot.*` properties. Values are parsed **literally** by the kernel, so they must not be
   quoted (this repo hit exactly that bug — see `tools/m0_build.py` header comment; the AOSP
   bootconfig handling is in `research/aosp-src/bootconfig_args.cpp.txt`, upstream
   [assemble_cvd](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/main/host/commands/assemble_cvd/)).
3. **AVB / vbmeta** gates the chain unless disabled. Cuttlefish images are effectively unlocked
   devices; this repo boots with `androidboot.verifiedbootstate=orange`,
   `androidboot.veritymode=disabled`, `androidboot.vbmeta.invalidate=yes` (see
   `tools/m0_build.py`). Background: [Verified Boot](https://source.android.com/docs/security/features/verifiedboot)
   and its [device state](https://source.android.com/docs/security/features/verifiedboot/device-state)
   model (LOCKED boots only software signed to the root of trust; UNLOCKED boots anyway — the
   state `verifiedbootstate=orange` requests).
4. **First-stage init** mounts the `fstab.<suffix>` entries (the Cuttlefish ramdisk ships
   `fstab.cf.ext4.cts` and friends — see
   `aosp_cf_arm64_only_phone-img/work/vend/fs/first_stage_ramdisk/system/etc/fstab.cf.ext4.cts`),
   then `SwitchRoot("/first_stage_ramdisk")` hands off to the second-stage init — see
   [first_stage_init.cpp](https://android.googlesource.com/platform/system/core/+/refs/heads/main/init/first_stage_init.cpp)
   (local copy `research/aosp-src/first_stage_init.cpp`, line 522).
5. **Second-stage init** runs `early-init` → `init` → `late-init` (the `init.rc` stages) and
   starts zygote, which forks system_server. Source: `init.cpp` / `SecondStageMain` in
   [system/core](https://android.googlesource.com/platform/system/core/+/refs/heads/main/init/).
6. On the Cuttlefish image specifically, `/system`, `/vendor`, `/product` live in the dynamic
   `super` partition (dm-linear logical volumes), and `userdata`/`metadata` are separate —
   see [Dynamic partitions](https://source.android.com/docs/core/ota/dynamic_partitions) and the
   repo's GPT assembly in `tools/m0_build.py`.

---

## 4. How the Cuttlefish image boots (aosp_cf_arm64_only_phone)

### 4.1 Official path: Linux + KVM only

Cuttlefish is "a virtual device … dependent on virtualization being available on the host"
and its host packages are Debian-only (`cuttlefish-base`/`cuttlefish-user`), launched by
`launch_cvd` under a Linux host with KVM (`/dev/kvm`). Windows is **not** a supported host OS.
The ARM64 target is `aosp_cf_arm64_only_phone-userdebug`, and the docs require downloading the
matching `cvd-host_package.tar.gz` from the **same build** as the image zip. Interaction is via
adb and WebRTC on port 8443. Sources:
[Cuttlefish — landing](https://source.android.com/docs/devices/cuttlefish/landing) ("locally
(on Linux x86 and ARM64 machines)"),
[Cuttlefish — Get started](https://source.android.com/docs/devices/cuttlefish/get-started).

### 4.2 What upstream's QEMU path actually does (and why this repo hand-rolls it)

From AOSP `device/google/cuttlefish` (local copies in `research/aosp-src/`):

- Machine/accelerator selection in
  [qemu_manager.cpp](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/main/host/libs/vm_manager/qemu_manager.cpp)
  (local `research/aosp-src/qemu_manager.cpp.txt`):
  - `-machine virt,gic-version=3` on non-x86 hosts (x86 hosts use `pc`);
  - accelerator branches for `kvm` (Linux) and `hvf` (macOS), with an explicit
    `#error "Unknown OS"` fallback (local copy line 387) — **upstream Cuttlefish's QEMU path has
    no Windows accelerator branch at all.** That is the primary-source reason this project
    drives `qemu-system-aarch64` + WHPX directly instead of using `launch_cvd`.
  - CPU: `-cpu host` when the guest arch matches the host, else `max`. Firmware: on ARM,
    `-bios <bootloader>` (U-Boot/EDK2) — `-kernel`+`-initrd` direct boot is this repo's
    deliberate simplification that skips boot.img parsing entirely.
  - `androidboot.boot_devices` per arch (`ConfigureBootDevices`): **`4010000000.pcie`** on
    Linux ARM64, `3f000000.pcie` on Apple ARM64 / 32-bit ARM. The value is the sysfs platform
    prefix first-stage init scans to find its disks.
  - Disks: `virtio-blk-pci-non-transitional`, with `bootindex=1` on disk 0; virtio-net-pci-
    non-transitional NICs; virtio-gpu-pci family.
- GPU mode → bootconfig mapping (`ConfigureGraphics`): `guest_swiftshader`,
  `drm_virgl`, and `gfxstream` modes each set a specific `androidboot.hardware.*` /
  `androidboot.cpuvulkan.version` / `androidboot.opengles.version` key set. The repo's
  `tools/m0_build.py` copied the `guest_swiftshader` set — see §6 for the mismatch this implies.
- Two boot flows exist in Cuttlefish. The **direct** flow (used by crosvm and by this repo)
  passes kernel + ramdisk + bootconfig straight to the VMM. The **full-bootloader** flow boots
  U-Boot, whose Android entrypoint is `bcb load virtio 0 misc; … run bootcmd_android` (boots
  `boot.img`/`vendor_boot` per slot), with an alternative EFI path that loads
  `efi/boot/bootaa64.efi` from a virtio ESP — see
  [cf_boot_config.cc](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/main/host/commands/assemble_cvd/cf_boot_config.cc)
  (local `research/aosp-src/cf_boot_config.cc`, `kUbootBootEsp`).
- The image ships key drivers as loadable modules in the vendor ramdisk
  (`virtio_blk.ko`, `virtio_net.ko`, `virtio_pci.ko`, … — see
  `aosp_cf_arm64_only_phone-img/work/vend/fs/lib/modules/`), which is why first-stage init can
  bring up virtio block/net even when the GKI kernel lacks them built-in.
- Image-level AVB evidence (inspected directly in `images/latest-stable/`): `vbmeta.img` starts
  with the `AVB0` magic (produced by avbtool 1.4.0) and carries descriptors for `boot`,
  `init_boot`, `vbmeta_system`, `vbmeta_system_dlkm`; `fastboot-info.txt` flashes the device
  unlocked-style (`flash --apply-vbmeta vbmeta`, then boot/init_boot/vendor_boot and
  `update-super`/super). Together with the `-userdebug` build flavor (see
  `images/latest-stable/source_url.txt`), this confirms an "unlocked, boot anyway" bootconfig
  (`verifiedbootstate=orange`) matches the image's own flashing script.

---

## 5. QEMU + WHPX on Windows ARM64

Source: [QEMU — Windows Hypervisor Platform](https://www.qemu.org/docs/master/system/whpx.html)
(QEMU 11.1.50 master; same facts verified in the repo's older dumps `research/raw/qemu_whpx.rst`).

- WHPX is "the Windows API for use of third-party virtual machine monitors with hardware
  acceleration on Hyper-V"; QEMU's WHPX backend "enables using QEMU with hardware acceleration
  on **both x86_64 and arm64 Windows machines**."
- **Hard OS floor:** on arm64, **Windows 11 24H2 with the April 2025 optional updates or the
  May 2025 security updates** is the minimum. Earlier 24H2 builds shipped a pre-release WHPX
  API that QEMU does not support. Feature enablement: `HypervisorPlatform` Windows Feature
  (`DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All`). Microsoft's own page
  describes WHPX as the extended user-mode hypervisor API for third-party VMMs that coexists
  with Hyper-V-managed partitions:
  [Hyper-V APIs / Windows Hypervisor Platform](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/hypervisor-platform).
- Documented arm64 quick start:
  `qemu-system-aarch64.exe -accel whpx -M virt -cpu host … -bios edk2-aarch64-code.fd -device ramfb …`
- Graphics: "On arm64, for non-Windows guests, `-device virtio-gpu-pci` provides additional
  functionality compared to `-device ramfb`, but is incompatible with Windows' UEFI GOP
  implementation" (a Windows *guest* needs `ramfb`; an Android/Linux guest should use virtio-gpu).
- **Known arm64 limitations:** SVE and SME are not currently supported by the arm64 WHPX
  backend. (Likely a non-issue on Snapdragon X Elite — its Oryon cores implement Armv8.7-A
  without SVE — but that SoC fact is not independently sourced in this note; verify per target
  host, and it does matter for future Armv9 hosts.)

Machine model facts from [QEMU — 'virt' generic virtual platform](https://www.qemu.org/docs/master/system/arm/virt.html):

- `virt` is "the recommended board type" for guests like Linux; `-machine virt,gic-version=3`
  gives GICv3 + ITS; `highmem=on` places PCI ECAM at high addresses (ECAM base `0x4010000000`
  on highmem) and RAM at `0x4000_0000`.
- The `virt` page lists the `host` CPU type "with KVM and HVF only" — note the WHPX doc's arm64
  quick start uses `-cpu host` anyway, so the two QEMU doc pages are not fully in sync on this
  point; treat `-cpu host` under WHPX as documented-by-example and verify per release.

---

## 6. Reconciliation with this repo's pipeline

Primary-source facts vs. what the repo actually does today — discrepancies to verify, not
silently "fix" (this task is research-only):

| # | Upstream fact (source) | Repo today | Verdict |
|---|---|---|---|
| 1 | `androidboot.boot_devices=4010000000.pcie` on Linux ARM64 (qemu_manager.cpp §4.2) | `tools/m0_build.py` sets **`3f000000.pcie`** (the Apple/32-bit value) | With `-machine virt,highmem=on` the virt doc places PCI ECAM at `0x4010000000`, suggesting the guest kernel's platform device should be `4010000000.pcie`. The repo comment claims kernel logs showed `3f000000.pcie` — **verify against the guest's actual sysfs path** (`/devices/platform/*.pcie`) before trusting either value. |
| 2 | Bootconfig values are parsed literally; AOSP never quotes them (bootconfig_args.cpp.txt; kernel parsing) | `run_emulator.ps1` writes **quoted** values (`androidboot.boot_devices = "pci0000:00/0000:00:01.0"`); `tools/m0_build.py` already documents this as broken and emits unquoted | `run_emulator.ps1` is the stale pipeline; `tools/launch.sh` + `m0_build.py` is the current one. Keep one canonical launcher. |
| 3 | `fstab_suffix` must name a real suffix shipped in the first-stage ramdisk (`cf.ext4.cts`, `cf.f2fs.cts`, …) | `run_emulator.ps1` still uses the nonexistent **`cf.virtio`**; `m0_build.py` uses `cf.ext4.cts` | Another stale-launcher bug; the M0 pipeline is correct. |
| 4 | GPU bootconfig keys are **per GPU mode** (guest_swiftshader vs drm_virgl vs gfxstream — §4.2) | `m0_build.py` passes the **guest_swiftshader** key set while QEMU gets `virtio-gpu-gl-pci,venus=on` (which corresponds to upstream's virgl path) | Mixed mode: guest renders with SwiftShader while the host device tries Venus/virgl. Either switch bootconfig to the `drm_virgl` set (`androidboot.hardware.egl=mesa`, `hwcomposer=ranchu`, …) or drop the GL device. Worth an experiment, documented here rather than done. |
| 5 | Cuttlefish relies on host-side daemons it expects to find over vsock (secure_env, netsim, webrtc, …) — see `research/raw/cvd_cmd_readme.md` / assemble_cvd tree | Repo has none of them; `tools/init_wrapper.c` replaces `/init` and statically configures eth0 (`10.0.2.15/24`, gw `10.0.2.2`) because the phone image has no EthernetService/DHCP and `CONFIG_VIRTIO_NET` is a module | Correct local workaround; the wrapper's boot-#11 diagnosis comment is the authoritative in-repo record. |
| 6 | WHPX arm64 floor = Win11 24H2 + Apr/May 2025 updates (§5) | README only says "enable Windows Hypervisor Platform" | Add the OS floor to the README/prereqs; users on earlier 24H2 will fail with WHPX init errors. |

Also noted: `src-tauri/src/lib.rs` hardcodes the QEMU path and most `-device` args with
`-m 8G`-class values while `tools/launch.sh` owns the real (M0) command line — the Tauri
scaffold and the M0 launcher have drifted; only one source of truth should remain.

---

## 7. Open questions & risks

1. **Arm SystemReady specifics** (band definitions SR/ES/IR and the normative firmware/ACPI
   requirements each band imposes) could not be fetched this session — the program page was
   verified at
   [arm.com — SystemReady Certification Program](https://www.arm.com/architecture/system-architectures/systemready-certification-program),
   but the normative `developer.arm.com` documents are JS-gated and could not be quoted.
   Consequence: the native-boot row in §2 rests on the firmware-lock reality and the
   LOCKED-device model, not on the SystemReady spec text itself.
2. **Qualcomm Linux-on-Snapdragon KVM status** (whether Snapdragon X devices that *do* run
   Linux expose working KVM) is unverified this session. It determines whether the
   "Linux + KVM + launch_cvd" fallback is even reachable on this hardware family. Related and
   verified: WSL2's nested-virt path on ARM64 is itself reported broken
   ([microsoft/WSL #13796](https://github.com/microsoft/WSL/issues/13796),
   [#8821](https://github.com/microsoft/WSL/issues/8821)), so "KVM inside WSL2" is not a
   shortcut today.
3. **Android Studio Emulator on Windows ARM64 hosts:** the accel page lists Intel/AMD/Apple
   silicon processors and the release notes document Linux-ARM64 hosts only — there is no
   explicit denial, but no documented Windows-ARM64 host support either. Treat as
   unsupported/undocumented; absence is the signal.
4. **ACPI vs DeviceTree for Android on ARM64** — kernel/AOSP documentation stating which
   Android supports on server-style ARM64 platforms was not fetchable. Cuttlefish itself uses
   DT (QEMU-generated DTB per the virt doc); native SystemReady PCs are ACPI-only. This is a
   real risk for any future native-boot attempt.
5. **WHPX OS floor is a support cliff:** every user machine must be on Win11 24H2 with the
   April/May 2025 updates. No graceful fallback exists (QEMU rejects the pre-release API).
6. **16 KB page-size Cuttlefish builds** exist for ARM64 (topic:
   [16 KB page size — source.android.com](https://source.android.com/docs/core/16kb) *(exact
   page path unverified this session — nav-confirmed topic only)*) and interact with both the
   guest kernel and QEMU's memory setup — untested in this repo.
7. **crosvm + WHPX on Windows** is "tested upstream: no"
   ([crosvm book](https://crosvm.dev/book/hypervisors.html)) — attractive (it is Cuttlefish's
   default VMM) but expect to debug its Windows/arm64 path yourself.

---

## 8. Sources

Primary sources cited above:

- [QEMU — Windows Hypervisor Platform](https://www.qemu.org/docs/master/system/whpx.html)
- [QEMU — Arm System emulator (target-arm)](https://www.qemu.org/docs/master/system/target-arm.html)
- [QEMU — 'virt' generic virtual platform](https://www.qemu.org/docs/master/system/arm/virt.html)
- [Cuttlefish — landing](https://source.android.com/docs/devices/cuttlefish/landing)
- [Cuttlefish — Get started](https://source.android.com/docs/devices/cuttlefish/get-started)
- [AOSP `device/google/cuttlefish` — qemu_manager.cpp](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/main/host/libs/vm_manager/qemu_manager.cpp)
- [AOSP `device/google/cuttlefish` — cf_boot_config.cc](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/main/host/commands/assemble_cvd/cf_boot_config.cc)
- [AOSP `system/core` — first_stage_init.cpp](https://android.googlesource.com/platform/system/core/+/refs/heads/main/init/first_stage_init.cpp)
- [AOSP `system/core` — init.cpp](https://android.googlesource.com/platform/system/core/+/refs/heads/main/init/init.cpp)
- [Bootloader overview](https://source.android.com/docs/core/architecture/bootloader)
- [Boot image header](https://source.android.com/docs/core/architecture/bootloader/boot-image-header)
- [Partitions](https://source.android.com/docs/core/architecture/partitions)
- [GKI project](https://source.android.com/docs/core/architecture/kernel/generic-kernel-image)
- [Device tree overlays](https://source.android.com/docs/core/architecture/dto)
- [Verified Boot](https://source.android.com/docs/security/features/verifiedboot)
- [Verified Boot — device state](https://source.android.com/docs/security/features/verifiedboot/device-state)
- [Dynamic partitions](https://source.android.com/docs/core/ota/dynamic_partitions)
- [Hyper-V APIs / Windows Hypervisor Platform (Microsoft Learn)](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/hypervisor-platform)
- [Configure hardware acceleration for the Android Emulator](https://developer.android.com/studio/run/emulator-acceleration)
- [Android Emulator release notes](https://developer.android.com/studio/releases/emulator)
- [crosvm book — Hypervisors](https://crosvm.dev/book/hypervisors.html)
- [Microsoft Learn — Windows Subsystem for Android](https://learn.microsoft.com/en-us/windows/android/wsa/)
- [microsoft/WSL #13796 — nested virtualization on ARM](https://github.com/microsoft/WSL/issues/13796)
- [microsoft/WSL #8821 — custom kernels on ARM64](https://github.com/microsoft/WSL/issues/8821)
- [Waydroid docs](https://docs.waydro.id)
- [GloDroid](https://glodroid.github.io)
- [KonstaKANG — Android on Raspberry Pi 4](https://konstakang.com/devices/rpi4/)
- [Arm SystemReady Certification Program](https://www.arm.com/architecture/system-architectures/systemready-certification-program) *(program page verified; normative docs JS-gated)*
- [16 KB page size — source.android.com](https://source.android.com/docs/core/16kb) *(path unverified — nav-confirmed topic)*

Local copies used as citation stand-ins for AOSP sources: `research/aosp-src/qemu_manager.cpp.txt`,
`research/aosp-src/cf_boot_config.cc`, `research/aosp-src/first_stage_init.cpp`,
`research/aosp-src/bootconfig_args.cpp.txt`, and the extracted image tree under
`aosp_cf_arm64_only_phone-img/work/`.
