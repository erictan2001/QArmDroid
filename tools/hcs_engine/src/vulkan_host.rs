//! Minimal but *correct* host-side Vulkan 1.0/1.1 wrapper loaded from
//! vulkan-1.dll on Windows.
//!
//! Why this file was rewritten (previous version faults):
//!   * `vkGetPhysicalDeviceProperties` was invoked through a `*mut u8`
//!     and the device name was read from byte offsets 24..280. In the real
//!     `VkPhysicalDeviceProperties` layout, `deviceName` starts at offset
//!     20 (after apiVersion/driverVersion/vendorID/deviceID/deviceType) and
//!     is 256 chars; offsets 20..40 are *binary* fields (UUIDs, limits), so
//!     the old code printed garbage that only *looked* right by luck.
//!   * No `VkDevice` / `VkQueue` were ever created — there was no usable
//!     Vulkan context to dispatch work into.
//!   * No dispatch table was kept, so handlers could not call real
//!     entrypoints once the probe finished.
//!
//! This version declares every struct with `#[repr(C)]` and lets the Rust
//! compiler (not hand-computed byte offsets) lay out the ABI, creates a
//! logical device with one graphics/compute queue, and stores the
//! entrypoints the passthrough dispatcher needs.

use std::ffi::{c_char, c_void};
use std::ptr::{null, null_mut};

pub type VkResult = i32;
pub type VkInstance = *mut c_void;
pub type VkPhysicalDevice = *mut c_void;
pub type VkDevice = *mut c_void;
pub type VkQueue = *mut c_void;
pub type VkDeviceMemory = *mut c_void;
pub type VkBuffer = *mut c_void;
pub type VkImage = *mut c_void;
pub type VkFence = *mut c_void;
pub type VkAllocationCallbacks = *mut c_void;
pub type VkDescriptorSetLayout = *mut c_void;
pub type VkDescriptorPool = *mut c_void;
pub type VkDescriptorSet = *mut c_void;
pub type VkShaderModule = *mut c_void;
pub type VkPipelineLayout = *mut c_void;
pub type VkPipeline = *mut c_void;
pub type VkCommandPool = *mut c_void;
pub type VkCommandBuffer = *mut c_void;
pub type VkPipelineCache = *mut c_void;

pub const VK_SUCCESS: VkResult = 0;
pub const VK_ERROR_OUT_OF_HOST_MEMORY: VkResult = -1;
pub const VK_ERROR_OUT_OF_DEVICE_MEMORY: VkResult = -2;
pub const VK_ERROR_INITIALIZATION_FAILED: VkResult = -3;
pub const VK_ERROR_DEVICE_LOST: VkResult = -4;
pub const VK_ERROR_INCOMPATIBLE_DRIVER: VkResult = -9;
pub const VK_ERROR_UNKNOWN: VkResult = -13;
pub const VK_ERROR_OUT_OF_DATE_KHR: VkResult = -1000001004;

pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO: u32 = 4;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: u32 = 5;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: u32 = 10;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: u32 = 11;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: u32 = 19;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: u32 = 21;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: u32 = 22;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: u32 = 23;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: u32 = 24;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: u32 = 28;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 29;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: u32 = 30;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: u32 = 34;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: u32 = 16;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: u32 = 18;

pub const VK_PIPELINE_BIND_POINT_COMPUTE: u32 = 2;
pub const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x0000_0020;
pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 6;
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x0000_0001;
pub const VK_WHOLE_SIZE: u64 = u64::MAX;
pub const VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO: u32 = 15;

pub const VK_QUEUE_GRAPHICS_BIT: u32 = 0x0000_0001;
pub const VK_QUEUE_COMPUTE_BIT: u32 = 0x0000_0002;
pub const VK_QUEUE_TRANSFER_BIT: u32 = 0x0000_0004;

pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x0000_0001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x0000_0002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x0000_0004;

pub const VK_IMAGE_TYPE_2D: u32 = 1;
pub const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;
pub const VK_TILING_OPTIMAL: u32 = 0;
pub const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;
pub const VK_IMAGE_LAYOUT_UNDEFINED: u32 = 0;
pub const VK_SAMPLE_COUNT_1_BIT: u32 = 0x0000_0001;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: u32 = 0x0000_0004;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x0000_0010;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: u32 = 0x0000_0001;
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x0000_0080;

