//! Compute render pipeline for the native passthrough.
//!
//! Two rendering backends:
//!
//! 1. **Shader backend** (preferred): descriptor set layout + pool + set
//!    (binding 0 = storage buffer), pipeline layout with an 8-byte push
//!    constant range (width, height), a compute pipeline from an embedded
//!    hand-assembled SPIR-V module, and one primary command buffer.
//!    The shader writes a red/green gradient; host API version 1.3.
//!
//! 2. **Fill backend** (fallback): on drivers whose SPIR-V pipeline
//!    compilation is unavailable (e.g. Microsoft's D3D12-mapping Vulkan
//!    layer, `dzn`, which returns VK_ERROR_UNKNOWN from
//!    vkCreateComputePipelines on this host), we still render by recording
//!    `vkCmdFillBuffer` calls — one per scanline with a hue-rotated color —
//!    into the guest-created host-visible buffer. This exercises the full
//!    command-recording -> submit -> wait-idle -> readback path and produces
//!    a visibly verifiable frame.
//!
//! The guest flow is identical either way:
//!   1. OP_CREATE_BUFFER + OP_ALLOCATE_MEMORY (host-visible)
//!   2. OP_BIND_RENDER_BUFFER  -> vkBindBufferMemory (+ descriptor update)
//!   3. OP_RENDER_FRAME        -> record + submit + waitIdle
//!   4. OP_READ_PIXELS         -> vkMapMemory -> raw bytes returned

use crate::vulkan_host::{
    HostVulkanEngine, VkBuffer, VkCommandBuffer, VkCommandBufferAllocateInfo,
    VkCommandBufferBeginInfo, VkCommandPoolCreateInfo, VkComputePipelineCreateInfo,
    VkDescriptorBufferInfo, VkDescriptorPoolCreateInfo, VkDescriptorPoolSize,
    VkDescriptorSet, VkDescriptorSetAllocateInfo, VkDescriptorSetLayoutBinding,
    VkDescriptorSetLayoutCreateInfo, VkDeviceMemory, VkPipelineLayoutCreateInfo,
    VkPipelineShaderStageCreateInfo, VkPushConstantRange, VkShaderModuleCreateInfo,
    VkSubmitInfo, VkWriteDescriptorSet, VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    VK_COMMAND_BUFFER_LEVEL_PRIMARY, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
    VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
    VK_PIPELINE_BIND_POINT_COMPUTE, VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, VK_SHADER_STAGE_COMPUTE_BIT,
    VK_STRUCTURE_TYPE_SUBMIT_INFO, VK_SUCCESS, VK_WHOLE_SIZE,
};
use std::ptr::{null, null_mut};

/// Local workgroup size of the embedded shader.
pub const LOCAL_SIZE: u32 = 16;

