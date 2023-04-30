package main

import "../aoc"

import "core:os"
import "core:strings"
import "core:strconv"
import "core:mem"
import "core:fmt"
import "core:math"
import vk "vendor:vulkan"

SHADER :: "./shaders/day3/comp.spv"
GROUP_SHADER :: "./shaders/day3/group.spv"
DAY_INPUT :: "./input/day3.txt"

main :: proc() {
    // initialize our vulkan context
    aoc.compute_init()

    input, input_ok := os.read_entire_file(DAY_INPUT)
    assert(input_ok)

    lines := strings.split_lines(string(input), context.temp_allocator) or_else []string{}
    max_pocket_size := 0
    max_backpack_size := 0
    for line in lines {
        max_pocket_size = max(max_pocket_size, len(line) / 2)
        max_backpack_size = max(max_backpack_size, len(line))
    }
    max_pocket_size = max(max_pocket_size, 32) // need to align with gpu
    max_backpack_size = max(max_backpack_size, 64) // align with gpu also


    data := make([]i32, len(lines) *  2 * max_pocket_size)
    backpack_data := make([]i32, len(lines) * max_backpack_size)
    for line, i in lines {
        as_u8 := transmute([]u8) line
        for c, j in as_u8[:len(as_u8)/2] {
            if c >= 'a' && c <= 'z' {
                data[(2 * i) * max_pocket_size + j] = i32(c - 'a' + 1)
            } else {
                assert(c >= 'A' && c <= 'Z')
                data[(2 * i) * max_pocket_size + j] = i32(c - 'A' + 27)
            }
        }
        for c, j in as_u8[len(as_u8)/2:] {
            if c >= 'a' && c <= 'z' {
                data[(2 * i + 1) * max_pocket_size + j] = i32(c - 'a' + 1)
            } else {
                assert(c >= 'A' && c <= 'Z')
                data[(2 * i + 1) * max_pocket_size + j] = i32(c - 'A' + 27)
            }
        }
        for c, j in as_u8 {
            if c >= 'a' && c <= 'z' {
                backpack_data[i * max_backpack_size + j] = i32(c - 'a' + 1)
            } else {
                assert(c >= 'A' && c <= 'Z')
                backpack_data[i * max_backpack_size + j] = i32(c - 'A' + 27)
            }
        }
    }

    output := make([]i32, len(lines))
    output_group := make([]i32, len(lines) / 3)
    fmt.println(len(output_group))

    shader, shader_ok := os.read_entire_file(SHADER)
    group_shader, group_s_ok := os.read_entire_file(GROUP_SHADER)
    assert(shader_ok)
    assert(group_s_ok)

    bindings := []vk.DescriptorSetLayoutBinding{
        {
            binding = 0,
            descriptorCount = 1,
            descriptorType = .STORAGE_BUFFER,
            stageFlags = {.COMPUTE},
        },
        {
            binding = 1,
            descriptorCount = 1,
            descriptorType = .STORAGE_BUFFER,
            stageFlags = {.COMPUTE},
        },
    }

    pipeline := aoc.compute_pipeline_create(1, shader, bindings)
    group_pipeline := aoc.compute_pipeline_create(1, group_shader, bindings)

    assert(pipeline.device == group_pipeline.device)


    data_buffer, data_memory := aoc.create_buffer(vk.DeviceSize(size_of(i32) * len(data)), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})
    output_buffer, output_memory := aoc.create_buffer(vk.DeviceSize(size_of(i32) * len(output)), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})
    
    backpack_buffer, backpack_memory := aoc.create_buffer(vk.DeviceSize(size_of(i32) * len(backpack_data)), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})
    output_buffer_group, output_memory_group := aoc.create_buffer(vk.DeviceSize(size_of(i32) * len(output)), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})

    raw_inputs, raw_backpack, raw_outputs, raw_outputs_group: rawptr
    vk.MapMemory(pipeline.device, data_memory, 0, vk.DeviceSize(size_of(i32) * len(data)), nil, &raw_inputs)
    vk.MapMemory(pipeline.device, output_memory, 0, vk.DeviceSize(size_of(i32) * len(output)), nil, &raw_outputs)
    
    vk.MapMemory(group_pipeline.device, backpack_memory, 0, vk.DeviceSize(size_of(i32) * len(backpack_data)), nil, &raw_backpack)
    vk.MapMemory(group_pipeline.device, output_memory_group, 0, vk.DeviceSize(size_of(i32) * len(output_group)), nil, &raw_outputs_group)

    mem.copy(raw_inputs, raw_data(data), size_of(i32) * len(data))
    mem.copy(raw_backpack, raw_data(backpack_data), size_of(i32) * len(backpack_data))

    compute_fence, compute_fence_group: vk.Fence
    aoc.vk_assert(vk.CreateFence(pipeline.device, &vk.FenceCreateInfo{
        sType = .FENCE_CREATE_INFO,
        flags = {.SIGNALED},
    }, nil, &compute_fence))
    aoc.vk_assert(vk.CreateFence(group_pipeline.device, &vk.FenceCreateInfo{
        sType = .FENCE_CREATE_INFO,
        flags = {.SIGNALED},
    }, nil, &compute_fence_group))

    { // PART 1 - Compute priority issues based on elements in each pocket
    
        write_descriptors := []vk.WriteDescriptorSet{
            { // Input data
                sType = .WRITE_DESCRIPTOR_SET,
                dstSet = pipeline.descriptor_sets[0],
                dstBinding = 0,
                dstArrayElement = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &vk.DescriptorBufferInfo{
                    buffer = data_buffer,
                    offset = 0,
                    range = vk.DeviceSize(size_of(i32) * len(data)),
                },
            },
            { // Output priorities
                sType = .WRITE_DESCRIPTOR_SET,
                dstSet = pipeline.descriptor_sets[0],
                dstBinding = 1,
                dstArrayElement = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &vk.DescriptorBufferInfo{
                    buffer = output_buffer,
                    offset = 0,
                    range = vk.DeviceSize(size_of(i32) * len(output)),
                },
            },
        }
        vk.UpdateDescriptorSets(pipeline.device, u32(len(write_descriptors)), raw_data(write_descriptors), 0, nil)

        mem.zero_explicit(raw_outputs, size_of(i32) * len(output))

        // Actually get GPU to do the work
        vk.ResetFences(pipeline.device, 1, &compute_fence)

        command_buffer := pipeline.command_buffers[0]
        aoc.vk_assert(vk.ResetCommandBuffer(command_buffer, {}))
        aoc.vk_assert(vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            sType = .COMMAND_BUFFER_BEGIN_INFO,
        }))

        vk.CmdBindPipeline(command_buffer, .COMPUTE, pipeline.pipeline)
        vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, pipeline.layout, 0, 1, &pipeline.descriptor_sets[0], 0, nil)
        vk.CmdDispatch(command_buffer, u32(len(output)), 1, 1)
        aoc.vk_assert(vk.EndCommandBuffer(command_buffer))

        compute_dst_stage_mask := vk.PipelineStageFlags{.COMPUTE_SHADER}

        aoc.vk_assert(vk.QueueSubmit(pipeline.queue, 1, &vk.SubmitInfo{
            sType = .SUBMIT_INFO,
            commandBufferCount = 1,
            pCommandBuffers = &command_buffer,
            pWaitDstStageMask = &compute_dst_stage_mask,
        }, compute_fence))
    }


    { // PART 2 - compute priorities based on groups of 3 backpacks
        write_descriptors := []vk.WriteDescriptorSet{
            { // Input data
                sType = .WRITE_DESCRIPTOR_SET,
                dstSet = group_pipeline.descriptor_sets[0],
                dstBinding = 0,
                dstArrayElement = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &vk.DescriptorBufferInfo{
                    buffer = backpack_buffer,
                    offset = 0,
                    range = vk.DeviceSize(size_of(i32) * len(backpack_data)),
                },
            },
            { // Output priorities
                sType = .WRITE_DESCRIPTOR_SET,
                dstSet = group_pipeline.descriptor_sets[0],
                dstBinding = 1,
                dstArrayElement = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &vk.DescriptorBufferInfo{
                    buffer = output_buffer_group,
                    offset = 0,
                    range = vk.DeviceSize(size_of(i32) * len(output_group)),
                },
            },
        }
        vk.UpdateDescriptorSets(group_pipeline.device, u32(len(write_descriptors)), raw_data(write_descriptors), 0, nil)

        mem.zero_explicit(raw_outputs_group, size_of(i32) * len(output_group))

        // Actually get GPU to do the work
        vk.ResetFences(group_pipeline.device, 1, &compute_fence_group)

        command_buffer := group_pipeline.command_buffers[0]
        aoc.vk_assert(vk.ResetCommandBuffer(command_buffer, {}))
        aoc.vk_assert(vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            sType = .COMMAND_BUFFER_BEGIN_INFO,
        }))

        vk.CmdBindPipeline(command_buffer, .COMPUTE, group_pipeline.pipeline)
        vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, group_pipeline.layout, 0, 1, &group_pipeline.descriptor_sets[0], 0, nil)
        vk.CmdDispatch(command_buffer, u32(len(output_group)), 1, 1)
        aoc.vk_assert(vk.EndCommandBuffer(command_buffer))

        compute_dst_stage_mask := vk.PipelineStageFlags{.COMPUTE_SHADER}

        aoc.vk_assert(vk.QueueSubmit(group_pipeline.queue, 1, &vk.SubmitInfo{
            sType = .SUBMIT_INFO,
            commandBufferCount = 1,
            pCommandBuffers = &command_buffer,
            pWaitDstStageMask = &compute_dst_stage_mask,
        }, compute_fence_group))
    }

    // wait for both fences
    aoc.vk_assert(vk.WaitForFences(pipeline.device, 2, raw_data([]vk.Fence{compute_fence, compute_fence_group}), true, max(u64)))

    { // Print result 1
        mem.copy(raw_data(output), raw_outputs, size_of(i32) * len(output))
        result := math.sum(output)
        fmt.println("Part1:", result)
    }
    { // Print result 2
        mem.copy(raw_data(output_group), raw_outputs_group, size_of(i32) * len(output_group))
        result := math.sum(output_group)
        fmt.println("Part2:", result)
    }
}