pub const VK_API_VERSION_1_3: u32 = (1 << 22) | (3 << 12);

/// Structure-type tags must exactly match the numbered values above.
#[repr(C)]
pub struct VkApplicationInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub p_application_name: *const c_char,
    pub application_version: u32,
    pub p_engine_name: *const c_char,
    pub engine_version: u32,
    pub api_version: u32,
}

#[repr(C)]
pub struct VkInstanceCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub p_application_info: *const VkApplicationInfo,
    pub enabled_layer_count: u32,
    pub pp_enabled_layer_names: *const *const c_char,
    pub enabled_extension_count: u32,
    pub pp_enabled_extension_names: *const *const c_char,
}

/// Prefix of `VkPhysicalDeviceProperties` (Vulkan 1.0 layout is identical
/// through `pipelineCacheUUID` in 1.1/1.2/1.3). We allocate a large zeroed
/// buffer on the stack and cast it, so the driver may write the full struct
/// while we only read this prefix through the correct fields.
#[repr(C)]
pub struct VkPhysicalDeviceProperties {
    pub api_version: u32,
    pub driver_version: u32,
    pub vendor_id: u32,
    pub device_id: u32,
    pub device_type: u32,
    pub device_name: [c_char; 256], // VK_MAX_PHYSICAL_DEVICE_NAME_SIZE
    pub pipeline_cache_uuid: [u8; 16],
}

#[repr(C)]
#[derive(Default, Clone)]
pub struct VkQueueFamilyProperties {
    pub queue_flags: u32,
    pub queue_count: u32,
    pub timestamp_valid_bits: u32,
    pub min_image_transfer_granularity: [u32; 3],
}

#[repr(C)]
pub struct VkDeviceQueueCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub queue_family_index: u32,
    pub queue_count: u32,
    pub p_queue_priorities: *const f32,
}

#[repr(C)]
pub struct VkDeviceCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub queue_create_info_count: u32,
    pub p_queue_create_infos: *const VkDeviceQueueCreateInfo,
    pub enabled_layer_count: u32,
    pub pp_enabled_layer_names: *const *const c_char,
    pub enabled_extension_count: u32,
    pub pp_enabled_extension_names: *const *const c_char,
    pub p_enabled_features: *const c_void,
}

#[repr(C)]
pub struct VkMemoryAllocateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub allocation_size: u64,
    pub memory_type_index: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct VkMemoryType {
    pub property_flags: u32,
    pub heap_index: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct VkMemoryHeap {
    pub size: u64,
    pub flags: u32,
    _pad: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct VkPhysicalDeviceMemoryProperties {
    pub memory_type_count: u32,
    pub memory_types: [VkMemoryType; 32],
    pub memory_heap_count: u32,
    pub memory_heaps: [VkMemoryHeap; 16],
}

#[repr(C)]
pub struct VkBufferCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub size: u64,
    pub usage: u32,
    pub sharing_mode: u32,
    pub queue_family_index_count: u32,
    pub p_queue_family_indices: *const u32,
}

#[repr(C)]
#[derive(Default)]
pub struct VkExtent3D {
    pub width: u32,
    pub height: u32,
    pub depth: u32,
}

#[repr(C)]
pub struct VkImageCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub image_type: u32,
    pub format: u32,
    pub extent: VkExtent3D,
    pub mip_levels: u32,
    pub array_layers: u32,
    pub samples: u32,
    pub tiling: u32,
    pub usage: u32,
    pub sharing_mode: u32,
    pub queue_family_index_count: u32,
    pub p_queue_family_indices: *const u32,
    pub initial_layout: u32,
}

#[repr(C)]
pub struct VkSubmitInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub wait_semaphore_count: u32,
    pub p_wait_semaphores: *const c_void,
    pub p_wait_dst_stage_mask: *const u32,
    pub command_buffer_count: u32,
    pub p_command_buffers: *const c_void,
    pub signal_semaphore_count: u32,
    pub p_signal_semaphores: *const c_void,
}

