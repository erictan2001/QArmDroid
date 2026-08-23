//! Opcode dispatcher: turns guest-side Vulkan requests from the TCP IPC
//! channel into real host-side Vulkan calls through `HostVulkanEngine`.
//!
//! Wire protocol (host end, port 6520):
//!   request  = magic u32 ('AVKQ'), opcode u32, seq u32, payload_len u32, payload
//!   response = magic u32 ('AVKA'), opcode u32, seq u32, status i32,
//!              handles u64[4], detail_len u32, detail
//!
//! Opcode payload layouts (all little-endian):
//!   OP_CREATE_INSTANCE (1): none
//!       -> handles[0] = host instance handle
//!   OP_CREATE_DEVICE   (2): none
//!       -> handles[0] = device, handles[1] = queue, handles[2] = queue family
//!   OP_ALLOCATE_MEMORY (3): size u64 @0, flags u32 @8 (bit0: prefer host-visible)
//!       -> handles[0] = memory handle, handles[1] = chosen memory type index
//!   OP_CREATE_IMAGE    (4): width u32 @0, height u32 @4, format u32 @8, usage u32 @12
//!       -> handles[0] = image handle
//!   OP_CREATE_BUFFER   (5): size u64 @0, usage u32 @8
//!       -> handles[0] = buffer handle
//!   OP_QUEUE_SUBMIT    (6): cmd_buffer_count u32 @0 (informational; host submits 0)
//!       -> status = VK_SUCCESS after host queue idle
//!   OP_QUEUE_PRESENT   (7): present_index u32 @0
//!       -> status = VK_ERROR_OUT_OF_DATE_KHR (no WSI surface in native path;
//!          guest framebuffer presentation stays on the virtio-gpu display)
//!   OP_DESTROY_DEVICE  (8): none
//!       -> no-op: the host device is daemon-owned for its whole lifetime

use crate::vulkan_host::{
    HostVulkanEngine, VkBufferCreateInfo, VkImageCreateInfo, VkMemoryAllocateInfo, VkSubmitInfo,
    VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, VK_ERROR_INITIALIZATION_FAILED, VK_ERROR_OUT_OF_DATE_KHR,
    VK_ERROR_UNKNOWN, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_TYPE_2D,
    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, VK_IMAGE_USAGE_SAMPLED_BIT,
    VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, VK_SAMPLE_COUNT_1_BIT, VK_SHARING_MODE_EXCLUSIVE,
    VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, VK_STRUCTURE_TYPE_SUBMIT_INFO, VK_SUCCESS,
    VK_TILING_OPTIMAL,
};
use std::ptr::{null, null_mut};

pub const OP_NOP: u32 = 0;
pub const OP_CREATE_INSTANCE: u32 = 1;
pub const OP_CREATE_DEVICE: u32 = 2;
pub const OP_ALLOCATE_MEMORY: u32 = 3;
pub const OP_CREATE_IMAGE: u32 = 4;
pub const OP_CREATE_BUFFER: u32 = 5;
pub const OP_QUEUE_SUBMIT: u32 = 6;
pub const OP_QUEUE_PRESENT: u32 = 7;
pub const OP_DESTROY_DEVICE: u32 = 8;
/// Bind a (buffer, memory) pair into the render descriptor set.
pub const OP_BIND_RENDER_BUFFER: u32 = 9;
/// Dispatch a compute frame of width x height pixels into the bound buffer.
pub const OP_RENDER_FRAME: u32 = 10;
/// Map the bound memory and return the rendered pixels as response data.
pub const OP_READ_PIXELS: u32 = 11;

pub const PROTO_MAGIC_REQ: u32 = 0x514b_5641; // 'AVKQ'
pub const PROTO_MAGIC_RSP: u32 = 0x4156_4b41; // 'AVKA'
pub const PROTO_MAX_PAYLOAD: usize = 1 << 20;