/// Hand-assembled SPIR-V 1.0 module for the gradient compute shader.
/// Layout: local_size 16x16x1, one storage buffer binding 0 (uint32[]),
/// push constant struct {uint width, uint height}.
///
/// IDs:
///   1   void           9   pixels var (StorageBuffer)  21  main function
///   2   fn()           10  push struct {uint,uint}     22  entry label
///   3   uint           11  ptr<PushConstant,10>        23  global id (uvec2)
///   4   const 0        12  push var (PushConstant)     24  x
///   5   const 1        13  uvec2                       25  y
///   6   runtime array  14  ptr<Input,13>               26  &push.width
///   7   struct {6}     15  gl_GlobalInvocationID       27  w
///   8   ptr<SB,7>      16  const 255                   28  y*w
///   17  const 0xFF000000                               29  idx
///   18  const 16                                       30  &pixels[idx]
///   19  const 8                                        31  x*255
///   20  const 127                                      32  w-1
///   44  ptr<SB,3>                                      33  r
///   45  ptr<PushConstant,3>                            34  &push.height
///                                                      35  h
///                                                      36  y*255
///                                                      37  h-1
///                                                      38  g
///                                                      39  g<<16
///                                                      40  r<<8
///                                                      41  |(0xFF000000)
///                                                      42  |r8
///                                                      43  |0x7F
const GRADIENT_SPIRV: &[u32] = &[
    // header: magic, version 1.0, generator, bound, schema
    0x0723_0203, 0x0001_0000, 0x0000_0000, 46, 0x0000_0000,
    // 1  OpCapability Shader
    0x0002_0011, 0x0000_0001,
    // 2  OpMemoryModel Logical GLSL450
    0x0002_000e, 0x0000_0000, 0x0000_0001,
    // 3  OpEntryPoint GLCompute %22 "main" interface %15
    0x0006_000f, 0x0000_0005, 22, 0x6e69_616d, 0x0000_0000, 15,
    // 4  OpExecutionMode %22 LocalSize 16 16 1
    0x0006_0011, 22, 0x0000_0011, 16, 16, 1,
    // 5  OpTypeVoid %1
    0x0002_0013, 1,
    // 6  OpTypeFunction %2 %1
    0x0003_0021, 2, 1,
    // 7  OpTypeInt 32 0 -> %3 (uint)
    0x0004_0015, 3, 0x0000_0020, 0,
    // 8  OpConstant %3 0 -> %4
    0x0004_002b, 3, 4, 0,
    // 9  OpConstant %3 1 -> %5
    0x0004_002b, 3, 5, 1,
    // 10 OpTypeRuntimeArray %3 -> %6
    0x0003_001d, 3, 6,
    // 11 OpTypeStruct %6 -> %7
    0x0003_001e, 6, 7,
    // 12 OpTypePointer StorageBuffer %7 -> %8
    0x0003_0032, 5348, 7, 8,
    // 13 OpVariable %8 StorageBuffer -> %9 (pixels)
    0x0004_003b, 8, 5348, 9,
    // 14 OpDecorate %6 ArrayStride 4
    0x0004_0047, 6, 6, 4,
    // 15 OpDecorate %7 Block   (storage buffer block)
    0x0003_0047, 7, 2,
    // 16 OpMemberDecorate %7 0 Offset 0
    0x0005_0048, 7, 0, 35, 0,
    // 17 OpDecorate %9 DescriptorSet 0
    0x0004_0047, 9, 33, 0,
    // 18 OpDecorate %9 Binding 0
    0x0004_0047, 9, 34, 0,
    // 19 OpTypeStruct %3 %3 -> %10 (push {w,h})
    0x0004_001e, 3, 3, 10,
    // 20 OpTypePointer PushConstant %10 -> %11
    0x0003_0032, 5432, 10, 11,
    // 21 OpVariable %11 PushConstant -> %12 (push)
    0x0004_003b, 11, 5432, 12,
    // 22 OpMemberDecorate %10 0 Offset 0
    0x0005_0048, 10, 0, 35, 0,
    // 23 OpMemberDecorate %10 1 Offset 4
    0x0005_0048, 10, 1, 35, 4,
    // 24 OpTypeVector %3 2 -> %13 (uvec2)
    0x0004_0017, 3, 2, 13,
    // 25 OpTypePointer Input %13 -> %14
    0x0003_0032, 1, 13, 14,
    // 26 OpVariable %14 Input -> %15 (gl_GlobalInvocationID)
    0x0004_003b, 14, 1, 15,
    // 27 OpDecorate %15 BuiltIn 28
    0x0004_0047, 15, 11, 28,
    // 28 OpConstant %3 255 -> %16
    0x0004_002b, 3, 16, 255,
    // 29 OpConstant %3 0xFF000000 -> %17
    0x0004_002b, 3, 17, 0xff00_0000,
    // 30 OpConstant %3 16 -> %18
    0x0004_002b, 3, 18, 16,
    // 31 OpConstant %3 8 -> %19
    0x0004_002b, 3, 19, 8,
    // 32 OpConstant %3 127 -> %20
    0x0004_002b, 3, 20, 127,
    // 33 OpTypePointer StorageBuffer %3 -> %44
    0x0003_0032, 5348, 3, 44,
    // 34 OpTypePointer PushConstant %3 -> %45
    0x0003_0032, 5432, 3, 45,
    // 35 OpFunction %1 None %2 -> %21
    0x0005_0036, 1, 0, 2, 21,
    // 36 OpLabel -> %22
    0x0002_00f8, 22,
    // 37 %23 = OpLoad %13 %15            (global id, uvec2)
    0x0004_003d, 13, 23, 15,
    // 38 %24 = OpCompositeExtract %3 %23 0 (x)
    0x0005_0051, 3, 24, 23, 0,
    // 39 %25 = OpCompositeExtract %3 %23 1 (y)
    0x0005_0051, 3, 25, 23, 1,
    // 40 %26 = OpAccessChain %45 %12 0   (&push.width : ptr<PushConstant,uint>)
    0x0005_0041, 45, 26, 12, 0,
    // 41 %27 = OpLoad %3 %26             (w)
    0x0004_003d, 3, 27, 26,
    // 42 %28 = OpIMul %3 %25 %27         (y*w)
    0x0005_0082, 3, 28, 25, 27,
    // 43 %29 = OpIAdd %3 %28 %24         (idx)
    0x0005_0080, 3, 29, 28, 24,
    // 44 %30 = OpAccessChain %44 %9 %29  (&pixels[idx] : ptr<StorageBuffer,uint>)
    0x0005_0041, 44, 30, 9, 29,
    // 45 %31 = OpIMul %3 %24 %16         (x*255)
    0x0005_0082, 3, 31, 24, 16,
    // 46 %32 = OpISub %3 %27 %5          (w-1)
    0x0005_0083, 3, 32, 27, 5,
    // 47 %33 = OpUDiv %3 %31 %32         (r)
    0x0005_0086, 3, 33, 31, 32,
    // 48 %34 = OpAccessChain %45 %12 1   (&push.height)
    0x0005_0041, 45, 34, 12, 1,
    // 49 %35 = OpLoad %3 %34             (h)
    0x0004_003d, 3, 35, 34,
    // 50 %36 = OpIMul %3 %25 %16         (y*255)
    0x0005_0082, 3, 36, 25, 16,
    // 51 %37 = OpISub %3 %35 %5          (h-1)
    0x0005_0083, 3, 37, 35, 5,
    // 52 %38 = OpUDiv %3 %36 %37         (g)
    0x0005_0086, 3, 38, 36, 37,
    // 53 %39 = OpShiftLeftLogical %3 %38 %18  (g<<16)
    0x0005_008f, 3, 39, 38, 18,
    // 54 %40 = OpShiftLeftLogical %3 %33 %19  (r<<8)
    0x0005_008f, 3, 40, 33, 19,
    // 55 %41 = OpBitwiseOr %3 %17 %39    (0xFF000000 | g16)
    0x0005_0096, 3, 41, 17, 39,
    // 56 %42 = OpBitwiseOr %3 %41 %40    (| r8)
    0x0005_0096, 3, 42, 41, 40,
    // 57 %43 = OpBitwiseOr %3 %42 %20    (| 0x7F)
    0x0005_0096, 3, 43, 42, 20,
    // 58 OpStore %30 %43
    0x0003_003e, 30, 43,
    // 59 OpReturn
    0x0001_00fd,
    // 60 OpFunctionEnd
    0x0001_0038,
];

