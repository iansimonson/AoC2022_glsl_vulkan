package aoc

import vk "vendor:vulkan"

import "core:fmt"
import "core:runtime"

create_buffer :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) -> (buffer: vk.Buffer, memory: vk.DeviceMemory) {
    return create_buffer_device(global_vulkan_context.physical_device, global_vulkan_context.device, size, usage, properties)
}

create_buffer_device :: proc(physical_device: vk.PhysicalDevice, device: vk.Device, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) -> (buffer: vk.Buffer, memory: vk.DeviceMemory) {
	buffer_info := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = usage,
		sharingMode = .EXCLUSIVE,
	}

	if vk.CreateBuffer(device, &buffer_info, nil, &buffer) != .SUCCESS {
		fmt.panicf("Failed to create buffer: {%v, %v, %v}\n", size, usage, properties)
	}

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &mem_requirements)

	alloc_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = mem_requirements.size,
		memoryTypeIndex = find_memory_type(physical_device, mem_requirements.memoryTypeBits, properties),
	}

	if vk.AllocateMemory(device, &alloc_info, nil, &memory) != .SUCCESS {
		fmt.panicf("failed to allocate memory for the buffer: {%v, %v, %v}\n", size, usage, properties)
	}

	vk.BindBufferMemory(device, buffer, memory, 0)

	return
}

find_memory_type :: proc(physical_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties)

	for i in 0..<mem_properties.memoryTypeCount {
		if type_filter & (1 << i) != 0 && (mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
			return i
		}
	}

	panic("Failed to find suitable memory type!")

}

debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_type: vk.DebugUtilsMessageTypeFlagsEXT,
	p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	p_user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
    fmt.println()
    fmt.printf("MESSAGE: (")
    for ms in vk.DebugUtilsMessageSeverityFlagEXT {
        if ms in message_severity {
            fmt.printf("%v, ", ms)
        }
    }
    for t in vk.DebugUtilsMessageTypeFlagEXT {
        if t in message_type {
            fmt.printf("%v", t)
        }
    }
    fmt.printf(")\n")
    fmt.println("---------------")
    fmt.printf("%#v\n", p_callback_data.pMessage)
    fmt.println()

	return false
}