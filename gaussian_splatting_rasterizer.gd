class_name GaussianSplattingRasterizer extends Resource

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512 # Same as defined in `radix_sort.glsl`
const RADIX_SORT_BINS := 256 # Same as defined in `radix_sort.glsl`
const NUM_BLOCKS_PER_WORKGROUP := 32

var context : RenderingContext
var pipelines : Dictionary
var descriptors : Dictionary
var descriptor_sets : Dictionary

var texture : Texture2DRD
var point_cloud : PlyFile
var num_sort_elements_max : int

var texture_size := Vector2(1920, 1080)
var load_thread := Thread.new()

func _init(point_cloud : PlyFile) -> void:
	self.point_cloud = point_cloud

func init_gpu() -> void:
	assert(texture, 'An output Texture2DRD must be specified!')
	
	# --- DEVICE/SHADER CREATION ---
	# We have to use `RenderingServer.get_rendering_device()` as Texture2DRD can only be used
	# on the main rendering device.
	context = RenderingContext.create(RenderingServer.get_rendering_device())
	var gaussian_projection_shader := context.load_shader('./resources/shaders/compute/gaussian_splatting_projection.glsl')
	var radix_sort_histogram_shader := context.load_shader('./resources/shaders/compute/radix_sort_histogram.glsl')
	var radix_sort_shader := context.load_shader('./resources/shaders/compute/radix_sort.glsl')
	var boundaries_shader := context.load_shader('./resources/shaders/compute/boundaries.glsl')
	var rasterize_shader := context.load_shader('./resources/shaders/compute/rasterize.glsl')
	
	# --- DESCRIPTOR PREPARATION ---
	num_sort_elements_max = ceili(point_cloud.num_vertices * 4)
	var num_workgroups = ceili(num_sort_elements_max / WORKGROUP_SIZE)
	
	descriptors['points'] = context.create_storage_buffer(point_cloud.num_vertices*60*4)
	descriptors['culled_points'] = context.create_storage_buffer(point_cloud.num_vertices * 16*4)
	descriptors['sort_buffer0'] = context.create_storage_buffer(num_sort_elements_max * 2*4)
	descriptors['sort_buffer1'] = context.create_storage_buffer(num_sort_elements_max * 2*4)
	descriptors['boundaries'] = context.create_storage_buffer(ceili(texture_size.x * texture_size.y / (TILE_SIZE*TILE_SIZE)) * 2*4)
	descriptors['histogram'] = context.create_storage_buffer(4 + num_workgroups * RADIX_SORT_BINS * 4)
	descriptors['texture'] = context.create_texture(texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT)
	
	var gaussian_projection_set := context.create_descriptor_set([descriptors['points'], descriptors['culled_points'], descriptors['histogram'], descriptors['sort_buffer0']], gaussian_projection_shader, 0)
	descriptor_sets['radix_sort0'] = context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['sort_buffer1']], radix_sort_shader, 0)
	descriptor_sets['radix_sort1'] = context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer1'], descriptors['sort_buffer0']], radix_sort_shader, 0)
	var boundaries_set = context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['boundaries']], boundaries_shader, 0)
	var rasterize_set := context.create_descriptor_set([descriptors['culled_points'], descriptors['sort_buffer0'], descriptors['boundaries'], descriptors['texture']], rasterize_shader, 0)
	
	texture.texture_rd_rid = descriptors['texture'].rid
	
	# --- COMPUTE PIPELINE CREATION ---
	pipelines['gaussian_projection']  = context.create_pipeline([ceili(point_cloud.num_vertices/256.0), 1, 1], [gaussian_projection_set], gaussian_projection_shader)
	pipelines['radix_sort_histogram'] = context.create_pipeline([ceili(num_sort_elements_max / NUM_BLOCKS_PER_WORKGROUP), 1, 1], [], radix_sort_histogram_shader)
	pipelines['radix_sort'] = context.create_pipeline([ceili(num_sort_elements_max / NUM_BLOCKS_PER_WORKGROUP), 1, 1], [], radix_sort_shader)
	pipelines['boundaries'] = context.create_pipeline([ceili(num_sort_elements_max / 256.0), 1, 1], [boundaries_set], boundaries_shader)
	pipelines['rasterize']  = context.create_pipeline([ceili(texture_size.x/TILE_SIZE), ceili(texture_size.y/TILE_SIZE), 1], [rasterize_set], rasterize_shader)
	
	# Begin loading splats asynchronously
	load_thread.start(PlyFile.load_gaussian_splats.bind(point_cloud, context.device, descriptors['points'].rid))
	
