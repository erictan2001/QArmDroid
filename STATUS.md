# STATUS — Arm64AndroidEmulator

Single source of truth for the current state of this project.
Historical session documents live in `DEVELOPMENT_LOG.md`, `PERFORMANCE.md`,
`PROJECT_REPORT.md` and `research/`; where they contradict this file,
**this file wins**.

## What works today

| Feature | Status | Notes |
|---|---|---|
| Android 16 ARM64 boot | ✅ | QEMU + WHPX, ~2–4 min to `sys.boot_completed=1` |
| Launch entry point | ✅ | **`tools\launch.ps1` only** — all other launchers deleted |
| Windowed display (sdl/gtk) | ✅ | Auto-switches to msys2 QEMU (custom build is headless-only); GPU falls back to basic |
| USB keyboard + mouse | ✅ | Windowed display modes; verified via getevent |
| adb over TCP | ✅ | `adb connect 127.0.0.1:5555` |
| Touch via adb / scrcpy | ✅ | scrcpy capped at 30 fps / 960p / 2M (measured optimum) |
| Resolution | ✅ | 1280×800 enforced by post-boot watchdog |
| GPU passthrough (gfxstream) | ⚠️ blocked | Boots & initializes Adreno X1-85; in-guest rendering stays SwiftShader |

## Rendering performance (measured)

- **~10–11 FPS**: SwiftShader CPU composition ceiling at 1280×800 (see PERFORMANCE.md).
- GPU passthrough boots but does not yet accelerate frames — see blocker below.

## The one open blocker

gfxstream needs a host Vulkan driver exposing
`VK_KHR_external_memory_win32`. Current native Qualcomm Adreno driver
(v0.863.0, branch pp165) exposes the core `VK_KHR_external_memory`
extension but **not** the win32 handle type, so cross-process GPU buffer
sharing fails and gfxstream falls back to non-accelerated mode.
Evidence: `research/docs/vulkaninfo-adreno-x1-85-driver-0.855.json`.
When Qualcomm ships the handle type, no code changes should be needed:
boot with default `-GpuMode gfxstream`.

## Canonical launch

```powershell
tools\launch.ps1                    # headless (GUI/scrcpy default)
tools\launch.ps1 -DisplayMode gtk   # windowed, USB keyboard+mouse
tools\launch.ps1 -PrintArgs         # inspect resolved QEMU argv, no boot
```

Parameters: `-DisplayMode none|scrcpy|embedded|vnc|gtk|sdl`,
`-GpuMode gfxstream|basic`, `-Memory 6G`, `-Cores 6`.

## Layout rules (post-cleanup)

- `tools/` holds only what a fresh boot or build invokes.
- MuMu reverse-engineering scripts: `research/scripts-mumu-re/`.
- Screenshots/render artifacts: `research/artifacts/`.
- Driver-capability evidence: `research/docs/`.
- Custom QEMU/gfxstream build environment: `tools/qemu-gfxstream/`
  (see its BUILD_STATUS.md for why gfxstream is platform-blocked).


## Known follow-ups (deferred by design)

- **Topology constants** (ports 5555/6520/6666, 1280x800, slirp IPs) still
  live as literals across launch.ps1 / src-tauri / m0_build.py. Candidate:
  emit `topology.json` from m0_build.py and read it in both consumers.
  Deferred until a second real consumer of the values appears.
- scrcpy stream flags are canonical in `src-tauri/src/lib.rs`; the removed
  `start_scrcpy.ps1` duplicate may be re-created only if it reads those
  consts rather than re-hardcoding them.
