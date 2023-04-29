package aoc

import vk "vendor:vulkan"
import "vendor:glfw"

import "core:strings"

ComputePipeline :: struct {
    using vulkan_context: VkContext,
    queue: vk.Queue,
    layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    descriptor_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [dynamic]vk.DescriptorSet,
    command_pool: vk.CommandPool,
    command_buffers: [dynamic]vk.CommandBuffer,
}

VkContext :: struct {
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    queue_family: u32,
    debug_messenger: vk.DebugUtilsMessengerEXT,
}

global_vulkan_context := VkContext{}

compute_init :: proc() {
    glfw.Init()
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

    instance_extensions := [?]cstring{
        vk.EXT_DEBUG_UTILS_EXTENSION_NAME,
    }
    validation_layers := []cstring{"VK_LAYER_KHRONOS_validation"}

    enabled := []vk.ValidationFeatureEnableEXT{.DEBUG_PRINTF}
    features := vk.ValidationFeaturesEXT{
        sType = .VALIDATION_FEATURES_EXT,
        enabledValidationFeatureCount = 1,
        pEnabledValidationFeatures = raw_data(enabled),
    }
    vk_assert(vk.CreateInstance(&vk.InstanceCreateInfo{
        sType = .INSTANCE_CREATE_INFO,
        enabledExtensionCount = 1,
        ppEnabledExtensionNames = raw_data(instance_extensions[:]),
        pApplicationInfo = &vk.ApplicationInfo{
            apiVersion = vk.API_VERSION_1_3,
        },
        pNext = &features,
        enabledLayerCount = u32(len(validation_layers)),
        ppEnabledLayerNames = raw_data(validation_layers),
    }, nil, &global_vulkan_context.instance))

    vk.GetInstanceProcAddr = get_instance_proc_addr
	vk.load_proc_addresses(global_vulkan_context.instance)

    vk.CreateDebugUtilsMessengerEXT(global_vulkan_context.instance, &vk.DebugUtilsMessengerCreateInfoEXT{
        sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
        messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
        pfnUserCallback = debug_callback,
    }, nil, &global_vulkan_context.debug_messenger)

    { // Setup Physical Device
        device_count: u32
        vk.EnumeratePhysicalDevices(global_vulkan_context.instance, &device_count, nil)
        devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
        vk.EnumeratePhysicalDevices(global_vulkan_context.instance, &device_count, raw_data(devices))
        physical_device := devices[0]
        global_vulkan_context.physical_device = physical_device
    }

    { // Setup devices
        using global_vulkan_context
        
        compute_family: u32 = 1000
        // ensure our device can support compute queue
        queue_family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
        queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, raw_data(queue_families))

        for queue_family, i in queue_families {
            if .COMPUTE in queue_family.queueFlags {
                compute_family = u32(i)
                break
            }
        }

        device_features := vk.PhysicalDeviceFeatures{
            samplerAnisotropy = true,
        }

        device_extensions := make([]cstring, len(DEVICE_EXTENSION_LIST), context.temp_allocator)
        for ext, i in DEVICE_EXTENSION_LIST {
            device_extensions[i] = strings.clone_to_cstring(ext, context.temp_allocator)
        }

        priority: f32 = 1.0

        vk_assert(vk.CreateDevice(physical_device, &vk.DeviceCreateInfo{
            sType = .DEVICE_CREATE_INFO,
            pQueueCreateInfos = &vk.DeviceQueueCreateInfo{
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = compute_family,
                queueCount = 1,
                pQueuePriorities = &priority,
            },
            queueCreateInfoCount = 1,
            pEnabledFeatures = &device_features,
            enabledExtensionCount = u32(len(device_extensions)),
            ppEnabledExtensionNames = raw_data(device_extensions),
            pNext = &vk.PhysicalDeviceSynchronization2Features{
                sType = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
                synchronization2 = true,
                pNext = &vk.PhysicalDeviceMaintenance4Features{
                    sType = .PHYSICAL_DEVICE_MAINTENANCE_4_FEATURES,
                    maintenance4 = true,
                },
            },
        }, nil, &global_vulkan_context.device))
    }
}