/* ---------------- compute-render pipeline types ---------------- */

#[repr(C)]
pub struct VkDescriptorSetLayoutBinding {
    pub binding: u32,
    pub descriptor_type: u32,
    pub descriptor_count: u32,
    pub stage_flags: u32,
    pub p_immutable_samplers: *const c_void,
}

#[repr(C)]
pub struct VkDescriptorSetLayoutCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub binding_count: u32,
    pub p_bindings: *const VkDescriptorSetLayoutBinding,
}

#[repr(C)]
pub struct VkDescriptorPoolSize {
    pub descriptor_type: u32,
    pub descriptor_count: u32,
}

#[repr(C)]
pub struct VkDescriptorPoolCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub max_sets: u32,
    pub pool_size_count: u32,
    pub p_pool_sizes: *const VkDescriptorPoolSize,
}

#[repr(C)]
pub struct VkDescriptorSetAllocateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub descriptor_pool: VkDescriptorPool,
    pub descriptor_set_count: u32,
    pub p_set_layouts: *const VkDescriptorSetLayout,
}

#[repr(C)]
pub struct VkDescriptorBufferInfo {
    pub buffer: VkBuffer,
    pub offset: u64,
    pub range: u64,
}

#[repr(C)]
pub struct VkWriteDescriptorSet {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub dst_set: VkDescriptorSet,
    pub dst_binding: u32,
    pub dst_array_element: u32,
    pub descriptor_count: u32,
    pub descriptor_type: u32,
    pub p_image_info: *const c_void,
    pub p_buffer_info: *const VkDescriptorBufferInfo,
    pub p_texel_buffer_view: *const c_void,
}

#[repr(C)]
pub struct VkShaderModuleCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub code_size: usize,
    pub p_code: *const u32,
}

#[repr(C)]
pub struct VkPipelineShaderStageCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub stage: u32,
    pub module: VkShaderModule,
    pub p_name: *const c_char,
    pub p_specialization_info: *const c_void,
}

#[repr(C)]
pub struct VkPushConstantRange {
    pub stage_flags: u32,
    pub offset: u32,
    pub size: u32,
}

#[repr(C)]
pub struct VkPipelineLayoutCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub set_layout_count: u32,
    pub p_set_layouts: *const VkDescriptorSetLayout,
    pub push_constant_range_count: u32,
    pub p_push_constant_ranges: *const VkPushConstantRange,
}

#[repr(C)]
pub struct VkComputePipelineCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub stage: VkPipelineShaderStageCreateInfo,
    pub layout: VkPipelineLayout,
    pub base_pipeline_handle: VkPipeline,
    pub base_pipeline_index: i32,
}

#[repr(C)]
pub struct VkCommandPoolCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub queue_family_index: u32,
}

#[repr(C)]
pub struct VkCommandBufferAllocateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub command_pool: VkCommandPool,
    pub level: u32,
    pub command_buffer_count: u32,
}

#[repr(C)]
pub struct VkCommandBufferBeginInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub p_inheritance_info: *const c_void,
}

#[repr(C)]
pub struct VkPipelineCacheCreateInfo {
    pub s_type: u32,
    pub p_next: *const c_void,
    pub flags: u32,
    pub initial_data_size: usize,
    pub p_initial_data: *const c_void,
}

