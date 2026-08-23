# hcs_engine Vulkan Passthrough — Wire Protocol v1

Single source of truth for the guest↔host Vulkan passthrough protocol.
Implementations that must stay conformant:

| Role | File |
|---|---|
| Host dispatcher (authoritative parser) | `src/dispatch.rs` |
| Reference encoder / test client | `../vk_passthrough_client.py` |
| Guest C client (freestanding, raw syscalls) | `../vk_guest_client.c` |

If any implementation drifts from this document, fix the code — not the doc.

## Transport

- TCP. Daemon listens on `127.0.0.1:6520` (`hcs_engine --serve`).
- Guest reaches it via QEMU slirp gateway: `10.0.2.2:6520`.
- One request → one response per connection is allowed; clients MAY pipeline
  on one stream (dispatcher handles sequentially).

## Frame layout (little-endian throughout)

```
request : magic u32 = 0x514B5641 ('AVKQ')
          opcode u32
          seq    u32            # echoed verbatim in response
          payload_len u32       # ≤ PROTO_MAX_PAYLOAD (1 MiB)
          payload[payload_len]

response: magic u32 = 0x41564B41 ('AVKA')
          opcode u32           # same as request
          seq    u32
          status i32           # VK_* result code (0 = VK_SUCCESS)
          handles u64[4]       # meaning per opcode below; unused = 0
          detail_len u32
          detail[detail_len]   # e.g. OP_READ_PIXELS pixel data
```

## Opcodes

| # | Name | Payload in | Response handles / notes |
|---|------|-----------|--------------------------|
| 0  | `NOP`               | — | status only; liveness probe |
| 1  | `CREATE_INSTANCE`   | — | h0 = instance |
| 2  | `CREATE_DEVICE`     | — | h0 = device, h1 = queue, h2 = queue family |
| 3  | `ALLOCATE_MEMORY`   | size u64 @0, flags u32 @8 (bit0 prefer host-visible) | h0 = memory, h1 = memory-type index |
| 4  | `CREATE_IMAGE`      | width u32 @0, height u32 @4, format u32 @8, usage u32 @12 | h0 = image |
| 5  | `CREATE_BUFFER`     | size u64 @0, usage u32 @8 | h0 = buffer |
| 6  | `QUEUE_SUBMIT`      | cmd_buffer_count u32 @0 (informational) | host submits an empty submit then waits idle |
| 7  | `QUEUE_PRESENT`     | present_index u32 @0 | returns `VK_ERROR_OUT_OF_DATE_KHR` — no WSI surface; guest presentation stays on virtio-gpu |
| 8  | `DESTROY_DEVICE`    | — | no-op: device is daemon-owned for its lifetime |
| 9  | `BIND_RENDER_BUFFER`| buffer handle u64 @0, memory handle u64 @8 | binds pair into the render descriptor set |
| 10 | `RENDER_FRAME`      | width u32 @0, height u32 @4 | dispatches compute frame into bound buffer |
| 11 | `READ_PIXELS`       | width u32 @0, height u32 @4 | detail = RGBA8888 pixels, row-major, top-left origin |

Formats: images/buffers use `VK_FORMAT_R8G8B8A8_UNORM`; render target is a
storage buffer addressed as `image2D(u32)`-equivalent layout by the compute
pipeline (see `src/render.rs`).

## Known limitations (v1)

- Single device/instance per daemon lifetime (opcodes 1/2/8 are bookkeeping).
- No free/delete opcodes — resources live until daemon exit.
- `QUEUE_PRESENT` never succeeds: there is no WSI surface in the daemon.
- The shared-memory `--aperture` transport named in older docs is **removed**;
  TCP is the only transport.
