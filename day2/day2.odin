package main

import "../aoc"

import "core:os"
import "core:strings"
import "core:strconv"
import "core:mem"
import "core:fmt"
import vk "vendor:vulkan"

SCORE_SHADER :: "./shaders/day2/score.spv"
DAY_INPUT :: "./input/day2.txt"

// more of a stack/transfer buffer but whatever
Params :: struct {
    is_score: b32,
    final_score: i32,
}

GROUP_SIZE :: 256
GROUP_DATA_SIZE :: 2 * GROUP_SIZE

main :: proc() {

    input, input_ok := os.read_entire_file(DAY_INPUT)
    assert(input_ok)

    opponents := make([dynamic]i32)
    ours := make([dynamic]i32)

    lines := strings.split(string(input), "\n", context.temp_allocator)
    for line in lines {
        append(&opponents, i32(line[0] - 'A') + 1)
        append(&ours, i32(line[2] - 'X') + 1)
    }

    assert(len(opponents) == len(ours))
    data_length := len(opponents)
    gpu_padding := (GROUP_DATA_SIZE) - (data_length % (GROUP_DATA_SIZE))

    resize(&opponents, data_length + gpu_padding)
    resize(&ours, data_length + gpu_padding)

    data_length = len(opponents)
    output_scores_len := data_length / GROUP_DATA_SIZE;
    outputs := make([dynamic]i32, output_scores_len)

    // initialize our vulkan context
    aoc.compute_init()

    shader, shader_ok := os.read_entire_file(SCORE_SHADER)
    assert(shader_ok)

    bindings := []vk.DescriptorSetLayoutBinding{
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
        {
            binding = 3,
            descriptorCount = 1,
            descriptorType = .STORAGE_BUFFER,
            stageFlags = {.COMPUTE},
        },
    }

    pipeline := aoc.compute_pipeline_create(1, shader, bindings)


    param_buffer, memory := aoc.create_buffer(size_of(Params), {.UNIFORM_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})
    data_buffer, data_memory := aoc.create_buffer(vk.DeviceSize(size_of(i32) * data_length * 2), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})
    output_buffer, output_memory := aoc.create_buffer(vk.DeviceSize(size_of(i32) * output_scores_len), {.STORAGE_BUFFER}, {.HOST_COHERENT, .HOST_VISIBLE})

    raw_param, raw_inputs, raw_outputs: rawptr
    vk.MapMemory(pipeline.device, memory, 0, size_of(Params), nil, &raw_param)
    vk.MapMemory(pipeline.device, data_memory, 0, vk.DeviceSize(size_of(i32) * data_length * 2), nil, &raw_inputs)
    vk.MapMemory(pipeline.device, output_memory, 0, vk.DeviceSize(size_of(i32) * output_scores_len), nil, &raw_outputs)

    mem.copy(raw_inputs, raw_data(opponents[:]), size_of(i32) * data_length)
    mem.copy(rawptr(uintptr(raw_inputs) + uintptr(size_of(i32) * data_length)), raw_data(ours[:]), size_of(i32) * data_length)

    compute_fence: vk.Fence
    aoc.vk_assert(vk.CreateFence(pipeline.device, &vk.FenceCreateInfo{
        sType = .FENCE_CREATE_INFO,
        flags = {.SIGNALED},
    }, nil, &compute_fence))

    write_descriptors := []vk.WriteDescriptorSet{
        { // PARAMS / Output
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = pipeline.descriptor_sets[0],
            dstBinding = 0,
            dstArrayElement = 0,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = param_buffer,
                offset = 0,
                range = size_of(Params),
            },
        },
        { // OPPONENTS
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = pipeline.descriptor_sets[0],
            dstBinding = 1,
            dstArrayElement = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = data_buffer,
                offset = 0,
                range = vk.DeviceSize(size_of(i32) * data_length),
            },
        },
        { // OUR MOVES
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = pipeline.descriptor_sets[0],
            dstBinding = 2,
            dstArrayElement = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = data_buffer,
                offset = vk.DeviceSize(size_of(i32) * data_length),
                range = vk.DeviceSize(size_of(i32) * data_length),
            },
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = pipeline.descriptor_sets[0],
            dstBinding = 3,
            dstArrayElement = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &vk.DescriptorBufferInfo{
                buffer = output_buffer,
                offset = 0,
                range = vk.DeviceSize(size_of(i32) * output_scores_len),
            },
        },
    }
    vk.UpdateDescriptorSets(pipeline.device, u32(len(write_descriptors)), raw_data(write_descriptors), 0, nil)

    { // PART 1 - we use the ours array xyz are moves
        // zero out the output scores
        mem.zero_explicit(raw_outputs, size_of(i32) * output_scores_len)

        params: Params
        mem.copy(raw_param, &params, size_of(Params))


        // Actually get GPU to do the work
        vk.ResetFences(pipeline.device, 1, &compute_fence)

        command_buffer := pipeline.command_buffers[0]
        aoc.vk_assert(vk.ResetCommandBuffer(command_buffer, {}))
        aoc.vk_assert(vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            sType = .COMMAND_BUFFER_BEGIN_INFO,
        }))

        vk.CmdBindPipeline(command_buffer, .COMPUTE, pipeline.pipeline)
        vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, pipeline.layout, 0, 1, &pipeline.descriptor_sets[0], 0, nil)
        vk.CmdDispatch(command_buffer, u32(output_scores_len), 1, 1)
        aoc.vk_assert(vk.EndCommandBuffer(command_buffer))

        compute_dst_stage_mask := vk.PipelineStageFlags{.COMPUTE_SHADER}

        aoc.vk_assert(vk.QueueSubmit(pipeline.queue, 1, &vk.SubmitInfo{
            sType = .SUBMIT_INFO,
            commandBufferCount = 1,
            pCommandBuffers = &command_buffer,
            pWaitDstStageMask = &compute_dst_stage_mask,
        }, compute_fence))
        
        aoc.vk_assert(vk.WaitForFences(pipeline.device, 1, &compute_fence, true, max(u64)))

        // we could create another compute shader that just sums the array BUT at this point
        // we have 9 values in output scores so lets just sum it up here
        final_score := 0
        final_scores := make([dynamic]i32, output_scores_len, context.temp_allocator)
        mem.copy(raw_data(final_scores[:]), raw_outputs, size_of(i32) * output_scores_len)

        for s in final_scores {
            final_score += int(s)
        }

        fmt.println("Part1:", final_score)
    }

    { // PART 1 - we use the ours array xyz are moves
        // zero out the output scores
        mem.zero_explicit(raw_outputs, size_of(i32) * output_scores_len)

        params := Params{
            is_score = true,
        }
        mem.copy(raw_param, &params, size_of(Params))

        // Actually get GPU to do the work
        vk.ResetFences(pipeline.device, 1, &compute_fence)

        command_buffer := pipeline.command_buffers[0]
        aoc.vk_assert(vk.ResetCommandBuffer(command_buffer, {}))
        aoc.vk_assert(vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            sType = .COMMAND_BUFFER_BEGIN_INFO,
        }))

        vk.CmdBindPipeline(command_buffer, .COMPUTE, pipeline.pipeline)
        vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, pipeline.layout, 0, 1, &pipeline.descriptor_sets[0], 0, nil)
        vk.CmdDispatch(command_buffer, u32(output_scores_len), 1, 1)
        aoc.vk_assert(vk.EndCommandBuffer(command_buffer))

        compute_dst_stage_mask := vk.PipelineStageFlags{.COMPUTE_SHADER}

        aoc.vk_assert(vk.QueueSubmit(pipeline.queue, 1, &vk.SubmitInfo{
            sType = .SUBMIT_INFO,
            commandBufferCount = 1,
            pCommandBuffers = &command_buffer,
            pWaitDstStageMask = &compute_dst_stage_mask,
        }, compute_fence))
        
        aoc.vk_assert(vk.WaitForFences(pipeline.device, 1, &compute_fence, true, max(u64)))

        // we could create another compute shader that just sums the array BUT at this point
        // we have 9 values in output scores so lets just sum it up here
        final_score := 0
        final_scores := make([dynamic]i32, output_scores_len)
        mem.copy(raw_data(final_scores[:]), raw_outputs, size_of(i32) * output_scores_len)

        for s in final_scores {
            final_score += int(s)
        }

        fmt.println("Part2:", final_score)
    }

}