/// Minimally correct compute shader (`void main() {}`, local size 1x1x1)
/// used to isolate SPIR-V errors from API-usage errors during bring-up.
const TRIVIAL_SPIRV: &[u32] = &[
    0x0723_0203, 0x0001_0000, 0x0000_0000, 6, 0x0000_0000,
    0x0002_0011, 0x0000_0001,               // OpCapability Shader
    0x0002_000e, 0x0000_0000, 0x0000_0001,  // OpMemoryModel
    0x0005_000f, 0x0000_0005, 5, 0x6e69_616d, 0x0000_0000, // OpEntryPoint GLCompute %5 "main"
    0x0006_0011, 5, 0x0000_0011, 1, 1, 1,   // OpExecutionMode %5 LocalSize 1 1 1
    0x0002_0013, 1,                         // OpTypeVoid %1
    0x0003_0021, 2, 1,                      // OpTypeFunction %2 %1
    0x0005_0036, 1, 0, 2, 3,                // OpFunction %1 None %2 %3
    0x0002_00f8, 4,                         // OpLabel %4
    0x0001_00fd,                            // OpReturn
    0x0001_0038,                            // OpFunctionEnd
];

pub struct RenderPipeline {
    desc_layout: crate::vulkan_host::VkDescriptorSetLayout,
    desc_pool: crate::vulkan_host::VkDescriptorPool,
    pub desc_set: VkDescriptorSet,
    shader_module: crate::vulkan_host::VkShaderModule,
    pipeline_layout: crate::vulkan_host::VkPipelineLayout,
    pipeline: crate::vulkan_host::VkPipeline,
    command_pool: crate::vulkan_host::VkCommandPool,
    command_buffer: VkCommandBuffer,
    device: crate::vulkan_host::VkDevice,
    queue: crate::vulkan_host::VkQueue,
    ext: crate::vulkan_host::ExtProcs,
    /// Buffer currently bound (guest-created) + its memory for readback.
    bound_buffer: Option<VkBuffer>,
    bound_memory: Option<VkDeviceMemory>,
    /// True when running without a shader pipeline (fill-backend).
    fill_based: bool,
}