// will create descriptor pool size equal to num_frames * resources required for all descripotr layout bindings
compute_pipeline_create :: proc(num_frames: int, shader_code: []byte, layout_bindings: []vk.DescriptorSetLayoutBinding) -> (pipeline: ComputePipeline) {

    using global_vulkan_context

    pipeline.vulkan_context = global_vulkan_context

    vk.GetDeviceQueue(device, queue_family, 0, &pipeline.queue)

    compute_shader_module := create_shader_module(device, shader_code)
    defer vk.DestroyShaderModule(device, compute_shader_module, nil)

    vk_assert(vk.CreateDescriptorSetLayout(device, &vk.DescriptorSetLayoutCreateInfo{
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = u32(len(layout_bindings)),
        pBindings = raw_data(layout_bindings),
    }, nil, &pipeline.descriptor_layout))

    vk_assert(vk.CreatePipelineLayout(device, &vk.PipelineLayoutCreateInfo{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &pipeline.descriptor_layout,
    }, nil, &pipeline.layout))

    vk_assert(vk.CreateComputePipelines(device, {}, 1, &vk.ComputePipelineCreateInfo{
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        layout = pipeline.layout,
            stage = vk.PipelineShaderStageCreateInfo{
                sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
                stage = {.COMPUTE},
                module = compute_shader_module,
                pName = "main",
            },
    }, nil, &pipeline.pipeline))

    vk_assert(vk.CreateCommandPool(device, &vk.CommandPoolCreateInfo{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.RESET_COMMAND_BUFFER},
        queueFamilyIndex = queue_family,
    }, nil, &pipeline.command_pool))

    resize(&pipeline.command_buffers, num_frames)

    vk_assert(vk.AllocateCommandBuffers(device, &vk.CommandBufferAllocateInfo{
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = pipeline.command_pool,
        level = .PRIMARY,
        commandBufferCount = u32(num_frames),
    }, raw_data(pipeline.command_buffers[:])))

    pool_sizes := make([dynamic]vk.DescriptorPoolSize, 0, 10, context.temp_allocator)
    for layout_binding in layout_bindings {
        append(&pool_sizes, vk.DescriptorPoolSize{
            type = layout_binding.descriptorType,
            descriptorCount = layout_binding.descriptorCount * u32(num_frames),
        })
    }

    vk_assert(vk.CreateDescriptorPool(device, &vk.DescriptorPoolCreateInfo{
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        poolSizeCount = u32(len(pool_sizes)),
        pPoolSizes = raw_data(pool_sizes),
        maxSets = u32(num_frames),
    }, nil, &pipeline.descriptor_pool))

    set_layouts := make([dynamic]vk.DescriptorSetLayout, 0, num_frames, context.temp_allocator)
    for i in 0..<num_frames {
        append(&set_layouts, pipeline.descriptor_layout)
    }
    resize(&pipeline.descriptor_sets, num_frames)

    vk_assert(vk.AllocateDescriptorSets(device, &vk.DescriptorSetAllocateInfo{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = pipeline.descriptor_pool,
        descriptorSetCount = u32(num_frames),
        pSetLayouts = raw_data(set_layouts),
    }, raw_data(pipeline.descriptor_sets[:])))

    return
}

create_shader_module :: proc(device: vk.Device, code: []byte) -> (sm: vk.ShaderModule) {
	vk_assert(vk.CreateShaderModule(
		   device,
		   &vk.ShaderModuleCreateInfo{
			   sType = .SHADER_MODULE_CREATE_INFO,
			   codeSize = len(code),
			   pCode = (^u32)(raw_data(code)),
		   },
		   nil,
		   &sm,
	   ))
	return
}

DEVICE_EXTENSION_LIST := [?]string{
    vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
}

compute_destroy :: proc() {
    defer glfw.Terminate()
}

vk_assert :: proc(result: vk.Result, loc := #caller_location) {
    assert(result == .SUCCESS, "vulkan returned non-success result", loc)
}

get_instance_proc_addr :: proc "system" (
    instance: vk.Instance,
    name: cstring,
) -> vk.ProcVoidFunction {
    f := glfw.GetInstanceProcAddress(instance, name)
    return (vk.ProcVoidFunction)(f)
}