// ---- payload builders -----------------------------------------------------
// Single definition per wire layout (see PROTOCOL.md). Host-side callers
// (selftest, --render) MUST use these instead of hand-packing bytes so the
// layouts have exactly one Rust definition alongside the parser below.

/// A single little-endian u32 payload.
pub fn payload_u32(v: u32) -> Vec<u8> {
    v.to_le_bytes().to_vec()
}

/// OP_ALLOCATE_MEMORY: size u64, flags u32.
pub fn payload_allocate_memory(size: u64, flags: u32) -> Vec<u8> {
    let mut p = size.to_le_bytes().to_vec();
    p.extend_from_slice(&flags.to_le_bytes());
    p
}

/// OP_CREATE_BUFFER: size u64, usage u32.
pub fn payload_create_buffer(size: u64, usage: u32) -> Vec<u8> {
    payload_allocate_memory(size, usage)
}

/// OP_CREATE_IMAGE: width u32, height u32, format u32, usage u32.
pub fn payload_create_image(width: u32, height: u32, format: u32, usage: u32) -> Vec<u8> {
    let mut p = width.to_le_bytes().to_vec();
    p.extend_from_slice(&height.to_le_bytes());
    p.extend_from_slice(&format.to_le_bytes());
    p.extend_from_slice(&usage.to_le_bytes());
    p
}

/// OP_BIND_RENDER_BUFFER: buffer handle u64, memory handle u64.
pub fn payload_bind_render_buffer(buffer_handle: u64, memory_handle: u64) -> Vec<u8> {
    let mut p = buffer_handle.to_le_bytes().to_vec();
    p.extend_from_slice(&memory_handle.to_le_bytes());
    p
}

/// OP_RENDER_FRAME: width u32, height u32.
pub fn payload_render_frame(width: u32, height: u32) -> Vec<u8> {
    let mut p = width.to_le_bytes().to_vec();
    p.extend_from_slice(&height.to_le_bytes());
    p
}

/// OP_READ_PIXELS: byte size u64.
pub fn payload_read_pixels(byte_size: u64) -> Vec<u8> {
    byte_size.to_le_bytes().to_vec()
}

pub fn opcode_name(op: u32) -> &'static str {
    match op {
        OP_NOP => "Nop",
        OP_CREATE_INSTANCE => "CreateInstance",
        OP_CREATE_DEVICE => "CreateDevice",
        OP_ALLOCATE_MEMORY => "AllocateMemory",
        OP_CREATE_IMAGE => "CreateImage",
        OP_CREATE_BUFFER => "CreateBuffer",
        OP_QUEUE_SUBMIT => "QueueSubmit",
        OP_QUEUE_PRESENT => "QueuePresent",
        OP_DESTROY_DEVICE => "DestroyDevice",
        OP_BIND_RENDER_BUFFER => "BindRenderBuffer",
        OP_RENDER_FRAME => "RenderFrame",
        OP_READ_PIXELS => "ReadPixels",
        _ => "Unknown",
    }
}

#[derive(Debug, Clone)]
pub struct DispatchResult {
    pub status: i32,
    pub handles: [u64; 4],
    pub detail: String,
    /// Optional binary payload returned to the caller (e.g. rendered pixels).
    pub data: Vec<u8>,
}

impl DispatchResult {
    pub fn ok(detail: impl Into<String>) -> Self {
        Self { status: VK_SUCCESS, handles: [0; 4], detail: detail.into(), data: Vec::new() }
    }
    pub fn err(status: i32, detail: impl Into<String>) -> Self {
        Self { status, handles: [0; 4], detail: detail.into(), data: Vec::new() }
    }
}

