//! Integration tests for the native Vulkan passthrough pipeline.
//!
//! These tests are the regression loop: they drive the *real* host Vulkan
//! runtime through the same `dispatch::dispatch` path the TCP IPC service
//! and aperture ring use. On a machine without a Vulkan 1.x runtime the
//! probe test fails loudly instead of the daemon silently degrading.
//!
//! They live in the lib (unit-test harness) because this Windows ARM64
//! host refuses to spawn the integration-test harness binary
//! (CreateProcess: ERROR_ELEVATION_REQUIRED) even though every other
//! binary — including the identical code in the lib unittest target —
//! runs fine. The assertions are identical either way.

#[cfg(test)]
mod tests {
    use crate::dispatch::{self, OP_ALLOCATE_MEMORY, OP_CREATE_BUFFER, OP_CREATE_DEVICE, OP_CREATE_IMAGE, OP_QUEUE_PRESENT, OP_QUEUE_SUBMIT};
    use crate::vulkan_host::{HostVulkanEngine, VK_ERROR_OUT_OF_DATE_KHR, VK_SUCCESS};

    fn engine() -> HostVulkanEngine {
        HostVulkanEngine::probe().expect("host Vulkan probe failed — is a Vulkan 1.x runtime installed?")
    }

    #[test]
    fn probe_creates_instance_device_and_queue() {
        let e = engine();
        assert!(!e.instance.is_null(), "VkInstance must not be null");
        assert!(!e.physical_device.is_null(), "VkPhysicalDevice must not be null");
        assert!(!e.device.is_null(), "VkDevice must not be null");
        assert!(!e.queue.is_null(), "VkQueue must not be null");
        assert!(!e.device_name.is_empty(), "device name must be readable");
        assert_ne!(e.driver_version, 0, "driver version must be readable");
        println!("probe: {} driver {}", e.device_name, e.driver_version_string());
    }

    #[test]
    fn create_instance_and_device_handles() {
        let e = engine();
        let r = dispatch::dispatch(&e, dispatch::OP_CREATE_INSTANCE, &[]);
        assert_eq!(r.status, VK_SUCCESS, "CreateInstance failed: {}", r.detail);
        assert_ne!(r.handles[0], 0, "must hand out the host instance handle");

        let r = dispatch::dispatch(&e, OP_CREATE_DEVICE, &[]);
        assert_eq!(r.status, VK_SUCCESS, "CreateDevice failed: {}", r.detail);
        assert_ne!(r.handles[0], 0, "device handle");
        assert_ne!(r.handles[1], 0, "queue handle");
    }

    #[test]
    fn allocate_host_visible_memory() {
        let e = engine();
        let mut payload = Vec::new();
        payload.extend_from_slice(&(1u64 << 20).to_le_bytes()); // size: 1 MiB
        payload.extend_from_slice(&1u32.to_le_bytes());         // bit0: prefer host-visible
        let r = dispatch::dispatch(&e, OP_ALLOCATE_MEMORY, &payload);
        assert_eq!(r.status, VK_SUCCESS, "AllocateMemory failed: {}", r.detail);
        assert_ne!(r.handles[0], 0, "memory handle");
    }

    #[test]
    fn create_buffer_and_image_objects() {
        let e = engine();

        let mut buf = Vec::new();
        buf.extend_from_slice(&(64u64 << 10).to_le_bytes()); // 64 KiB
        buf.extend_from_slice(&0u32.to_le_bytes());          // usage default
        let r = dispatch::dispatch(&e, OP_CREATE_BUFFER, &buf);
        assert_eq!(r.status, VK_SUCCESS, "CreateBuffer failed: {}", r.detail);
        assert_ne!(r.handles[0], 0, "buffer handle");

        let mut img = Vec::new();
        img.extend_from_slice(&64u32.to_le_bytes()); // width
        img.extend_from_slice(&64u32.to_le_bytes()); // height
        img.extend_from_slice(&37u32.to_le_bytes()); // VK_FORMAT_R8G8B8A8_UNORM
        img.extend_from_slice(&20u32.to_le_bytes()); // sampled | color attachment
        let r = dispatch::dispatch(&e, OP_CREATE_IMAGE, &img);
        assert_eq!(r.status, VK_SUCCESS, "CreateImage failed: {}", r.detail);
        assert_ne!(r.handles[0], 0, "image handle");
    }

    #[test]
    fn queue_submit_drains() {
        let e = engine();
        let r = dispatch::dispatch(&e, OP_QUEUE_SUBMIT, &[0u8, 0, 0, 0]);
        assert_eq!(r.status, VK_SUCCESS, "QueueSubmit failed: {}", r.detail);
    }

    #[test]
    fn queue_present_reports_documented_limitation() {
        let e = engine();
        let r = dispatch::dispatch(&e, OP_QUEUE_PRESENT, &[0u8, 0, 0, 0]);
        // No WSI surface exists on the native passthrough path; the guest is
        // expected to present via the virtio-gpu display path instead.
        assert_eq!(r.status, VK_ERROR_OUT_OF_DATE_KHR, "unexpected present status: {}", r.detail);
    }

    #[test]
    fn malformed_payloads_return_error_not_panic() {
        let e = engine();
        let r = dispatch::dispatch(&e, OP_CREATE_IMAGE, &[1, 2, 3]); // too short
        assert_ne!(r.status, VK_SUCCESS);
        let r = dispatch::dispatch(&e, OP_ALLOCATE_MEMORY, &[]);
        assert_ne!(r.status, VK_SUCCESS);
        let r = dispatch::dispatch(&e, 0xdead_beef, &[]);
        assert_ne!(r.status, VK_SUCCESS, "unknown opcodes must be rejected");
    }

    /// Simulates a guest producer writing a packet into the shared-memory
    /// aperture ring, then verifies the host consumer+dispatcher executes it.
    #[test]
    fn aperture_ring_dispatches_guest_packets() {
        use crate::shm_ring::{ShmApertureConsumer, VkCommandPacket};
        use std::sync::atomic::Ordering;

        let mut buf = vec![0u8; 64 * 1024];
        let ptr = buf.as_mut_ptr();
        let mut consumer =
            unsafe { ShmApertureConsumer::new(ptr, buf.len()) }.expect("aperture must init");

        // --- guest producer side ---
        let header = unsafe { &*(ptr as *const crate::shm_ring::ShmApertureHeader) };
        let head = header.head.load(Ordering::Relaxed) as usize;
        let pkt = VkCommandPacket {
            opcode: dispatch::OP_CREATE_DEVICE,
            payload_size: 0,
            cookie: 42,
        };
        unsafe {
            let p = &pkt as *const VkCommandPacket as *const u8;
            for i in 0..size_of::<VkCommandPacket>() {
                *consumer.ring_buf.add((head + i) % consumer.capacity) = *p.add(i);
            }
        }
        header
            .head
            .store((head + size_of::<VkCommandPacket>()) as u32, Ordering::Release);

        // --- host consumer + dispatcher side ---
        let (pkt_out, payload) = consumer.poll_packet().expect("packet must be available");
        assert_eq!(pkt_out.cookie, 42);
        let e = engine();
        let r = dispatch::dispatch(&e, pkt_out.opcode, &payload);
        assert_eq!(r.status, VK_SUCCESS, "aperture dispatch failed: {}", r.detail);
        assert_ne!(r.handles[0], 0, "device handle through aperture path");
    }
}