/// Entrypoints needed by the passthrough dispatcher, resolved at load time.
#[derive(Clone, Copy)]
pub struct ExtProcs {
    pub vk_get_physical_device_memory_properties:
        unsafe extern "system" fn(VkPhysicalDevice, *mut VkPhysicalDeviceMemoryProperties),
    pub vk_allocate_memory:
        unsafe extern "system" fn(VkDevice, *const VkMemoryAllocateInfo, *const VkAllocationCallbacks, *mut VkDeviceMemory) -> VkResult,
    pub vk_free_memory: unsafe extern "system" fn(VkDevice, VkDeviceMemory, *const VkAllocationCallbacks),
    pub vk_create_buffer:
        unsafe extern "system" fn(VkDevice, *const VkBufferCreateInfo, *const VkAllocationCallbacks, *mut VkBuffer) -> VkResult,
    pub vk_destroy_buffer: unsafe extern "system" fn(VkDevice, VkBuffer, *const VkAllocationCallbacks),
    pub vk_create_image:
        unsafe extern "system" fn(VkDevice, *const VkImageCreateInfo, *const VkAllocationCallbacks, *mut VkImage) -> VkResult,
    pub vk_destroy_image: unsafe extern "system" fn(VkDevice, VkImage, *const VkAllocationCallbacks),
    pub vk_queue_submit: unsafe extern "system" fn(VkQueue, u32, *const VkSubmitInfo, VkFence) -> VkResult,
    pub vk_queue_wait_idle: unsafe extern "system" fn(VkQueue) -> VkResult,
    pub vk_device_wait_idle: unsafe extern "system" fn(VkDevice) -> VkResult,
    pub vk_destroy_device: unsafe extern "system" fn(VkDevice, *const VkAllocationCallbacks),
    pub vk_destroy_instance: unsafe extern "system" fn(VkInstance, *const VkAllocationCallbacks),
    pub vk_bind_buffer_memory: unsafe extern "system" fn(VkDevice, VkBuffer, VkDeviceMemory, u64) -> VkResult,
    pub vk_map_memory: unsafe extern "system" fn(VkDevice, VkDeviceMemory, u64, u64, u32, *mut *mut c_void) -> VkResult,
    pub vk_unmap_memory: unsafe extern "system" fn(VkDevice, VkDeviceMemory),
    pub vk_create_descriptor_set_layout: unsafe extern "system" fn(
        VkDevice,
        *const VkDescriptorSetLayoutCreateInfo,
        *const VkAllocationCallbacks,
        *mut VkDescriptorSetLayout,
    ) -> VkResult,
    pub vk_destroy_descriptor_set_layout: unsafe extern "system" fn(
        VkDevice,
        VkDescriptorSetLayout,
        *const VkAllocationCallbacks,
    ),
    pub vk_create_descriptor_pool: unsafe extern "system" fn(
        VkDevice,
        *const VkDescriptorPoolCreateInfo,
        *const VkAllocationCallbacks,
        *mut VkDescriptorPool,
    ) -> VkResult,
    pub vk_destroy_descriptor_pool: unsafe extern "system" fn(
        VkDevice,
        VkDescriptorPool,
        *const VkAllocationCallbacks,
    ),
    pub vk_allocate_descriptor_sets: unsafe extern "system" fn(
        VkDevice,
        *const VkDescriptorSetAllocateInfo,
        *mut VkDescriptorSet,
    ) -> VkResult,
    pub vk_free_descriptor_sets: unsafe extern "system" fn(
        VkDevice,
        VkDescriptorPool,
        u32,
        *const VkDescriptorSet,
    ) -> VkResult,
    pub vk_update_descriptor_sets: unsafe extern "system" fn(
        VkDevice,
        u32,
        *const VkWriteDescriptorSet,
        u32,
        *const c_void,
    ),
    pub vk_create_shader_module: unsafe extern "system" fn(
        VkDevice,
        *const VkShaderModuleCreateInfo,
        *const VkAllocationCallbacks,
        *mut VkShaderModule,
    ) -> VkResult,
    pub vk_destroy_shader_module: unsafe extern "system" fn(
        VkDevice,
        VkShaderModule,
        *const VkAllocationCallbacks,
    ),
    pub vk_create_pipeline_layout: unsafe extern "system" fn(
        VkDevice,
        *const VkPipelineLayoutCreateInfo,
        *const VkAllocationCallbacks,
        *mut VkPipelineLayout,
    ) -> VkResult,
    pub vk_destroy_pipeline_layout: unsafe extern "system" fn(
        VkDevice,
        VkPipelineLayout,
        *const VkAllocationCallbacks,
    ),
    pub vk_create_compute_pipelines: unsafe extern "system" fn(
        VkDevice,
        VkPipelineCache,
        u32,
        *const VkComputePipelineCreateInfo,
        *const VkAllocationCallbacks,
        *mut VkPipeline,
    ) -> VkResult,
    pub vk_destroy_pipeline: unsafe extern "system" fn(VkDevice, VkPipeline, *const VkAllocationCallbacks),
    pub vk_create_command_pool: unsafe extern "system" fn(
        VkDevice,
        *const VkCommandPoolCreateInfo,
        *const VkAllocationCallbacks,
        *mut VkCommandPool,
    ) -> VkResult,
    pub vk_destroy_command_pool: unsafe extern "system" fn(
        VkDevice,
        VkCommandPool,
        *const VkAllocationCallbacks,
    ),
    pub vk_allocate_command_buffers: unsafe extern "system" fn(
        VkDevice,
        *const VkCommandBufferAllocateInfo,
        *mut VkCommandBuffer,
    ) -> VkResult,
    pub vk_free_command_buffers: unsafe extern "system" fn(
        VkDevice,
        VkCommandPool,
        u32,
        *const VkCommandBuffer,
    ),
    pub vk_begin_command_buffer: unsafe extern "system" fn(
        VkCommandBuffer,
        *const VkCommandBufferBeginInfo,
    ) -> VkResult,
    pub vk_end_command_buffer: unsafe extern "system" fn(VkCommandBuffer) -> VkResult,
    pub vk_cmd_bind_pipeline: unsafe extern "system" fn(VkCommandBuffer, u32, VkPipeline),
    pub vk_cmd_bind_descriptor_sets: unsafe extern "system" fn(
        VkCommandBuffer,
        u32,
        VkPipelineLayout,
        u32,
        u32,
        *const VkDescriptorSet,
        u32,
        *const u32,
    ),
    pub vk_cmd_push_constants: unsafe extern "system" fn(
        VkCommandBuffer,
        VkPipelineLayout,
        u32,
        u32,
        u32,
        *const c_void,
    ),
    pub vk_cmd_dispatch: unsafe extern "system" fn(VkCommandBuffer, u32, u32, u32),
    pub vk_cmd_fill_buffer: unsafe extern "system" fn(
        VkCommandBuffer,
        VkBuffer,
        u64,
        u64,
        u32,
    ),
    pub vk_create_pipeline_cache: unsafe extern "system" fn(
        VkDevice,
        *const VkPipelineCacheCreateInfo,
        *const VkAllocationCallbacks,
        *mut VkPipelineCache,
    ) -> VkResult,
    pub vk_destroy_pipeline_cache: unsafe extern "system" fn(
        VkDevice,
        VkPipelineCache,
        *const VkAllocationCallbacks,
    ),
}