impl RenderPipeline {
    pub fn create(engine: &HostVulkanEngine) -> Result<Self, String> {
        match Self::create_with(engine, GRADIENT_SPIRV) {
            Ok(p) => Ok(p),
            Err(gradient_err) => match Self::create_with(engine, TRIVIAL_SPIRV) {
                Ok(_p) => Err(format!(
                    "SPIR-V pipeline rejected by driver ({gradient_err}); trivial shader links, \
                     but the gradient module does not — fix the SPIR-V"
                )),
                Err(trivial_err) => {
                    // No shader pipeline at all on this driver: fall back to
                    // the fill-based renderer (vkCmdFillBuffer scanlines).
                    eprintln!(
                        "[warn] shader pipelines unavailable on this Vulkan runtime \
                         (gradient: {gradient_err}; trivial: {trivial_err}); \
                         using fill-based renderer"
                    );
                    Self::create_fill_based(engine)
                }
            },
        }
    }

    /// Fill-backend construction: command pool + one primary command buffer
    /// only. Rendering records one vkCmdFillBuffer per scanline.
    fn create_fill_based(engine: &HostVulkanEngine) -> Result<Self, String> {
        let ext = engine.ext;
        let device = engine.device;
        unsafe {
            let cp_ci = VkCommandPoolCreateInfo {
                s_type: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                p_next: null(),
                flags: 0,
                queue_family_index: engine.queue_family_index,
            };
            let mut command_pool = null_mut();
            let r = (ext.vk_create_command_pool)(device, &cp_ci, null(), &mut command_pool);
            if r != VK_SUCCESS || command_pool.is_null() {
                return Err(format!("vkCreateCommandPool failed ({r})"));
            }
            let cb_ai = VkCommandBufferAllocateInfo {
                s_type: crate::vulkan_host::VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                p_next: null(),
                command_pool,
                level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                command_buffer_count: 1,
            };
            let mut command_buffer: VkCommandBuffer = null_mut();
            let r = (ext.vk_allocate_command_buffers)(device, &cb_ai, &mut command_buffer);
            if r != VK_SUCCESS || command_buffer.is_null() {
                return Err(format!("vkAllocateCommandBuffers failed ({r})"));
            }
            Ok(Self {
                desc_layout: null_mut(),
                desc_pool: null_mut(),
                desc_set: null_mut(),
                shader_module: null_mut(),
                pipeline_layout: null_mut(),
                pipeline: null_mut(),
                command_pool,
                command_buffer,
                device,
                queue: engine.queue,
                ext,
                bound_buffer: None,
                bound_memory: None,
                fill_based: true,
            })
        }
    }

    /// Diagnostic: try a matrix of pipeline configurations with the trivial
    /// shader and report which combination the driver accepts. Used to
    /// isolate API-usage errors from shader errors when bring-up fails.
    #[allow(dead_code)]
    pub fn diagnostic(engine: &HostVulkanEngine) -> Vec<(String, String)> {
        let mut out = Vec::new();
        for (label, with_push, with_desc) in [
            ("full", true, true),
            ("no-push", false, true),
            ("no-desc", true, false),
            ("minimal", false, false),
        ] {
            let r = Self::create_variant(engine, TRIVIAL_SPIRV, with_push, with_desc);
            out.push((
                label.to_string(),
                match r {
                    Ok(_) => "OK".to_string(),
                    Err(e) => e,
                },
            ));
        }
        out
    }

