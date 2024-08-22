#[compute]
#version 460

#extension GL_KHR_shader_subgroup_arithmetic: enable

#define SH_C0 0.28209479177387814
#define SH_C1 0.4886025119029199

#define SH_C2_0 1.0925484305920792
#define SH_C2_1 1.0925484305920792
#define SH_C2_2 0.31539156525252005
#define SH_C2_3 1.0925484305920792
#define SH_C2_4 0.5462742152960396

#define SH_C3_0 0.5900435899266435
#define SH_C3_1 2.890611442640554
#define SH_C3_2 0.4570457994644658
#define SH_C3_3 0.3731763325901154
#define SH_C3_4 0.4570457994644658
#define SH_C3_5 1.445305721320277
#define SH_C3_6 0.5900435899266435

#define TILE_SIZE                (16)
#define NUM_BLOCKS_PER_WORKGROUP (32)
#define SORT_WORKGROUP_SIZE      (512)
#define SORT_PARTITION_DIVISION  (8)
#define SORT_PARTITION_SIZE      (SORT_PARTITION_DIVISION * SORT_WORKGROUP_SIZE)

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

struct Splat {
	vec3 position;
	uint _pad;
	vec3 scale;
	float opacity;
	vec4 quaternion;
	float sh_coefficients[16*3]; // Spherical harmonic coefficients in increasing order
};

struct RasterizeData {
	vec2 image_pos;
    vec2 pos_xy;
	vec3 conic;
	float pos_z;
	vec4 color;
};

layout(std430, set = 0, binding = 0) restrict readonly buffer SplatsBuffer {
	Splat splat_buffer[];
};

layout(std430, set = 0, binding = 1) restrict writeonly buffer CulledBuffer {
	RasterizeData culled_buffer[];
};

layout (std430, set = 0, binding = 2) restrict buffer Histograms {
	uint sort_buffer_size;
    uint histogram[];
};

layout (std430, set = 0, binding = 3) restrict writeonly buffer SortKeysBuffer {
    uint sort_keys[];
};

layout (std430, set = 0, binding = 4) restrict writeonly buffer SortValuesBuffer {
    uint sort_values[];
};

layout (std430, set = 0, binding = 5) restrict writeonly buffer GridDimensionsBuffer {
	uint grid_dims[];
};

layout (std140, set = 0, binding = 6) restrict uniform Uniforms {
	vec3 camera_pos;
	uint _pad;
	ivec2 dims; // Texture size
};

layout(push_constant) restrict readonly uniform PushConstants {
	mat4 view_matrix;
	mat4 projection_matrix;
};

/** Calculates the color from given spherical harmonic coefficients and view direction. */
#define SH_COEFFICIENTS(x) (vec3(sh_coefficients[x*3], sh_coefficients[x*3+1], sh_coefficients[x*3+2]))
vec3 get_color(in vec3 view_dir, in float sh_coefficients[16*3]) {
	const float x = view_dir.x,
			    y = view_dir.y,
				z = view_dir.z;
	const float xx = x*x, yy = y*y, zz = z*z,
			    xy = x*y, yz = y*z, xz = x*z;
	return max(vec3(0), 0.5 
		// Degree 0
		+  SH_COEFFICIENTS(0) *   SH_C0
		// Degree 1
		-  SH_COEFFICIENTS(1) *   SH_C1 * y
		+  SH_COEFFICIENTS(2) *   SH_C1 * z
		-  SH_COEFFICIENTS(3) *   SH_C1 * x
		// Degree 2
		+  SH_COEFFICIENTS(4) * SH_C2_0 * xy
		-  SH_COEFFICIENTS(5) * SH_C2_1 * yz
		+  SH_COEFFICIENTS(6) * SH_C2_2 * (2.0*zz - xx - yy)
		-  SH_COEFFICIENTS(7) * SH_C2_3 * xz
		+  SH_COEFFICIENTS(8) * SH_C2_4 * (xx - yy)
		// Degree 3
		-  SH_COEFFICIENTS(9) * SH_C3_0 * y * (3.0*xx - yy)
		+ SH_COEFFICIENTS(10) * SH_C3_1 * x * yz
		- SH_COEFFICIENTS(11) * SH_C3_2 * y * (4.0*zz - xx - yy)
		+ SH_COEFFICIENTS(12) * SH_C3_3 * z * (2.0*zz - 3.0*xx - 3.0*yy)
		- SH_COEFFICIENTS(13) * SH_C3_4 * x * (4.0*zz - xx - yy)
		+ SH_COEFFICIENTS(14) * SH_C3_5 * z * (xx - yy)
		- SH_COEFFICIENTS(15) * SH_C3_6 * x * (xx - 3.0*yy));
}