pub struct HostVulkanEngine {
    module: *mut c_void,
    pub instance: VkInstance,
    pub physical_device: VkPhysicalDevice,
    pub device: VkDevice,
    pub queue: VkQueue,
    pub queue_family_index: u32,
    pub device_name: String,
    pub driver_version: u32,
    pub api_version: u32,
    pub ext: ExtProcs,
    /// Compute render pipeline (descriptor set + shader + pipeline + command
    /// buffer) used by the render opcodes. Constructed during probe, so the
    /// daemon is render-ready from the start.
    pub render: std::sync::Mutex<Option<crate::render::RenderPipeline>>,
}

// Vulkan guarantees thread safety for device calls; the daemon serves
// concurrent guest connections, so the engine must be shareable across
// threads (mirrors the existing HcsApi pattern).
unsafe impl Send for HostVulkanEngine {}
unsafe impl Sync for HostVulkanEngine {}

unsafe extern "system" {
    fn LoadLibraryA(lpLibFileName: *const u8) -> *mut c_void;
    fn GetProcAddress(hModule: *mut c_void, lpProcName: *const u8) -> *mut c_void;
    fn FreeLibrary(hLibModule: *mut c_void) -> i32;
}

fn vk_make_version(major: u32, minor: u32, patch: u32) -> u32 {
    (major << 22) | (minor << 12) | patch
}