    /// Variant of `create_with` parameterized by push-constant and
    /// descriptor-set usage; 0 == success, negative == VkResult.
    fn create_variant(
        engine: &HostVulkanEngine,
        spirv: &[u32],
        with_push: bool,
        with_desc: bool,
    ) -> Result<Self, String> {
        unsafe {
            let ext = engine.ext;
            let device = engine.device;

            let pcr = VkPushConstantRange {
                stage_flags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: 8,
            };

            let dsl_ci = VkDescriptorSetLayoutCreateInfo {
                s_type: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                p_next: null(),
                flags: 0,
                binding_count: 1,
                p_bindings: &VkDescriptorSetLayoutBinding {
                    binding: 0,
                    descriptor_type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    descriptor_count: 1,
                    stage_flags: VK_SHADER_STAGE_COMPUTE_BIT,
                    p_immutable_samplers: null(),
                },
            };
            let mut desc_layout = null_mut();
            if with_desc {
                let r = (ext.vk_create_descriptor_set_layout)(device, &dsl_ci, null(), &mut desc_layout);
                if r != VK_SUCCESS || desc_layout.is_null() {
                    return Err(format!("vkCreateDescriptorSetLayout ({r})"));
                }
            }

            let pl_ci = VkPipelineLayoutCreateInfo {
                s_type: VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                p_next: null(),
                flags: 0,
                set_layout_count: if with_desc { 1 } else { 0 },
                p_set_layouts: if with_desc { &desc_layout } else { null() },
                push_constant_range_count: if with_push { 1 } else { 0 },
                p_push_constant_ranges: if with_push { &pcr } else { null() },
            };
            let mut pipeline_layout = null_mut();
            let r = (ext.vk_create_pipeline_layout)(device, &pl_ci, null(), &mut pipeline_layout);
            if r != VK_SUCCESS || pipeline_layout.is_null() {
                if !desc_layout.is_null() {
                    (ext.vk_destroy_descriptor_set_layout)(device, desc_layout, null());
                }
                return Err(format!("vkCreatePipelineLayout ({r})"));
            }

            let sm_ci = VkShaderModuleCreateInfo {
                s_type: crate::vulkan_host::VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                code_size: spirv.len() * 4,
                p_code: spirv.as_ptr(),
            };
            let mut shader_module = null_mut();
            let r = (ext.vk_create_shader_module)(device, &sm_ci, null(), &mut shader_module);
            if r != VK_SUCCESS || shader_module.is_null() {
                return Err(format!("vkCreateShaderModule ({r})"));
            }

            let stage = VkPipelineShaderStageCreateInfo {
                s_type: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                stage: VK_SHADER_STAGE_COMPUTE_BIT,
                module: shader_module,
                p_name: c"main".as_ptr(),
                p_specialization_info: null(),
            };
            let cp_ci = VkComputePipelineCreateInfo {
                s_type: VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                stage,
                layout: pipeline_layout,
                base_pipeline_handle: null_mut(),
                base_pipeline_index: -1,
            };
            let cache_ci = crate::vulkan_host::VkPipelineCacheCreateInfo {
                s_type: crate::vulkan_host::VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                initial_data_size: 0,
                p_initial_data: null(),
            };
            let mut cache: crate::vulkan_host::VkPipelineCache = null_mut();
            let cr = (ext.vk_create_pipeline_cache)(device, &cache_ci, null(), &mut cache);
            if cr != VK_SUCCESS || cache.is_null() {
                return Err(format!("vkCreatePipelineCache ({cr})"));
            }
            let mut pipeline = null_mut();
            let r = (ext.vk_create_compute_pipelines)(device, cache, 1, &cp_ci, null(), &mut pipeline);
            (ext.vk_destroy_pipeline_cache)(device, cache, null());
            if r != VK_SUCCESS || pipeline.is_null() {
                return Err(format!("vkCreateComputePipelines ({r})"));
            }

            // cleanup of the diagnostic pieces
            (ext.vk_destroy_pipeline)(device, pipeline, null());
            (ext.vk_destroy_pipeline_layout)(device, pipeline_layout, null());
            (ext.vk_destroy_shader_module)(device, shader_module, null());
            if !desc_layout.is_null() {
                (ext.vk_destroy_descriptor_set_layout)(device, desc_layout, null());
            }
            Ok(Self {
                desc_layout: null_mut(),
                desc_pool: null_mut(),
                desc_set: null_mut(),
                shader_module: null_mut(),
                pipeline_layout: null_mut(),
                pipeline: null_mut(),
                command_pool: null_mut(),
                command_buffer: null_mut(),
                device,
                queue: engine.queue,
                ext,
                bound_buffer: None,
                bound_memory: None,
                fill_based: true,
            })
        }
    }

