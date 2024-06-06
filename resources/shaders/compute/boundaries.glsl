#[compute]
#version 460

#define BLOCK_SIZE (256)

layout (local_size_x = BLOCK_SIZE, local_size_y = 1, local_size_z = 1) in;

layout (std430, set = 0, binding = 0) restrict buffer Histograms {
    uint sort_buffer_size;
    uint histogram[];
};

layout (std430, set = 0, binding = 1) readonly buffer SortBuffer {
    uvec2 data[];
} sort_buffer;

layout (std430, set = 0, binding = 2) restrict buffer BoundsBuffer {
    uvec2 data[];
} bounds;

shared uint[BLOCK_SIZE+1] local;

void main() {
    const uint id = gl_GlobalInvocationID.x;
    const uint id_local = gl_LocalInvocationIndex;
    if (id >= sort_buffer_size || id == 0) return;

    // Load tile into shared memory
    if (id_local == 0) {
        local[id_local] = sort_buffer.data[id - 1].x >> 16;
    }
    local[id_local + 1] = sort_buffer.data[id].x >> 16;
    barrier();

    uint tile_id_prev = local[id_local]; // Left neighbor
    uint tile_id = local[id_local + 1];
    // If tiles IDs are different, then we have found a boundary!
    if (tile_id_prev != tile_id) {
        bounds.data[tile_id_prev].y = id;
        bounds.data[tile_id].x = id;
    }
}