impl HostVulkanEngine {
    pub fn probe() -> Result<Self, String> {
        unsafe {
            let module = LoadLibraryA(c"vulkan-1.dll".as_ptr() as *const u8);
            if module.is_null() {
                return Err("Could not load host vulkan-1.dll (is a Vulkan runtime installed?)".to_string());
            }

            macro_rules! get {
                ($name:expr) => {{
                    // c"" literals yield *const c_char (i8); GetProcAddress
                    // wants *const u8 — same address space, cast is fine.
                    let p = GetProcAddress(module, $name.as_ptr() as *const u8);
                    if p.is_null() {
                        FreeLibrary(module);
                        return Err(format!(
                            "vulkan-1.dll is missing required export {}",
                            String::from_utf8_lossy($name.to_bytes())
                        ));
                    }
                    p
                }};
            }

            // ---- instance ----
            let vk_create_instance: unsafe extern "system" fn(
                *const VkInstanceCreateInfo,
                *const VkAllocationCallbacks,
                *mut VkInstance,
            ) -> VkResult = std::mem::transmute(get!(c"vkCreateInstance"));

            let app_info = VkApplicationInfo {
                s_type: VK_STRUCTURE_TYPE_APPLICATION_INFO,
                p_next: null(),
                p_application_name: c"Arm64DroidHostVulkan".as_ptr(),
                application_version: vk_make_version(0, 1, 0),
                p_engine_name: c"ApertureVulkan".as_ptr(),
                engine_version: 1,
                // HCS_VK_API_VERSION=0 requests 1.0 (bring-up diagnostic);
                // default is 1.3.
                api_version: match std::env::var("HCS_VK_API_VERSION") {
                    Ok(v) if v.trim() == "0" => 1 << 22,
                    _ => VK_API_VERSION_1_3,
                },
            };
            let create_info = VkInstanceCreateInfo {
                s_type: VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                p_application_info: &app_info,
                enabled_layer_count: 0,
                pp_enabled_layer_names: null(),
                enabled_extension_count: 0,
                pp_enabled_extension_names: null(),
            };

            let mut instance: VkInstance = null_mut();
            let res = vk_create_instance(&create_info, null(), &mut instance);
            if res != VK_SUCCESS || instance.is_null() {
                FreeLibrary(module);
                return Err(format!("vkCreateInstance failed with code {}", res));
            }

            // ---- physical device ----
            let vk_enumerate_physical_devices: unsafe extern "system" fn(
                VkInstance,
                *mut u32,
                *mut VkPhysicalDevice,
            ) -> VkResult = std::mem::transmute(get!(c"vkEnumeratePhysicalDevices"));

            let mut count = 0u32;
            vk_enumerate_physical_devices(instance, &mut count, null_mut());
            if count == 0 {
                return Err("No physical Vulkan GPUs detected on host".to_string());
            }
            let mut devices = vec![null_mut(); count as usize];
            let res = vk_enumerate_physical_devices(instance, &mut count, devices.as_mut_ptr());
            if res != VK_SUCCESS {
                return Err(format!("vkEnumeratePhysicalDevices failed with code {}", res));
            }
            let physical_device = devices[0];

            // ---- device properties (correct layout via repr(C)) ----
            let vk_get_physical_device_properties: unsafe extern "system" fn(
                VkPhysicalDevice,
                *mut VkPhysicalDeviceProperties,
            ) = std::mem::transmute(get!(c"vkGetPhysicalDeviceProperties"));

            let mut props_buf = [0u8; 4096]; // driver may write the full struct; we read only the prefix
            vk_get_physical_device_properties(physical_device, props_buf.as_mut_ptr() as *mut VkPhysicalDeviceProperties);
            let props = &*(props_buf.as_ptr() as *const VkPhysicalDeviceProperties);
            let name_len = props
                .device_name
                .iter()
                .position(|&c| c == 0)
                .unwrap_or(256);
            let name_bytes = std::slice::from_raw_parts(props.device_name.as_ptr() as *const u8, name_len);
            let device_name = String::from_utf8_lossy(name_bytes).to_string();

            // ---- queue family ----
            let vk_get_queue_family_properties: unsafe extern "system" fn(
                VkPhysicalDevice,
                *mut u32,
                *mut VkQueueFamilyProperties,
            ) = std::mem::transmute(get!(c"vkGetPhysicalDeviceQueueFamilyProperties"));

            let mut qf_count = 0u32;
            vk_get_queue_family_properties(physical_device, &mut qf_count, null_mut());
            let mut qfs = vec![VkQueueFamilyProperties { queue_flags: 0, queue_count: 0, timestamp_valid_bits: 0, min_image_transfer_granularity: [0; 3] }; qf_count as usize];
            vk_get_queue_family_properties(physical_device, &mut qf_count, qfs.as_mut_ptr());

            let mut queue_family_index: Option<u32> = None;
            for (i, qf) in qfs.iter().enumerate() {
                if qf.queue_count > 0
                    && (qf.queue_flags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) != 0
                {
                    queue_family_index = Some(i as u32);
                    break;
                }
            }
            let queue_family_index = queue_family_index.ok_or_else(|| {
                "No physical device queue family exposes graphics/compute queues".to_string()
            })?;

            // ---- logical device with one queue ----
            let vk_create_device: unsafe extern "system" fn(
                VkPhysicalDevice,
                *const VkDeviceCreateInfo,
                *const VkAllocationCallbacks,
                *mut VkDevice,
            ) -> VkResult = std::mem::transmute(get!(c"vkCreateDevice"));

            let priority = [1.0f32];
            let queue_ci = VkDeviceQueueCreateInfo {
                s_type: VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                queue_family_index,
                queue_count: 1,
                p_queue_priorities: priority.as_ptr(),
            };
            let dev_ci = VkDeviceCreateInfo {
                s_type: VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                queue_create_info_count: 1,
                p_queue_create_infos: &queue_ci,
                enabled_layer_count: 0,
                pp_enabled_layer_names: null(),
                enabled_extension_count: 0,
                pp_enabled_extension_names: null(),
                p_enabled_features: null(),
            };

            let mut device: VkDevice = null_mut();
            let res = vk_create_device(physical_device, &dev_ci, null(), &mut device);
            if res != VK_SUCCESS || device.is_null() {
                return Err(format!("vkCreateDevice failed with code {}", res));
            }

            let vk_get_device_queue: unsafe extern "system" fn(VkDevice, u32, u32, *mut VkQueue) =
                std::mem::transmute(get!(c"vkGetDeviceQueue"));
            let mut queue: VkQueue = null_mut();
            vk_get_device_queue(device, queue_family_index, 0, &mut queue);
            if queue.is_null() {
                return Err("vkGetDeviceQueue returned a null queue".to_string());
            }

            // ---- remaining dispatch table (all are loader exports) ----
            let ext = ExtProcs {
                vk_get_physical_device_memory_properties: std::mem::transmute(
                    get!(c"vkGetPhysicalDeviceMemoryProperties"),
                ),
                vk_allocate_memory: std::mem::transmute(get!(c"vkAllocateMemory")),
                vk_free_memory: std::mem::transmute(get!(c"vkFreeMemory")),
                vk_create_buffer: std::mem::transmute(get!(c"vkCreateBuffer")),
                vk_destroy_buffer: std::mem::transmute(get!(c"vkDestroyBuffer")),
                vk_create_image: std::mem::transmute(get!(c"vkCreateImage")),
                vk_destroy_image: std::mem::transmute(get!(c"vkDestroyImage")),
                vk_queue_submit: std::mem::transmute(get!(c"vkQueueSubmit")),
                vk_queue_wait_idle: std::mem::transmute(get!(c"vkQueueWaitIdle")),
                vk_device_wait_idle: std::mem::transmute(get!(c"vkDeviceWaitIdle")),
                vk_destroy_device: std::mem::transmute(get!(c"vkDestroyDevice")),
                vk_destroy_instance: std::mem::transmute(get!(c"vkDestroyInstance")),
                vk_bind_buffer_memory: std::mem::transmute(get!(c"vkBindBufferMemory")),
                vk_map_memory: std::mem::transmute(get!(c"vkMapMemory")),
                vk_unmap_memory: std::mem::transmute(get!(c"vkUnmapMemory")),
                vk_create_descriptor_set_layout: std::mem::transmute(
                    get!(c"vkCreateDescriptorSetLayout"),
                ),
                vk_destroy_descriptor_set_layout: std::mem::transmute(
                    get!(c"vkDestroyDescriptorSetLayout"),
                ),
                vk_create_descriptor_pool: std::mem::transmute(get!(c"vkCreateDescriptorPool")),
                vk_destroy_descriptor_pool: std::mem::transmute(get!(c"vkDestroyDescriptorPool")),
                vk_allocate_descriptor_sets: std::mem::transmute(get!(c"vkAllocateDescriptorSets")),
                vk_free_descriptor_sets: std::mem::transmute(get!(c"vkFreeDescriptorSets")),
                vk_update_descriptor_sets: std::mem::transmute(get!(c"vkUpdateDescriptorSets")),
                vk_create_shader_module: std::mem::transmute(get!(c"vkCreateShaderModule")),
                vk_destroy_shader_module: std::mem::transmute(get!(c"vkDestroyShaderModule")),
                vk_create_pipeline_layout: std::mem::transmute(get!(c"vkCreatePipelineLayout")),
                vk_destroy_pipeline_layout: std::mem::transmute(get!(c"vkDestroyPipelineLayout")),
                vk_create_compute_pipelines: std::mem::transmute(get!(c"vkCreateComputePipelines")),
                vk_destroy_pipeline: std::mem::transmute(get!(c"vkDestroyPipeline")),
                vk_create_command_pool: std::mem::transmute(get!(c"vkCreateCommandPool")),
                vk_destroy_command_pool: std::mem::transmute(get!(c"vkDestroyCommandPool")),
                vk_allocate_command_buffers: std::mem::transmute(get!(c"vkAllocateCommandBuffers")),
                vk_free_command_buffers: std::mem::transmute(get!(c"vkFreeCommandBuffers")),
                vk_begin_command_buffer: std::mem::transmute(get!(c"vkBeginCommandBuffer")),
                vk_end_command_buffer: std::mem::transmute(get!(c"vkEndCommandBuffer")),
                vk_cmd_bind_pipeline: std::mem::transmute(get!(c"vkCmdBindPipeline")),
                vk_cmd_bind_descriptor_sets: std::mem::transmute(get!(c"vkCmdBindDescriptorSets")),
                vk_cmd_push_constants: std::mem::transmute(get!(c"vkCmdPushConstants")),
                vk_cmd_dispatch: std::mem::transmute(get!(c"vkCmdDispatch")),
                vk_cmd_fill_buffer: std::mem::transmute(get!(c"vkCmdFillBuffer")),
                vk_create_pipeline_cache: std::mem::transmute(get!(c"vkCreatePipelineCache")),
                vk_destroy_pipeline_cache: std::mem::transmute(get!(c"vkDestroyPipelineCache")),
            };

            let engine = Self {
                module,
                instance,
                physical_device,
                device,
                queue,
                queue_family_index,
                device_name,
                driver_version: props.driver_version,
                api_version: props.api_version,
                ext,
                render: std::sync::Mutex::new(None),
            };

            // Build the compute render pipeline (SPIR-V shader, descriptor
            // set, pipeline, command buffer). Non-fatal: if it fails, the
            // daemon stays up but render opcodes report the error.
            match crate::render::RenderPipeline::create(&engine) {
                Ok(p) => {
                    *engine.render.lock().unwrap() = Some(p);
                }
                Err(e) => {
                    eprintln!("[warn] render pipeline init failed: {e}");
                }
            }

            Ok(engine)
        }
    }
}

impl Drop for HostVulkanEngine {
    fn drop(&mut self) {
        unsafe {
            // Render pipeline objects must be destroyed before the device.
            if let Ok(mut guard) = self.render.lock() {
                if let Some(p) = guard.take() {
                    drop(p); // RenderPipeline::drop destroys its Vulkan objects
                }
            }
            if !self.device.is_null() {
                (self.ext.vk_destroy_device)(self.device, null());
            }
            if !self.instance.is_null() {
                (self.ext.vk_destroy_instance)(self.instance, null());
            }
            if !self.module.is_null() {
                FreeLibrary(self.module);
            }
        }
    }
}

// Re-export a couple of helpers for callers that print human-readable info.
impl HostVulkanEngine {
    pub fn driver_version_string(&self) -> String {
        format!(
            "{}.{}.{}",
            (self.driver_version >> 22) & 0x3ff,
            (self.driver_version >> 12) & 0x3ff,
            self.driver_version & 0xfff
        )
    }
}