    /// Internals of `create` parameterized by the SPIR-V module, so a
    /// failure reports exactly which shader failed to link.
    fn create_with(engine: &HostVulkanEngine, spirv: &[u32]) -> Result<Self, String> {
        let ext = engine.ext;
        let device = engine.device;
        let queue = engine.queue;
        unsafe {
            // ---- descriptor set layout: binding 0 = storage buffer ----
            let binding = VkDescriptorSetLayoutBinding {
                binding: 0,
                descriptor_type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptor_count: 1,
                stage_flags: VK_SHADER_STAGE_COMPUTE_BIT,
                p_immutable_samplers: null(),
            };
            let dsl_ci = VkDescriptorSetLayoutCreateInfo {
                s_type: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                p_next: null(),
                flags: 0,
                binding_count: 1,
                p_bindings: &binding,
            };
            let mut desc_layout = null_mut();
            let r = (ext.vk_create_descriptor_set_layout)(device, &dsl_ci, null(), &mut desc_layout);
            if r != VK_SUCCESS || desc_layout.is_null() {
                return Err(format!("vkCreateDescriptorSetLayout failed ({r})"));
            }

            // ---- descriptor pool: 1 storage-buffer descriptor ----
            let psize = VkDescriptorPoolSize {
                descriptor_type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptor_count: 1,
            };
            let dp_ci = VkDescriptorPoolCreateInfo {
                s_type: VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                p_next: null(),
                flags: 0,
                max_sets: 1,
                pool_size_count: 1,
                p_pool_sizes: &psize,
            };
            let mut desc_pool = null_mut();
            let r = (ext.vk_create_descriptor_pool)(device, &dp_ci, null(), &mut desc_pool);
            if r != VK_SUCCESS || desc_pool.is_null() {
                return Err(format!("vkCreateDescriptorPool failed ({r})"));
            }

            // ---- allocate the descriptor set ----
            let sa_ci = VkDescriptorSetAllocateInfo {
                s_type: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                p_next: null(),
                descriptor_pool: desc_pool,
                descriptor_set_count: 1,
                p_set_layouts: &desc_layout,
            };
            let mut desc_set: VkDescriptorSet = null_mut();
            let r = (ext.vk_allocate_descriptor_sets)(device, &sa_ci, &mut desc_set);
            if r != VK_SUCCESS || desc_set.is_null() {
                return Err(format!("vkAllocateDescriptorSets failed ({r})"));
            }

            // ---- shader module ----
            let sm_ci = VkShaderModuleCreateInfo {
                s_type: crate::vulkan_host::VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                code_size: spirv.len() * 4,
                p_code: spirv.as_ptr(),
            };
            let mut shader_module = null_mut();
            let r = (ext.vk_create_shader_module)(device, &sm_ci, null(), &mut shader_module);
            if r != VK_SUCCESS || shader_module.is_null() {
                return Err(format!(
                    "vkCreateShaderModule failed ({r}) — SPIR-V module rejected by driver"
                ));
            }

            // ---- pipeline layout: 1 set + push constants {w,h} ----
            let pcr = VkPushConstantRange {
                stage_flags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: 8,
            };
            let pl_ci = VkPipelineLayoutCreateInfo {
                s_type: VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                p_next: null(),
                flags: 0,
                set_layout_count: 1,
                p_set_layouts: &desc_layout,
                push_constant_range_count: 1,
                p_push_constant_ranges: &pcr,
            };
            let mut pipeline_layout = null_mut();
            let r = (ext.vk_create_pipeline_layout)(device, &pl_ci, null(), &mut pipeline_layout);
            if r != VK_SUCCESS || pipeline_layout.is_null() {
                return Err(format!("vkCreatePipelineLayout failed ({r})"));
            }

            // ---- compute pipeline ----
            let stage = VkPipelineShaderStageCreateInfo {
                s_type: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                stage: VK_SHADER_STAGE_COMPUTE_BIT,
                module: shader_module,
                p_name: c"main".as_ptr(),
                p_specialization_info: null(),
            };
            let cp_ci = VkComputePipelineCreateInfo {
                s_type: VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                stage,
                layout: pipeline_layout,
                base_pipeline_handle: null_mut(),
                base_pipeline_index: -1,
            };
            let cache_ci = crate::vulkan_host::VkPipelineCacheCreateInfo {
                s_type: crate::vulkan_host::VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
                p_next: null(),
                flags: 0,
                initial_data_size: 0,
                p_initial_data: null(),
            };
            let mut cache: crate::vulkan_host::VkPipelineCache = null_mut();
            let cr = (ext.vk_create_pipeline_cache)(device, &cache_ci, null(), &mut cache);
            if cr != VK_SUCCESS || cache.is_null() {
                return Err(format!("vkCreatePipelineCache failed ({cr})"));
            }
            let mut pipeline = null_mut();
            let r = (ext.vk_create_compute_pipelines)(device, cache, 1, &cp_ci, null(), &mut pipeline);
            (ext.vk_destroy_pipeline_cache)(device, cache, null());
            if r != VK_SUCCESS || pipeline.is_null() {
                return Err(format!("vkCreateComputePipelines failed ({r})"));
            }

            // ---- command pool + one primary command buffer ----
            let cp2_ci = VkCommandPoolCreateInfo {
                s_type: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                p_next: null(),
                flags: 0,
                queue_family_index: engine.queue_family_index,
            };
            let mut command_pool = null_mut();
            let r = (ext.vk_create_command_pool)(device, &cp2_ci, null(), &mut command_pool);
            if r != VK_SUCCESS || command_pool.is_null() {
                return Err(format!("vkCreateCommandPool failed ({r})"));
            }
            let cb_ai = VkCommandBufferAllocateInfo {
                s_type: crate::vulkan_host::VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                p_next: null(),
                command_pool,
                level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                command_buffer_count: 1,
            };
            let mut command_buffer: VkCommandBuffer = null_mut();
            let r = (ext.vk_allocate_command_buffers)(device, &cb_ai, &mut command_buffer);
            if r != VK_SUCCESS || command_buffer.is_null() {
                return Err(format!("vkAllocateCommandBuffers failed ({r})"));
            }

            Ok(Self {
                desc_layout,
                desc_pool,
                desc_set,
                shader_module,
                pipeline_layout,
                pipeline,
                command_pool,
                command_buffer,
                device,
                queue,
                ext,
                bound_buffer: None,
                bound_memory: None,
                fill_based: false,
            })
        }
    }

