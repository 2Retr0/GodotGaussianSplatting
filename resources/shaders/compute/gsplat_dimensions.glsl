#[compute]
#version 460

#define NUM_BLOCKS_PER_WORKGROUP (32)

layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout (std430, set = 0, binding = 0) restrict readonly buffer Histograms {
    uint sort_buffer_size;
    uint histogram[];
};

layout (std430, set = 0, binding = 1) restrict writeonly buffer DimensionsBuffer {
    uint sort_dim_x;
	uint sort_dim_y;
	uint sort_dim_z;
	uint bounds_dim_x;
	uint bounds_dim_y;
	uint bounds_dim_z;
};

void main() {
    sort_dim_x = uint(ceil(sort_buffer_size / float(NUM_BLOCKS_PER_WORKGROUP)));
	bounds_dim_x = uint(ceil(sort_buffer_size / 256.0));
}