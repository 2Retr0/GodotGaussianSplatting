#[compute]
#version 460
/**
 * VkRadixSort written by Mirco Werner: https://github.com/MircoWerner/VkRadixSort
 * Based on implementation of Intel's Embree: https://github.com/embree/embree/blob/v4.0.0-ploc/kernels/rthwif/builder/gpu/sort.h
 */

#define WORKGROUP_SIZE           (512) // assert WORKGROUP_SIZE >= RADIX_SORT_BINS
#define RADIX_SORT_BINS          (256)
#define NUM_BLOCKS_PER_WORKGROUP (32)

layout (local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout (std430, set = 0, binding = 0) restrict buffer Histogram {
    uint sort_buffer_size;
    // [histogram_of_workgroup_0 | histogram_of_workgroup_1 | ... ]
    uint histogram[]; // |histogram| = RADIX_SORT_BINS * #WORKGROUPS
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

shared uint[RADIX_SORT_BINS] histogram_local;

void main() {
    const uint size = sort_buffer_size;
    if (gl_GlobalInvocationID.x >= size) return;

    const uint id_local = gl_LocalInvocationIndex;
    const uint id_workgroup = gl_WorkGroupID.x;
    
    // initialize histogram_local
    if (id_local < RADIX_SORT_BINS) {
        histogram_local[id_local] = 0U;
    }
    barrier();

    // Ping-pong buffer offset
    // uint offset = ((shift / 8) % 2) * size;
    for (uint index = 0; index < NUM_BLOCKS_PER_WORKGROUP; index++) {
        uint id = id_workgroup * NUM_BLOCKS_PER_WORKGROUP * WORKGROUP_SIZE + index * WORKGROUP_SIZE + id_local;
        if (id < size) {
            // determine the bin
            const uint bin = uint(in_buffer[id][0] >> shift) & uint(RADIX_SORT_BINS - 1);
            // increment the histogram_local
            atomicAdd(histogram_local[bin], 1U);
        }
    }
    barrier();

    if (id_local < RADIX_SORT_BINS) {
        histogram[RADIX_SORT_BINS * id_workgroup + id_local] = histogram_local[id_local];
    }
}