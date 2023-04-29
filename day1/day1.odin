package main

import "../aoc"

import "core:os"
import "core:strings"
import "core:strconv"
import "core:mem"
import "core:fmt"
import vk "vendor:vulkan"

main :: proc() {

    input, input_ok := os.read_entire_file(DAY_INPUT)
    assert(input_ok)

    values := make([dynamic][dynamic]int, 0, 1000)
    max_rows, max_cols := 0, 0
    sections, _ := strings.split(string(input), "\n\n", context.temp_allocator)
    for section in sections {
        lines := strings.split(section, "\n", context.temp_allocator)
        row := make([dynamic]int, 0, 100)
        cols := 0
        for line in lines {
            value, v_ok := strconv.parse_int(line)
            assert(v_ok)
            append(&row, value)
            cols += 1
        }
        append(&values, row)
        max_rows += 1
        max_cols = max(max_cols, cols)
        assert(max_rows == len(values))
    }

    // normalize all rows to have the same number of values
    for row in &values {
        if len(row) < max_cols {
            for i in len(row)..<max_cols {
                append(&row, 0)
            }
        }
    }

    flattened := make([dynamic]i32, 0, max_rows * max_cols)
    for row in values {
        for v in row {
            append(&flattened, i32(v))
        }
    }

    // now we can read from the output buffer
    result := make([dynamic]i32, max_rows)

    fmt.println(values[:5])
    assert(len(values[0]) == len(values[1]))

    // initialize our vulkan context
    aoc.compute_init()

    sum_shader, shader_ok := os.read_entire_file(SUM_SHADER)
    sort_shader, sort_ok := os.read_entire_file(SORT_SHADER)
    assert(shader_ok)
    assert(sort_ok)

    // Set up our compute pipeline based on the shader requirements
    layout_bindings := []vk.DescriptorSetLayoutBinding{
        {
            binding = 0,
            descriptorCount = 1,
            descriptorType = .UNIFORM_BUFFER,
            stageFlags = {.COMPUTE},
        },
        {
            binding = 1,
            descriptorCount = 1,
            descriptorType = .STORAGE_BUFFER,
            stageFlags = {.COMPUTE},
        },
        {
            binding = 2,
            descriptorCount = 1,
            descriptorType = .STORAGE_BUFFER,
            stageFlags = {.COMPUTE},
        },
    }
    sum_pipeline := aoc.compute_pipeline_create(1, sum_shader, layout_bindings)


    // could get fancy and put this all into a single buffer BUT lets be lazy and make a buffer per object
    // doing 2 i32s because we're going to reuse this for both compute shaders
    param_buffer, memory := aoc.create_buffer(size_of(i32) * 2, {.UNIFORM_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})    
    
    input_buffer, input_memory := aoc.create_buffer(vk.DeviceSize(size_of(i32) * max_rows * max_cols), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})
    output_buffer, output_memory := aoc.create_buffer(vk.DeviceSize(size_of(i32) * max_rows), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})

    raw_param, raw_input, raw_output: rawptr
    vk.MapMemory(sum_pipeline.device, memory, 0, size_of(i32), nil, &raw_param)
    vk.MapMemory(sum_pipeline.device, input_memory, 0, vk.DeviceSize(size_of(i32) * max_rows * max_cols), nil, &raw_input)
    vk.MapMemory(sum_pipeline.device, output_memory, 0, vk.DeviceSize(size_of(i32) * max_rows), nil, &raw_output)

    max_cols_as_i32 := i32(max_cols)
    mem.copy(raw_param, &max_cols_as_i32, size_of(i32))
    mem.copy(raw_input, raw_data(flattened[:]), size_of(i32) * max_rows * max_cols)

    // we only have one descriptor set so just update for that one
    write_descriptor_sets := []vk.WriteDescriptorSet{
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = sum_pipeline.descriptor_sets[0],
            dstBinding = 0,
            dstArrayElement = 0,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = param_buffer,
                offset = 0,
                range = size_of(i32),
            },
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = sum_pipeline.descriptor_sets[0],
            dstBinding = 1,
            dstArrayElement = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = input_buffer,
                offset = 0,
                range = vk.DeviceSize(size_of(i32) * max_rows * max_cols),
            },
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = sum_pipeline.descriptor_sets[0],
            dstBinding = 2,
            dstArrayElement = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = output_buffer,
                offset = 0,
                range = vk.DeviceSize(size_of(i32) * max_rows),
            },
        },
    }
    vk.UpdateDescriptorSets(sum_pipeline.device, u32(len(write_descriptor_sets)), raw_data(write_descriptor_sets), 0, nil)

    layout_bindings = []vk.DescriptorSetLayoutBinding{
        {
            binding = 0,
            descriptorCount = 1,
            descriptorType = .UNIFORM_BUFFER,
            stageFlags = {.COMPUTE},
        },
        {
            binding = 1,
            descriptorCount = 1,
            descriptorType = .STORAGE_BUFFER,
            stageFlags = {.COMPUTE},  
        },
    }
    sort_pipeline := aoc.compute_pipeline_create(1, sort_shader, layout_bindings)

    // Reuse the same buffers from before (we will make sure to barrier between)
    write_descriptor_sets = []vk.WriteDescriptorSet{
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = sort_pipeline.descriptor_sets[0],
            dstBinding = 0,
            dstArrayElement = 0,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = param_buffer,
                offset = 0,
                range = size_of(i32) * 2,
            },
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = sort_pipeline.descriptor_sets[0],
            dstBinding = 1,
            dstArrayElement = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = output_buffer,
                offset = 0,
                range = vk.DeviceSize(size_of(i32) * max_rows),
            },
        },
    }
    vk.UpdateDescriptorSets(sort_pipeline.device, u32(len(write_descriptor_sets)), raw_data(write_descriptor_sets), 0, nil)


    compute_fence: vk.Fence
    // Create an end of compute fence so we know it's ok to read from the output:
    aoc.vk_assert(vk.CreateFence(sum_pipeline.device, &vk.FenceCreateInfo{
        sType = .FENCE_CREATE_INFO,
        flags = {.SIGNALED},
    }, nil, &compute_fence))

    vk.ResetFences(sum_pipeline.device, 1, &compute_fence)
    command_buffer := sum_pipeline.command_buffers[0]
    aoc.vk_assert(vk.ResetCommandBuffer(command_buffer, {}))
    aoc.vk_assert(vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
    }))

    fmt.println(max_rows, max_cols)

    
    vk.CmdBindPipeline(command_buffer, .COMPUTE, sum_pipeline.pipeline)
	vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, sum_pipeline.layout, 0, 1, &sum_pipeline.descriptor_sets[0], 0, nil)
    vk.CmdDispatch(command_buffer, 1 + (u32(max_cols) / 256), 1, 1)
    aoc.vk_assert(vk.EndCommandBuffer(command_buffer))

    compute_dst_stage_mask := vk.PipelineStageFlags{.COMPUTE_SHADER}

    aoc.vk_assert(vk.QueueSubmit(sum_pipeline.queue, 1, &vk.SubmitInfo{
        sType = .SUBMIT_INFO,
        commandBufferCount = 1,
        pCommandBuffers = &command_buffer,
        pWaitDstStageMask = &compute_dst_stage_mask,
    }, compute_fence))
    
    aoc.vk_assert(vk.WaitForFences(sum_pipeline.device, 1, &compute_fence, true, max(u64)))

    max_rows_as_i32 := i32(max_rows)
    mem.copy(raw_param, &max_rows_as_i32, size_of(i32))

    for i in 0..<max_rows { // bubble sort guaranteed to finish after N runs
        odd: b32 = (i % 2 == 1)
        mem.copy(rawptr(uintptr(raw_param) + uintptr(size_of(i32))), &odd, size_of(odd))
        vk.ResetFences(sum_pipeline.device, 1, &compute_fence)
        command_buffer = sort_pipeline.command_buffers[0]
        aoc.vk_assert(vk.ResetCommandBuffer(command_buffer, {}))
        aoc.vk_assert(vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            sType = .COMMAND_BUFFER_BEGIN_INFO,
        }))

        vk.CmdBindPipeline(command_buffer, .COMPUTE, sort_pipeline.pipeline)
	    vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, sort_pipeline.layout, 0, 1, &sort_pipeline.descriptor_sets[0], 0, nil)
        vk.CmdDispatch(command_buffer, u32(max_rows / 256) / 2 + 1, 1, 1)
        aoc.vk_assert(vk.EndCommandBuffer(command_buffer))
        
        aoc.vk_assert(vk.QueueSubmit(sort_pipeline.queue, 1, &vk.SubmitInfo{
            sType = .SUBMIT_INFO,
            commandBufferCount = 1,
            pCommandBuffers = &command_buffer,
            pWaitDstStageMask = &compute_dst_stage_mask,
        }, compute_fence))
        
        aoc.vk_assert(vk.WaitForFences(sort_pipeline.device, 1, &compute_fence, true, max(u64)))
    }

    // vk.DeviceWaitIdle(compute_pipeline.device)

    mem.copy(raw_data(result[:]), raw_output, size_of(i32) * max_rows)

    fmt.println("Part1: ", result[0])
    fmt.println("Part2: ", result[0] + result[1] + result[2])
}


SHADER_DIRECTORY :: "./shaders/day1/"
SUM_SHADER :: "./shaders/day1/sum_comp.spv"
SORT_SHADER :: "./shaders/day1/sort_comp.spv"
DAY_INPUT :: "./input/day1.txt"