    /// Bind a guest-created (buffer, memory) pair: vkBindBufferMemory +
    /// (shader backend) vkUpdateDescriptorSets so the next RenderFrame
    /// dispatches into it.
    pub fn bind_buffer(&mut self, buffer: u64, memory: u64) -> Result<(), String> {
        let buffer = buffer as usize as VkBuffer;
        let memory = memory as usize as VkDeviceMemory;
        unsafe {
            let r = (self.ext.vk_bind_buffer_memory)(self.device, buffer, memory, 0);
            if r != VK_SUCCESS {
                return Err(format!("vkBindBufferMemory failed ({r})"));
            }
            if !self.desc_set.is_null() {
                let binfo = VkDescriptorBufferInfo {
                    buffer,
                    offset: 0,
                    range: VK_WHOLE_SIZE,
                };
                let write = VkWriteDescriptorSet {
                    s_type: crate::vulkan_host::VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    p_next: null(),
                    dst_set: self.desc_set,
                    dst_binding: 0,
                    dst_array_element: 0,
                    descriptor_count: 1,
                    descriptor_type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    p_image_info: null(),
                    p_buffer_info: &binfo,
                    p_texel_buffer_view: null(),
                };
                (self.ext.vk_update_descriptor_sets)(self.device, 1, &write, 0, null());
            }
        }
        self.bound_buffer = Some(buffer);
        self.bound_memory = Some(memory);
        Ok(())
    }