fn rd_u32(p: &[u8], off: usize) -> Option<u32> {
    let b = p.get(off..off + 4)?;
    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn rd_u64(p: &[u8], off: usize) -> Option<u64> {
    let b = p.get(off..off + 8)?;
    Some(u64::from_le_bytes([
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
    ]))
}

/// Execute one guest opcode against the (already probed) host engine.
pub fn dispatch(engine: &HostVulkanEngine, opcode: u32, payload: &[u8]) -> DispatchResult {
    match opcode {
        OP_CREATE_INSTANCE => {
            // The daemon probes and holds the instance; hand the guest its handle.
            let h = engine.instance as usize as u64;
            let mut r = DispatchResult::ok("host instance (created during daemon probe)");
            r.handles[0] = h;
            r
        }

        OP_CREATE_DEVICE => {
            if !engine.device.is_null() && !engine.queue.is_null() {
                let mut r = DispatchResult::ok("host device + queue (created during daemon probe)");
                r.handles[0] = engine.device as usize as u64;
                r.handles[1] = engine.queue as usize as u64;
                r.handles[2] = engine.queue_family_index as u64;
                r
            } else {
                DispatchResult::err(VK_ERROR_INITIALIZATION_FAILED as i32, "host device was not created during probe")
            }
        }

        OP_ALLOCATE_MEMORY => {
            let size = match rd_u64(payload, 0) {
                Some(s) if s > 0 => s,
                _ => return DispatchResult::err(VK_ERROR_UNKNOWN, "AllocateMemory: malformed payload (need size u64 @0)"),
            };
            let flags = rd_u32(payload, 8).unwrap_or(0);
            let prefer_host = flags & 1 != 0;

            let mut mem_props: crate::vulkan_host::VkPhysicalDeviceMemoryProperties;
            unsafe {
                mem_props = std::mem::zeroed();
                (engine.ext.vk_get_physical_device_memory_properties)(
                    engine.physical_device,
                    &mut mem_props,
                );
            }
            let want = if prefer_host {
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
            } else {
                VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
            };
            let mut type_index: Option<u32> = None;
            for i in 0..mem_props.memory_type_count as usize {
                if mem_props.memory_types[i].property_flags & want == want {
                    type_index = Some(i as u32);
                    break;
                }
            }
            let type_index = match type_index {
                Some(t) => t,
                None => {
                    return DispatchResult::err(
                        VK_ERROR_UNKNOWN,
                        format!("AllocateMemory: no memory type with required flags 0x{want:x}"),
                    )
                }
            };

            let ai = VkMemoryAllocateInfo {
                s_type: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                p_next: null(),
                allocation_size: size,
                memory_type_index: type_index,
            };
            let mut memory: crate::vulkan_host::VkDeviceMemory = null_mut();
            let status = unsafe {
                (engine.ext.vk_allocate_memory)(engine.device, &ai, null(), &mut memory)
            };
            if status != VK_SUCCESS || memory.is_null() {
                return DispatchResult::err(
                    status,
                    format!("AllocateMemory({size} bytes, type {type_index}) failed"),
                );
            }
            let mut r = DispatchResult::ok(format!("allocated {size} bytes on memory type {type_index}"));
            r.handles[0] = memory as usize as u64;
            r.handles[1] = type_index as u64;
            r
        }

        OP_CREATE_BUFFER => {
            let size = match rd_u64(payload, 0) {
                Some(s) if s > 0 => s,
                _ => return DispatchResult::err(VK_ERROR_UNKNOWN, "CreateBuffer: malformed payload (need size u64 @0)"),
            };
            let usage = rd_u32(payload, 8).unwrap_or(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

            let ci = VkBufferCreateInfo {
                s_type: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                p_next: null(),
                flags: 0,
                size,
                usage,
                sharing_mode: VK_SHARING_MODE_EXCLUSIVE,
                queue_family_index_count: 0,
                p_queue_family_indices: null(),
            };
            let mut buffer: crate::vulkan_host::VkBuffer = null_mut();
            let status = unsafe { (engine.ext.vk_create_buffer)(engine.device, &ci, null(), &mut buffer) };
            if status != VK_SUCCESS || buffer.is_null() {
                return DispatchResult::err(status, format!("CreateBuffer({size} bytes, usage 0x{usage:x}) failed"));
            }
            let mut r = DispatchResult::ok(format!("created buffer {size} bytes usage 0x{usage:x}"));
            r.handles[0] = buffer as usize as u64;
            r
        }

        OP_CREATE_IMAGE => {
            let (w, h, format, usage) = match (rd_u32(payload, 0), rd_u32(payload, 4), rd_u32(payload, 8), rd_u32(payload, 12)) {
                (Some(w), Some(h), Some(f), Some(u)) if w > 0 && h > 0 => (w, h, f, u),
                _ => {
                    return DispatchResult::err(
                        VK_ERROR_UNKNOWN,
                        "CreateImage: malformed payload (need width/height/format/usage u32s)",
                    )
                }
            };
            let ci = VkImageCreateInfo {
                s_type: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                image_type: VK_IMAGE_TYPE_2D,
                format,
                extent: crate::vulkan_host::VkExtent3D { width: w, height: h, depth: 1 },
                mip_levels: 1,
                array_layers: 1,
                samples: VK_SAMPLE_COUNT_1_BIT,
                tiling: VK_TILING_OPTIMAL,
                usage,
                sharing_mode: VK_SHARING_MODE_EXCLUSIVE,
                queue_family_index_count: 0,
                p_queue_family_indices: null(),
                initial_layout: VK_IMAGE_LAYOUT_UNDEFINED,
            };
            let mut image: crate::vulkan_host::VkImage = null_mut();
            let status = unsafe { (engine.ext.vk_create_image)(engine.device, &ci, null(), &mut image) };
            if status != VK_SUCCESS || image.is_null() {
                return DispatchResult::err(
                    status,
                    format!("CreateImage({w}x{h}, format {format}, usage 0x{usage:x}) failed"),
                );
            }
            let mut r = DispatchResult::ok(format!("created 2D image {w}x{h} format {format}"));
            r.handles[0] = image as usize as u64;
            r
        }

        OP_QUEUE_SUBMIT => {
            // The guest reports how many command buffers it believes it queued;
            // the host submits an empty batch and waits for the queue to drain —
            // this is what makes guest-side fence/sync bookkeeping correct.
            let _reported = rd_u32(payload, 0).unwrap_or(0);
            let si = VkSubmitInfo {
                s_type: VK_STRUCTURE_TYPE_SUBMIT_INFO,
                p_next: null(),
                wait_semaphore_count: 0,
                p_wait_semaphores: null(),
                p_wait_dst_stage_mask: null(),
                command_buffer_count: 0,
                p_command_buffers: null(),
                signal_semaphore_count: 0,
                p_signal_semaphores: null(),
            };
            let status = unsafe { (engine.ext.vk_queue_submit)(engine.queue, 1, &si, null_mut()) };
            if status != VK_SUCCESS {
                return DispatchResult::err(status, "QueueSubmit: vkQueueSubmit failed");
            }
            let idle = unsafe { (engine.ext.vk_queue_wait_idle)(engine.queue) };
            if idle != VK_SUCCESS {
                return DispatchResult::err(idle, "QueueSubmit: vkQueueWaitIdle failed");
            }
            DispatchResult::ok("submitted empty batch; host queue is idle")
        }

        OP_QUEUE_PRESENT => {
            // Presentation on the native path requires a WSI surface that does
            // not exist in this passthrough model: the guest composits to its
            // virtio-gpu framebuffer, which the host mirrors (e.g. via scrcpy).
            DispatchResult::err(
                VK_ERROR_OUT_OF_DATE_KHR,
                "QueuePresent: no WSI surface on native Vulkan passthrough; \
                 guest presentation happens on the virtio-gpu display path",
            )
        }

        OP_DESTROY_DEVICE => DispatchResult::ok("host device is daemon-owned; destroy is a no-op"),

        OP_BIND_RENDER_BUFFER => {
            // payload: bufferHandle u64 @0, memoryHandle u64 @8
            let (buffer, memory) = match (rd_u64(payload, 0), rd_u64(payload, 8)) {
                (Some(b), Some(m)) if b != 0 && m != 0 => (b, m),
                _ => {
                    return DispatchResult::err(
                        VK_ERROR_UNKNOWN,
                        "BindRenderBuffer: malformed payload (need buffer u64 @0, memory u64 @8)",
                    )
                }
            };
            let mut guard = match engine.render.lock() {
                Ok(g) => g,
                Err(_) => return DispatchResult::err(VK_ERROR_UNKNOWN, "render pipeline lock poisoned"),
            };
            let rp = match guard.as_mut() {
                Some(rp) => rp,
                None => {
                    return DispatchResult::err(
                        VK_ERROR_INITIALIZATION_FAILED,
                        "render pipeline not initialized",
                    )
                }
            };
            match rp.bind_buffer(buffer, memory) {
                Ok(()) => {
                    let mut r = DispatchResult::ok("buffer bound into render descriptor set");
                    r.handles[0] = buffer;
                    r.handles[1] = memory;
                    r
                }
                Err(e) => DispatchResult::err(VK_ERROR_UNKNOWN, e),
            }
        }

        OP_RENDER_FRAME => {
            // payload: width u32 @0, height u32 @4
            let (w, h) = match (rd_u32(payload, 0), rd_u32(payload, 4)) {
                (Some(w), Some(h)) if w > 0 && h > 0 => (w, h),
                _ => {
                    return DispatchResult::err(
                        VK_ERROR_UNKNOWN,
                        "RenderFrame: malformed payload (need width u32 @0, height u32 @4)",
                    )
                }
            };
            let mut guard = match engine.render.lock() {
                Ok(g) => g,
                Err(_) => return DispatchResult::err(VK_ERROR_UNKNOWN, "render pipeline lock poisoned"),
            };
            let rp = match guard.as_mut() {
                Some(rp) => rp,
                None => {
                    return DispatchResult::err(
                        VK_ERROR_INITIALIZATION_FAILED,
                        "render pipeline not initialized",
                    )
                }
            };
            match rp.render_frame(w, h) {
                Ok(()) => {
                    let mut r = DispatchResult::ok(format!(
                        "dispatched compute frame {w}x{h}; queue idle",
                    ));
                    r.handles[0] = (w as u64) << 32 | h as u64;
                    r
                }
                Err(e) => DispatchResult::err(VK_ERROR_UNKNOWN, e),
            }
        }

        OP_READ_PIXELS => {
            // payload: size u64 @0 (bytes to read from the bound memory)
            let size = match rd_u64(payload, 0) {
                Some(s) if s > 0 && s <= (256 * 1024 * 1024) => s,
                _ => {
                    return DispatchResult::err(
                        VK_ERROR_UNKNOWN,
                        "ReadPixels: malformed payload (need size u64 @0, 1..=256MiB)",
                    )
                }
            };
            let mut guard = match engine.render.lock() {
                Ok(g) => g,
                Err(_) => return DispatchResult::err(VK_ERROR_UNKNOWN, "render pipeline lock poisoned"),
            };
            let rp = match guard.as_mut() {
                Some(rp) => rp,
                None => {
                    return DispatchResult::err(
                        VK_ERROR_INITIALIZATION_FAILED,
                        "render pipeline not initialized",
                    )
                }
            };
            match rp.read_pixels(size) {
                Ok(bytes) => {
                    let mut r = DispatchResult::ok(format!("read back {} bytes", bytes.len()));
                    r.data = bytes;
                    r
                }
                Err(e) => DispatchResult::err(VK_ERROR_UNKNOWN, e),
            }
        }

        _ => DispatchResult::err(VK_ERROR_UNKNOWN, format!("unknown opcode {opcode}")),
    }
}

// Keep the format-constant imports used by callers compiling against a guest
// that picks defaults (e.g. self-test/guest client can reference these).
pub const DEFAULT_IMAGE_FORMAT: u32 = VK_FORMAT_R8G8B8A8_UNORM;
pub const DEFAULT_IMAGE_USAGE: u32 =
    VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;