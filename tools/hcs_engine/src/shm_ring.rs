//! Shared-memory aperture ring buffer between the guest and the host
//! Vulkan daemon.
//!
//! The guest writes `VkCommandPacket` headers + payloads and advances
//! `head`; the host consumer advances `tail`. This is the *legacy*
//! in-process simulation path (see `--aperture`): the primary transport is
//! the TCP IPC service on 127.0.0.1:6520, which guests reach through the
//! QEMU slirp gateway at 10.0.2.2.

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

#[repr(C, align(64))]
pub struct ShmApertureHeader {
    pub magic: u32,             // 0x564B534D ('VKSM')
    pub version: u32,           // 1
    pub total_size: u64,        // Total aperture size in bytes
    pub ring_offset: u64,       // Offset to ring buffer from base
    pub ring_capacity: u32,     // Capacity of ring in bytes
    pub head: AtomicU32,        // Written by Producer (Guest)
    pub tail: AtomicU32,        // Read by Consumer (Host)
    pub flags: AtomicU32,       // Status & control flags
    pub sequence_num: AtomicU64,// Frame / command sequence counter
}

pub const SHM_MAGIC: u32 = 0x564B534D; // 'VKSM' (Vulkan Shared Memory)
pub const SHM_FLAG_READY: u32 = 1 << 0;
pub const SHM_FLAG_HOST_ACTIVE: u32 = 1 << 1;
pub const SHM_FLAG_GUEST_ACTIVE: u32 = 1 << 2;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct VkCommandPacket {
    pub opcode: u32,
    pub payload_size: u32,
    pub cookie: u64,
}

/// Guest opcodes mirror the wire protocol in `dispatch.rs`.
#[allow(dead_code)]
pub enum VkOpcode {
    Nop = 0,
    CreateInstance = 1,
    CreateDevice = 2,
    AllocateMemory = 3,
    CreateImage = 4,
    CreateBuffer = 5,
    QueueSubmit = 6,
    QueuePresent = 7,
    DestroyDevice = 8,
}

pub struct ShmApertureConsumer {
    pub base_ptr: *mut u8,
    pub header: *mut ShmApertureHeader,
    pub ring_buf: *mut u8,
    pub capacity: usize,
}

// The consumer is moved into a single daemon thread that owns it exclusively;
// all pointer accesses are confined to that thread, so Send is sound here.
unsafe impl Send for ShmApertureConsumer {}

impl ShmApertureConsumer {
    /// # Safety
    /// `base_ptr` must point to a buffer of at least `size` bytes that stays
    /// alive for the lifetime of the returned consumer.
    pub unsafe fn new(base_ptr: *mut u8, size: usize) -> Option<Self> {
        if size < size_of::<ShmApertureHeader>() + 1024 {
            return None;
        }

        unsafe {
            let header = base_ptr as *mut ShmApertureHeader;
            // Initialize header
            (*header).magic = SHM_MAGIC;
            (*header).version = 1;
            (*header).total_size = size as u64;
            let ring_offset = size_of::<ShmApertureHeader>() as u64;
            let ring_capacity = (size - size_of::<ShmApertureHeader>()) as u32;
            (*header).ring_offset = ring_offset;
            (*header).ring_capacity = ring_capacity;
            (*header).head.store(0, Ordering::Release);
            (*header).tail.store(0, Ordering::Release);
            (*header).flags.store(SHM_FLAG_READY | SHM_FLAG_HOST_ACTIVE, Ordering::Release);
            (*header).sequence_num.store(0, Ordering::Release);

            let ring_buf = base_ptr.add(ring_offset as usize);

            Some(Self {
                base_ptr,
                header,
                ring_buf,
                capacity: ring_capacity as usize,
            })
        }
    }

    pub fn poll_packet(&mut self) -> Option<(VkCommandPacket, Vec<u8>)> {
        unsafe {
            let head = (*self.header).head.load(Ordering::Acquire);
            let tail = (*self.header).tail.load(Ordering::Relaxed);

            if head == tail {
                return None; // Ring empty
            }

            let available = if head >= tail {
                (head - tail) as usize
            } else {
                self.capacity - (tail - head) as usize
            };

            let hdr_size = size_of::<VkCommandPacket>();
            if available < hdr_size {
                return None;
            }

            // Read packet header
            let mut packet: VkCommandPacket = std::mem::zeroed();
            let mut tail_idx = tail as usize;

            let pkt_ptr = &mut packet as *mut _ as *mut u8;
            for i in 0..hdr_size {
                *pkt_ptr.add(i) = *self.ring_buf.add((tail_idx + i) % self.capacity);
            }
            tail_idx = (tail_idx + hdr_size) % self.capacity;

            let payload_size = packet.payload_size as usize;
            let mut payload = vec![0u8; payload_size];
            for i in 0..payload_size {
                payload[i] = *self.ring_buf.add((tail_idx + i) % self.capacity);
            }
            tail_idx = (tail_idx + payload_size) % self.capacity;

            (*self.header).tail.store(tail_idx as u32, Ordering::Release);
            Some((packet, payload))
        }
    }
}