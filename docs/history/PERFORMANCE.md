# Emulator UI performance: diagnosis & roadmap (2026-08)

## What the user sees
"UI in the guest (scrcpy) is much slower than the previous implementation
without Vulkan — MuMu ARM64 reaches 60 FPS at high resolution."

## Measured facts (this machine, running VM)

| Measurement | Result |
|---|---|
| `hcs_engine` daemon CPU (8s window) | 0.02 s (≈ 0%) — idle |
| Daemon in GPU engine counters | absent (GPU util 5.5% is Edge) |
| scrcpy stream, daemon ON vs OFF (10 s, same motion) | 112 vs 115 frames — **identical** |
| QEMU CPU share | swings 12%–121% of a core, not daemon-correlated |
| Guest CPU while UI motion | SurfaceFlinger ≈ 52% of one core (SwiftShader) |
| Guest SF active refresh under load | 37.5 Hz (26.7 ms period) |
| scrcpy 960p/60fps/4M delivered | ≈ 11 fps under full motion |
| scrcpy 800p/30fps/2M delivered | ≈ 13 fps (still encode-bound) |

**Conclusion:** the Vulkan passthrough daemon is *not* the cause — no measurable
mechanism (0% CPU, 0% GPU, identical A/B streams). The real ceiling is the
guest's software graphics path, unchanged by the passthrough work.

## Root cause chain (why 11 fps, and why MuMu gets 60)

1. The AOSP image declares `ro.hardware.vulkan=pastel` and ships the HALs in
   the `com.google.cf.vulkan` apex (`vulkan.pastel.so`, `vulkan.ranchu.so`,
   `libOpenglCodecCommon.so`) — confirmed present in the guest.
2. Those HALs speak the **gfxstream virtio-gpu transport** (context-init +
   blob resources + a host-side renderer). Our QEMU (msys64 clangarm64 11.0.0)
   has plain `virtio-gpu` and `virtio-gpu-gl` (virgl) but **no rutabaga /
   gfxstream backend**: `-device help` lists no `virtio-gpu-rutabaga`,
   `-object help` lists no rutabaga.
3. Result in guest logcat: `ANGLE Warn: vulkan_icd.cpp:388 ... Preferred
   device ICD not found` → ANGLE falls back to its bundled **SwiftShader**
   (CPU rendering) for ALL guest GLES/Vulkan.
4. The visible display goes through scrcpy = guest **software H264 encode**
   (c2.android.avc) — another CPU wall at ≈ 11 fps.
5. MuMu ships its own QEMU with the gfxstream host renderer
   (`libRenderer.dll`), so its guests render on the host GPU and present
   without an encode wall → 60 fps at high resolution.

## Fixes already shipped

- `launch.ps1` / `launch_vulkan.ps1`: default vCPUs 4 → **6** (SwiftShader
  composition and the software encoder scale with vCPUs).
- `start_scrcpy.ps1`: 60fps/4M → **30fps/2M** stable cap (smoother stream
  than a saturated encoder).
- Scrcpy is only a convenience windowing layer: for *smooth* UI use the
  zero-encode display instead.

## Using the smooth path now

The guest composes at 37–75 Hz; the H264 encoder is what cuts it to 11 fps.
`-DisplayMode sdl` (supported by this QEMU, SDL2.dll present) shows the
virtio-gpu framebuffer **directly**, no encoder:

```powershell
powershell -ExecutionPolicy Bypass -File tools\launch.ps1 -DisplayMode sdl
```

`vnc` (`vnc=127.0.0.1:0,websocket=5901,lossy=off`) is the network variant.

## The MuMu-class fix (proper 60 fps @ high res)

Guest GPU acceleration requires a gfxstream-capable host. Roadmap:

1. **QEMU + gfxstream (rutabaga) for aarch64 Windows.** Build QEMU 11 with
   `--enable-gfxstream`/rutabaga (meson subproject `rutabaga_gfx`, Rust via
   cargo — toolchain already present). Then the guest's `vulkan.pastel.so`
   initializes, ANGLE renders through the host Adreno GPU, and guest Vulkan
   apps work natively — MuMu-level throughput.
2. Alternative: pull the Google Android Emulator arm64-windows package
   (`emulator` cmdline package; SDK manager) whose QEMU bundles gfxstream,
   and drive our Cuttlefish machine config through it.
3. Once guest Vulkan is live, guest apps can also choose the passthrough
   daemon (`10.0.2.2:6520`) for host-GPU compute/rendering via the protocol
   in `tools/hcs_engine/src/dispatch.rs`.

## Verification commands (re-run after any change)

```powershell
# stream FPS (daemon state irrelevant — A/B proven equal)
cd tools\scrcpy
.\scrcpy.exe -s 127.0.0.1:5555 --no-window --record "$env:TEMP\t.mp4" `
  --video-codec=h264 --max-size=960 --max-fps=60 --no-audio --time-limit=10
python ..\mp4_frames.py "$env:TEMP\t.mp4"   # frames/10s
```