/** Computes a 2D projected covariance matrix from the given Gaussian parameters. */
vec3 get_covariance(in vec3 scale, in vec4 quaternion, in vec3 mean, in ivec2 dims) {
	const vec4 q = normalize(quaternion);
	// --- 3D Covariance ---
	// 3D gaussian covariance could be precomputed... but the main bottleneck is the
	// sorting step, so it doesn't really matter ^^
	mat3 scale_matrix = mat3(scale.x, 0, 0, 0, scale.y, 0, 0, 0, scale.z);
	mat3 rotation_matrix = 2.0 * mat3(
		0.5 - (q[2]*q[2] + q[3]*q[3]),       (q[1]*q[2] - q[0]*q[3]),       (q[1]*q[3] + q[0]*q[2]),
		      (q[1]*q[2] + q[0]*q[3]), 0.5 - (q[1]*q[1] + q[3]*q[3]),       (q[2]*q[3] - q[0]*q[1]),
		      (q[1]*q[3] - q[0]*q[2]),       (q[2]*q[3] + q[0]*q[1]), 0.5 - (q[1]*q[1] + q[2]*q[2]));
	mat3 a = scale_matrix * rotation_matrix;
	mat3 cov_3d = transpose(a) * a;

	// --- 2D Covariance Projection ---
	vec2 tan_fov_inv = vec2(projection_matrix[0][0], projection_matrix[1][1]);
	vec2 focal = dims * 0.5*tan_fov_inv;
	float z_inv = 1.0 / mean.z;

	vec2 tan_fov = 1.0 / tan_fov_inv;
    mean.xy = clamp(mean.xy*z_inv, -tan_fov*1.3, tan_fov*1.3) * mean.z;
	mat3 jacobian = mat3(
		focal.x * z_inv, 0, -focal.y*mean.x * z_inv*z_inv,
	    0, focal.y * z_inv, -focal.y*mean.y * z_inv*z_inv,
		0, 0, 0);
	mat3 inv_view = transpose(mat3(view_matrix));
	mat3 b = inv_view * jacobian;
	mat3 cov_2d = transpose(b) * cov_3d * b;
	return vec3(cov_2d[0][0] + 0.3, cov_2d[0][1], cov_2d[1][1] + 0.3);
}

uvec4 get_rect(in vec2 image_pos, in float radius, in uvec2 grid_size) {
	return ivec4(
		clamp(     (image_pos - radius) / TILE_SIZE,  vec2(0), grid_size),
		clamp(ceil((image_pos + radius) / TILE_SIZE), vec2(0), grid_size));
}

void main() {
	const int id = int(gl_GlobalInvocationID.x);
	const uvec2 grid_size = (dims + TILE_SIZE - 1) / TILE_SIZE;

	if (id >= splat_buffer.length()) return;
	
	RasterizeData data;
	barrier();
	const Splat splat = splat_buffer[id];

	// --- FRUSTUM CULLING ---
	vec4 view_pos = view_matrix * vec4(splat.position, 1);
	vec4 clip_pos = projection_matrix * view_pos;
	vec2 view_bounds = clip_pos.ww*1.2;
	if (any(lessThan(clip_pos.xyz, vec3(-view_bounds, 0.0))) || any(greaterThan(clip_pos.xyz, vec3(view_bounds, clip_pos.w)))) {
		return;
	}
	
	// --- GAUSSIAN PROJECTION ---
	vec3 covariance = get_covariance(splat.scale, splat.quaternion, view_pos.xyz, dims);
	float det = covariance.x*covariance.z - covariance.y*covariance.y;
	if (det == 0.0 || any(lessThan(covariance.xz, vec2(0)))) return;

	float mid = 0.5 * (covariance.x + covariance.z);
	vec2 eigenvalues = mid + vec2(1, -1)*sqrt(max(0.1, mid*mid - det));
	if (any(lessThan(eigenvalues, vec2(0)))) return;

	vec3 ndc_pos = clip_pos.xyz / clip_pos.w;
	data.image_pos = (ndc_pos.xy + 1.0)*0.5 * (dims - 1);

	// We bias the radius (w/ base=3x standard deviation) such that low opacity splats cover 
	// fewer screen tiles. This has the effect of making the image *slightly* brighter while
	// minimizing perceptible tile artifacts.
	float radius = pow(splat.opacity, 0.2) * 3.0*sqrt(max(eigenvalues.x, eigenvalues.y));
	uvec4 rect_bounds = get_rect(data.image_pos, radius, grid_size);
	uint num_tiles_touched = (rect_bounds.z - rect_bounds.x)*(rect_bounds.w - rect_bounds.y);

	if (num_tiles_touched == 0 || num_tiles_touched > grid_size.x*grid_size.y/3) return;

	const uint buffer_size = atomicAdd(sort_buffer_size, num_tiles_touched);
	uint sort_buffer_offset = buffer_size;
	vec3 view_dir = normalize(splat.position - camera_pos);
	data.conic = vec3(covariance.z, -covariance.y, covariance.x) / det; // Inverse 2D covariance
	data.color = vec4(get_color(view_dir, splat.sh_coefficients), splat.opacity);
	data.pos_xy = splat.position.xy;
	data.pos_z = splat.position.z;
	culled_buffer[id] = data;
	barrier();

	// --- UPDATE SORT KERNEL DIMENSIONS ---
	if (subgroupElect()) {
		uint sort_buffer_size = sort_buffer_size;
		atomicMax(grid_dims[0], (sort_buffer_size + SORT_PARTITION_SIZE - 1) / SORT_PARTITION_SIZE); // Grid size is number of partitions
		atomicMax(grid_dims[3], (sort_buffer_size + 256 - 1) / 256);
	}

	// --- GAUSSIAN DUPLICATION ---
	// uint depth = uint((clip_pos.z) * 512) & 0xFFFF;
	uint depth = uint(ndc_pos.z*ndc_pos.z*ndc_pos.z * 0xFFFF) & 0xFFFF; // Depth normalized in [0, 2^16 - 1] as a uint
	for (uint y = rect_bounds.y; y < rect_bounds.w; ++y)
	for (uint x = rect_bounds.x; x < rect_bounds.z; ++x) {
		uint tile_id = y*grid_size.x + x;
		uint key = (tile_id << 16) | depth;
		sort_keys[sort_buffer_offset] = key;
		sort_values[sort_buffer_offset] = id;
		sort_buffer_offset++;
	}
}