    /// HSV -> RGB (h in [0,360), s,v in [0,1]); returns (r,g,b) in [0,255].
    fn hsv_to_rgb(h: f32, s: f32, v: f32) -> (u8, u8, u8) {
        let c = v * s;
        let hp = (h / 60.0) % 6.0;
        let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
        let (r1, g1, b1) = match hp as u32 {
            0 => (c, x, 0.0),
            1 => (x, c, 0.0),
            2 => (0.0, c, x),
            3 => (0.0, x, c),
            4 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        let m = v - c;
        (
            ((r1 + m) * 255.0) as u8,
            ((g1 + m) * 255.0) as u8,
            ((b1 + m) * 255.0) as u8,
        )
    }

    /// Record + submit one frame of `width x height` pixels (BGRA8 in the
    /// storage buffer) and wait for the queue to drain. Shader backend:
    /// one compute dispatch. Fill backend: one vkCmdFillBuffer per scanline
    /// with the hue rotated per row (vertical rainbow).
    pub fn render_frame(&mut self, width: u32, height: u32) -> Result<(), String> {
        if self.bound_buffer.is_none() {
            return Err("no buffer bound yet (send BindRenderBuffer first)".to_string());
        }
        let buffer = self.bound_buffer.unwrap();

        unsafe {
            let begin = VkCommandBufferBeginInfo {
                s_type: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                p_next: null(),
                flags: VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                p_inheritance_info: null(),
            };
            let r = (self.ext.vk_begin_command_buffer)(self.command_buffer, &begin);
            if r != VK_SUCCESS {
                return Err(format!("vkBeginCommandBuffer failed ({r})"));
            }

            if self.fill_based {
                // One fill per scanline; color = hue(h * row/height) as BGRA.
                let row_bytes = (width as u64) * 4;
                for y in 0..height {
                    let hue = 360.0 * (y as f32) / (height as f32);
                    let (rr, gg, bb) = Self::hsv_to_rgb(hue, 1.0, 1.0);
                    // BGRA bytes -> LE u32: b | g<<8 | r<<16 | a<<24
                    let color = (bb as u32) | ((gg as u32) << 8) | ((rr as u32) << 16) | 0xFF00_0000;
                    (self.ext.vk_cmd_fill_buffer)(
                        self.command_buffer,
                        buffer,
                        (y as u64) * row_bytes,
                        row_bytes,
                        color,
                    );
                }
            } else {
                let groups_x = width.div_ceil(LOCAL_SIZE);
                let groups_y = height.div_ceil(LOCAL_SIZE);
                let push = [width, height];
                (self.ext.vk_cmd_bind_pipeline)(
                    self.command_buffer,
                    VK_PIPELINE_BIND_POINT_COMPUTE,
                    self.pipeline,
                );
                (self.ext.vk_cmd_bind_descriptor_sets)(
                    self.command_buffer,
                    VK_PIPELINE_BIND_POINT_COMPUTE,
                    self.pipeline_layout,
                    0,
                    1,
                    &self.desc_set,
                    0,
                    null(),
                );
                (self.ext.vk_cmd_push_constants)(
                    self.command_buffer,
                    self.pipeline_layout,
                    VK_SHADER_STAGE_COMPUTE_BIT,
                    0,
                    8,
                    push.as_ptr() as *const _,
                );
                (self.ext.vk_cmd_dispatch)(self.command_buffer, groups_x, groups_y, 1);
            }

            let r = (self.ext.vk_end_command_buffer)(self.command_buffer);
            if r != VK_SUCCESS {
                return Err(format!("vkEndCommandBuffer failed ({r})"));
            }

            let si = VkSubmitInfo {
                s_type: VK_STRUCTURE_TYPE_SUBMIT_INFO,
                p_next: null(),
                wait_semaphore_count: 0,
                p_wait_semaphores: null(),
                p_wait_dst_stage_mask: null(),
                command_buffer_count: 1,
                p_command_buffers: (&self.command_buffer as *const VkCommandBuffer) as *const _,
                signal_semaphore_count: 0,
                p_signal_semaphores: null(),
            };
            let r = (self.ext.vk_queue_submit)(self.queue, 1, &si, null_mut());
            if r != VK_SUCCESS {
                return Err(format!("vkQueueSubmit(render) failed ({r})"));
            }
            let r = (self.ext.vk_queue_wait_idle)(self.queue);
            if r != VK_SUCCESS {
                return Err(format!("vkQueueWaitIdle failed ({r})"));
            }
        }
        Ok(())
    }

    /// Map the bound (host-visible, coherent) memory and copy `size` bytes
    /// back to the caller. Returns raw BGRA bytes.
    pub fn read_pixels(&mut self, size: u64) -> Result<Vec<u8>, String> {
        let memory = self
            .bound_memory
            .ok_or_else(|| "no memory bound yet (send BindRenderBuffer first)".to_string())?;
        unsafe {
            let mut ptr: *mut std::ffi::c_void = null_mut();
            let r = (self.ext.vk_map_memory)(self.device, memory, 0, size, 0, &mut ptr);
            if r != VK_SUCCESS || ptr.is_null() {
                return Err(format!("vkMapMemory failed ({r})"));
            }
            let bytes = std::slice::from_raw_parts(ptr as *const u8, size as usize).to_vec();
            (self.ext.vk_unmap_memory)(self.device, memory);
            Ok(bytes)
        }
    }

    pub fn is_ready(&self) -> bool {
        self.bound_buffer.is_some() && self.bound_memory.is_some()
    }

    pub fn fill_based(&self) -> bool {
        self.fill_based
    }
}

impl Drop for RenderPipeline {
    fn drop(&mut self) {
        unsafe {
            if !self.command_buffer.is_null() {
                (self.ext.vk_free_command_buffers)(self.device, self.command_pool, 1, &self.command_buffer);
            }
            if !self.command_pool.is_null() {
                (self.ext.vk_destroy_command_pool)(self.device, self.command_pool, null());
            }
            if !self.pipeline.is_null() {
                (self.ext.vk_destroy_pipeline)(self.device, self.pipeline, null());
            }
            if !self.pipeline_layout.is_null() {
                (self.ext.vk_destroy_pipeline_layout)(self.device, self.pipeline_layout, null());
            }
            if !self.shader_module.is_null() {
                (self.ext.vk_destroy_shader_module)(self.device, self.shader_module, null());
            }
            if !self.desc_pool.is_null() {
                (self.ext.vk_destroy_descriptor_pool)(self.device, self.desc_pool, null());
            }
            if !self.desc_layout.is_null() {
                (self.ext.vk_destroy_descriptor_set_layout)(self.device, self.desc_layout, null());
            }
        }
    }
}