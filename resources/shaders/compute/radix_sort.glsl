#[compute]
#version 460
#extension GL_KHR_shader_subgroup_basic: enable
#extension GL_KHR_shader_subgroup_arithmetic: enable
#extension GL_KHR_shader_subgroup_ballot: enable

/**
 * VkRadixSort written by Mirco Werner: https://github.com/MircoWerner/VkRadixSort
 * Based on implementation of Intel's Embree: https://github.com/embree/embree/blob/v4.0.0-ploc/kernels/rthwif/builder/gpu/sort.h
 */

#define WORKGROUP_SIZE           (512) // assert WORKGROUP_SIZE >= RADIX_SORT_BINS
#define RADIX_SORT_BINS          (256)
#define SUBGROUP_SIZE            (32) // 32 NVIDIA; 64 AMD
#define NUM_BLOCKS_PER_WORKGROUP (32)

layout (local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout (std430, set = 0, binding = 0) restrict buffer Histograms {
    uint sort_buffer_size;
    // [histogram_of_workgroup_0 | histogram_of_workgroup_1 | ... ]
    uint histogram[];// |histogram| = RADIX_SORT_BINS * #WORKGROUPS = RADIX_SORT_BINS * num_workgroups
};

layout (std430, set = 0, binding = 1) restrict readonly buffer SortBufferIn {
    uvec2 in_buffer[];
};

layout (std430, set = 0, binding = 2) restrict writeonly buffer SortBufferOut {
    uvec2 out_buffer[];
};

layout (push_constant) restrict readonly uniform PushConstants {
    uint shift;
};

shared uint[RADIX_SORT_BINS / SUBGROUP_SIZE] sums;// subgroup reductions
shared uint[RADIX_SORT_BINS] global_offsets;// global exclusive scan (prefix sum)

struct BinFlags {
    uint flags[WORKGROUP_SIZE / 32 + 1];
};

shared BinFlags[RADIX_SORT_BINS] bin_flags;

void main() {
    const uint size = sort_buffer_size;
    if (gl_GlobalInvocationID.x >= size) return;

    const uint num_blocks = uint(ceil(float(size) / float(NUM_BLOCKS_PER_WORKGROUP)));
    const uint num_workgroups = (num_blocks + WORKGROUP_SIZE-1) / WORKGROUP_SIZE;
    
    const uint id_local = gl_LocalInvocationIndex;
    const uint id_workgroup = gl_WorkGroupID.x;
    const uint id_subgroup = gl_SubgroupID;
    const uint id_local_subgroup = gl_SubgroupInvocationID;
    
    uint local_histogram = 0;
    uint prefix_sum = 0;
    uint histogram_count = 0;

    if (id_local < RADIX_SORT_BINS) {
        uint count = 0;
        for (uint j = 0; j < num_workgroups; j++) {
            const uint t = histogram[RADIX_SORT_BINS * j + id_local];
            local_histogram = (j == id_workgroup) ? count : local_histogram;
            count += t;
        }
        histogram_count = count;
        const uint sum = subgroupAdd(histogram_count);
        prefix_sum = subgroupExclusiveAdd(histogram_count);
        if (subgroupElect()) {
            // one thread inside the warp/subgroup enters this section
            sums[id_subgroup] = sum;
        }
    }
    barrier();

    if (id_local < RADIX_SORT_BINS) {
        const uint sums_prefix_sum = subgroupBroadcast(subgroupExclusiveAdd(sums[id_local_subgroup]), id_subgroup);
        const uint global_histogram = sums_prefix_sum + prefix_sum;
        global_offsets[id_local] = global_histogram + local_histogram;
    }

    // Ping-pong buffer offsets for kernel input/output
    // const uint ping_pong_index = (shift / 8) % 2;
    // const uvec2 offsets = uvec2(ping_pong_index, ~ping_pong_index & 1) * size;
    //     ==== scatter keys according to global offsets =====
    const uint flags_bin = id_local / 32;
    const uint flags_bit = 1 << (id_local % 32);

    for (uint index = 0; index < NUM_BLOCKS_PER_WORKGROUP; index++) {
        uint id = id_workgroup * NUM_BLOCKS_PER_WORKGROUP * WORKGROUP_SIZE + index * WORKGROUP_SIZE + id_local;

        // initialize bin flags
        if (id_local < RADIX_SORT_BINS) {
            for (int i = 0; i < WORKGROUP_SIZE / 32; i++) {
                bin_flags[id_local].flags[i] = 0U;// init all bin flags to 0
            }
        }
        barrier();

        uvec2 element_in = uvec2(0);
        uint bin_id = 0;
        uint bin_offset = 0;
        if (id < size) {
            element_in = in_buffer[id];
            bin_id = uint(element_in[0] >> shift) & uint(RADIX_SORT_BINS - 1);
            // offset for group
            bin_offset = global_offsets[bin_id];
            // add bit to flag
            atomicAdd(bin_flags[bin_id].flags[flags_bin], flags_bit);
        }
        barrier();

        if (id < size) {
            // calculate output index of element
            uint prefix = 0;
            uint count = 0;
            for (uint i = 0; i < WORKGROUP_SIZE / 32; i++) {
                const uint bits = bin_flags[bin_id].flags[i];
                const uint full_count = bitCount(bits);
                const uint partial_count = bitCount(bits & (flags_bit - 1));
                prefix += (i < flags_bin) ? full_count : 0U;
                prefix += (i == flags_bin) ? partial_count : 0U;
                count += full_count;
            }
            out_buffer[bin_offset + prefix] = element_in;
            if (prefix == count - 1) {
                atomicAdd(global_offsets[bin_id], count);
            }
        }

        barrier();
    }
}