func cleanup_gpu():
	if context: context.free()
	if texture: texture.texture_rd_rid = RID()
	
func rasterize(camera : Camera3D) -> void:
	if not context: init_gpu()
	var proj := camera.get_camera_projection()
	var view := Projection(camera.get_camera_transform())
	var push_constant : Array[float] = [
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1,
		
		# --- View Matrix ---
		# Since (we assume) camera transform is orthonormal, the view matrix
		# (i.e., its inverse) is just the transpose.
		-view.x[0], view.y[0], -view.z[0], 0, 
		-view.x[1], view.y[1], -view.z[1], 0,
		view.x[2], -view.y[2], view.z[2], 0,
		-view.w.dot(view.x), -view.w.dot(-view.y), -view.w.dot(view.z), 1,
		#view.x[0], view.y[0], view.z[0], 0, 
		#view.x[1], view.y[1], view.z[1], 0,
		#view.x[2], view.y[2], view.z[2], 0,
		#-view.x.dot(view.w), -view.y.dot(view.w), -view.z.dot(view.w), 1,
		# --- Projection Matrix ---
		proj.x[0], proj.x[1], proj.x[2], 0, 
		proj.y[0], proj.y[1], proj.y[2], 0,
		proj.z[0], proj.z[1], proj.z[2],-1,
		proj.w[0], proj.w[1], proj.w[2], 0,
		
		camera.global_position.x, camera.global_position.y, camera.global_position.z, camera.far,
		point_cloud.num_vertices,
		Engine.get_frames_drawn() % 1 == 0,
	]
	
	#if context.needs_sync: 
		#context.sync()
	context.device.buffer_clear(descriptors['histogram'].rid, 0, 4)
	#context.device.buffer_clear(descriptors['debug'].rid, 0, 4)
	#context.device.buffer_clear(descriptors['boundaries'].rid, 0, ceili(texture_size.x * texture_size.y / (TILE_SIZE*TILE_SIZE) * 2)*4)
	#context.device.buffer_clear(descriptors['culled_buffer'].rid, 0, 4)
	
	var compute_list := context.compute_list_begin()
	pipelines['gaussian_projection'].call(context, compute_list, push_constant)
	if Engine.get_frames_drawn() % 1 == 0:
		for shift in range(0, 32, 8):
			var descriptor_set = descriptor_sets['radix_sort%d' % ((shift / 8) % 2)]
			pipelines['radix_sort_histogram'].call(context, compute_list, [shift], [descriptor_set])
			pipelines['radix_sort'].call(context, compute_list, [shift], [descriptor_set])
	
	pipelines['boundaries'].call(context, compute_list)
	pipelines['rasterize'].call(context, compute_list)
	context.compute_list_end()


	#print()
	#var out_buffer := context.device.buffer_get_data(descriptors['boundaries'].rid, 0, 4*2*8100).to_int32_array()
	#var output := ''
	#for i in range(8000, 8100, 2):
		#output += '(%d %d), ' % [out_buffer[i], out_buffer[i+1]]
	#print(output)
	#for i in range(1, num_elements):
		#assert(out_buffer[i*2] >= out_buffer[(i - 1)*2], 'Index (%d): %d < %d' % [i*2, out_buffer[i*2], out_buffer[(i - 1)*2]])
	#var remaining_points := context.device.buffer_get_data(descriptors['culled_buffer'].rid, 0, 4).decode_u32(0)
	#var to_sort := context.device.buffer_get_data(descriptors['histogram'].rid, 0, 4).decode_u32(0)
	#print('#Culled Points (%f%%): ' % (100.0 * float(point_cloud.num_vertices - remaining_points) / float(point_cloud.num_vertices)), point_cloud.num_vertices - remaining_points)
	#var to_sort := context.device.buffer_get_data(descriptors['histogram'].rid, 0, 4).decode_u32(0)
	#print('#Avg Duplications per Gaussian (overflow? %s): ' % ('TRUE!' if to_sort > (point_cloud.num_vertices * 50) else 'false'), float(to_sort) / float(point_cloud.num_vertices), ' (total: %d)' % to_sort)
	#context.submit()
