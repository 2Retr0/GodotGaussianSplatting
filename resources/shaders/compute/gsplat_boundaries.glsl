#[compute]
#version 460

#define BLOCK_SIZE (256)

layout (local_size_x = BLOCK_SIZE, local_size_y = 1, local_size_z = 1) in;

layout (std430, set = 0, binding = 0) restrict readonly buffer Histograms {
    uint sort_buffer_size;
    uint histogram[];
};

layout (std430, set = 0, binding = 1) restrict readonly buffer SortBuffer {
    uint sort_buffer[];
};

layout (std430, set = 0, binding = 2) restrict writeonly buffer BoundsBuffer {
    uvec2 bounds_buffer[];
};

shared uint[BLOCK_SIZE+1] local;

void main() {
    const uint id = gl_GlobalInvocationID.x;
    const uint id_local = gl_LocalInvocationIndex;
    const uint sort_buffer_size = sort_buffer_size;
    if (id >= sort_buffer_size || id == 0) return;

    // Load tile into shared memory
    if (id_local == 0) {
        local[id_local] = sort_buffer[id - 1] >> 16;
    }
    local[id_local + 1] = sort_buffer[id] >> 16;
    barrier();

    uint tile_id_prev = local[id_local]; // Left neighbor
    uint tile_id = local[id_local + 1];
    // If tiles IDs are different, then we have found a boundary!
    if (tile_id_prev != tile_id) {
        bounds_buffer[tile_id_prev].y = id;
        bounds_buffer[tile_id].x = id;
    }
    // Edge case for the last tile. Since no left neighbor will ever be the last
    // tile, the end index of the last tile *would* remain zero. To fix this,
    // if the tile ID is the last tile, we also set the end index of the last
    // tile to be the sort buffer size.
    const uint last_tile_id = bounds_buffer.length() - 1;
    if (tile_id == last_tile_id)
        bounds_buffer[last_tile_id].y = sort_buffer_size - 1;
}