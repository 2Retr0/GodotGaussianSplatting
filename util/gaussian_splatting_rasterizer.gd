@tool
class_name GaussianSplattingRasterizer extends Resource

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512 # Same as defined in `radix_sort.glsl`
const RADIX_SORT_BINS := 256 # Same as defined in `radix_sort.glsl`
const NUM_BLOCKS_PER_WORKGROUP := 32

var context : RenderingContext
var shaders : Dictionary
var pipelines : Dictionary
var descriptors : Dictionary
var descriptor_sets : Dictionary

var point_cloud : PlyFile
var render_texture : Texture2DRD
var camera : Camera3D
var camera_projection : Projection
var camera_transform : Projection
var camera_push_constants : PackedByteArray

var default_block_dims : PackedByteArray
var tile_dims := Vector2i.ZERO
var texture_size : Vector2i :
	set(value):
		texture_size = value
		tile_dims = (texture_size + Vector2i.ONE*(TILE_SIZE - 1)) / TILE_SIZE
		if not descriptors.has('output_texture') or not context: return
		# Rebuild boundaries and rasterize pielines (since those depend on texture size)
		render_texture = Texture2DRD.new() # FIXME: idk why I have to do this
		context.deletion_queue.free_rid(context.device, descriptors['bounds_buffer'].rid)
		context.deletion_queue.free_rid(context.device, descriptors['output_texture'].rid)
		
		# FIXME: ERM MEMORY LEAK?!
		#context.device.free_rid(pipelines['boundaries'])
		#context.device.free_rid(pipelines['rasterize'])
		
		descriptors['bounds_buffer'] = context.create_storage_buffer(tile_dims.x*tile_dims.y * 2*4)
		descriptors['output_texture'] = context.create_texture(value, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
		pipelines['boundaries'] = context.create_pipeline([], [context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['bounds_buffer']], shaders['boundaries'], 0)], shaders['boundaries'])
		pipelines['rasterize'] = context.create_pipeline([tile_dims.x, tile_dims.y, 1], [context.create_descriptor_set([descriptors['culled_splats'], descriptors['sort_buffer0'], descriptors['bounds_buffer'], descriptors['output_texture']], shaders['rasterize'], 0)], shaders['rasterize'])
		render_texture.texture_rd_rid = descriptors['output_texture'].rid

var load_thread := Thread.new()
var is_loaded := false
var should_terminate_thread : Array[bool] = [false]

func _init(point_cloud : PlyFile, output_texture_size : Vector2i, render_texture : Texture2DRD, camera : Camera3D) -> void:
	self.point_cloud = point_cloud
	self.texture_size = output_texture_size
	self.render_texture = render_texture
	self.camera = camera
	var block_dims : PackedInt32Array; block_dims.resize(2*3); block_dims.fill(1)
	self.default_block_dims = block_dims.to_byte_array()
	update_camera_matrices()

func init_gpu() -> void:
	assert(render_texture, 'An output Texture2DRD must be set!')
	# --- DEVICE/SHADER CREATION ---
	# We have to use `RenderingServer.get_rendering_device()` as Texture2DRD can only be used
	# on the main rendering device.
	context = RenderingContext.create(RenderingServer.get_rendering_device())
	var projection_shader := context.load_shader('res://resources/shaders/compute/gsplat_projection.glsl')
	var radix_sort_histogram_shader := context.load_shader('res://resources/shaders/compute/radix_sort_histogram.glsl')
	var radix_sort_shader := context.load_shader('res://resources/shaders/compute/radix_sort.glsl')
	shaders['boundaries'] = context.load_shader('res://resources/shaders/compute/gsplat_boundaries.glsl')
	shaders['rasterize'] = context.load_shader('res://resources/shaders/compute/gsplat_rasterize.glsl')
	
	# --- DESCRIPTOR PREPARATION ---
	var num_sort_elements_max := ceili(point_cloud.num_vertices * 10) # FIXME: This should not be a static value!
	var num_workgroups := ceili(num_sort_elements_max / WORKGROUP_SIZE)
	
	descriptors['splats'] = context.create_storage_buffer(point_cloud.num_vertices * 60*4)
	descriptors['uniforms'] = context.create_uniform_buffer(8*4)
	descriptors['culled_splats'] = context.create_storage_buffer(point_cloud.num_vertices * 12*4)
	descriptors['block_dimensions'] = context.create_storage_buffer(2*3*4, default_block_dims, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	descriptors['sort_buffer0'] = context.create_storage_buffer(num_sort_elements_max * 2*4)
	descriptors['sort_buffer1'] = context.create_storage_buffer(num_sort_elements_max * 2*4)
	descriptors['bounds_buffer'] = context.create_storage_buffer(tile_dims.x*tile_dims.y * 2*4)
	descriptors['histogram'] = context.create_storage_buffer(4 + num_workgroups * RADIX_SORT_BINS * 4)
	descriptors['output_texture'] = context.create_texture(texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	
	var projection_set := context.create_descriptor_set([descriptors['splats'], descriptors['culled_splats'], descriptors['histogram'], descriptors['sort_buffer0'], descriptors['block_dimensions'], descriptors['uniforms']], projection_shader, 0)
	var boundaries_set := context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['bounds_buffer']], shaders['boundaries'], 0)
	var rasterize_set := context.create_descriptor_set([descriptors['culled_splats'], descriptors['sort_buffer0'], descriptors['bounds_buffer'], descriptors['output_texture']], shaders['rasterize'], 0)
	descriptor_sets['radix_sort0'] = context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['sort_buffer1']], radix_sort_shader, 0)
	descriptor_sets['radix_sort1'] = context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer1'], descriptors['sort_buffer0']], radix_sort_shader, 0)
	
	render_texture.texture_rd_rid = descriptors['output_texture'].rid
	
	# --- COMPUTE PIPELINE CREATION ---
	pipelines['projection'] = context.create_pipeline([ceili(point_cloud.num_vertices/256.0), 1, 1], [projection_set], projection_shader)
	pipelines['radix_sort_histogram'] = context.create_pipeline([], [], radix_sort_histogram_shader)
	pipelines['radix_sort'] = context.create_pipeline([], [], radix_sort_shader)
	pipelines['boundaries'] = context.create_pipeline([], [boundaries_set], shaders['boundaries'])
	pipelines['rasterize'] = context.create_pipeline([tile_dims.x, tile_dims.y, 1], [rasterize_set], shaders['rasterize'])
	
	# Begin loading splats asynchronously
	load_thread.start(PlyFile.load_gaussian_splats.bind(point_cloud, point_cloud.num_vertices / 1000, context.device, descriptors['splats'].rid, should_terminate_thread))
	
func cleanup_gpu():
	if load_thread.is_alive():
		should_terminate_thread[0] = true
		load_thread.wait_to_finish()
	if context: context.free()
	if render_texture: render_texture.texture_rd_rid = RID()

func rasterize() -> void:
	if not context: init_gpu()
	context.device.buffer_clear(descriptors['histogram'].rid, 0, 4) # Clear the sort buffer size
	context.device.buffer_clear(descriptors['bounds_buffer'].rid, 0, tile_dims.x*tile_dims.y * 2*4) # Clear boundaries buffer
	#context.device.texture_clear(descriptors['output_texture'].rid, Color.WHITE, 0, 1, 0, 1)
	context.device.buffer_update(descriptors['uniforms'].rid, 0, 8*4, RenderingContext.create_push_constant([camera.global_position.x, camera.global_position.y, camera.global_position.z, 0, texture_size.x, texture_size.y]))
	context.device.buffer_update(descriptors['block_dimensions'].rid, 0, 3*4*2, default_block_dims)
	is_loaded = not load_thread.is_alive()
	
	# Run the projection pipeline. This will return how many duplicated points
	# we will actually need to sort after culling.
	var compute_list := context.compute_list_begin()
	pipelines['projection'].call(context, compute_list, camera_push_constants)
	
	# Then, run the sort and rasterize pipelines with block sizes based on the
	# amount of points to sort determined in the projection pipeline.
	for shift in range(0, 32, 8):
		var descriptor_set := [descriptor_sets['radix_sort%d' % ((shift / 8) % 2)]]
		var push_constant := RenderingContext.create_push_constant([shift])
		pipelines['radix_sort_histogram'].call(context, compute_list, push_constant, descriptor_set, descriptors['block_dimensions'].rid, 0)
		pipelines['radix_sort'].call(context, compute_list, push_constant, descriptor_set, descriptors['block_dimensions'].rid, 0)
	pipelines['boundaries'].call(context, compute_list, [], [], descriptors['block_dimensions'].rid, 3*4)
	pipelines['rasterize'].call(context, compute_list)
	context.compute_list_end()
	
	#if is_loaded and Engine.get_process_frames() % 20 == 0:
		#var boundaries := context.device.buffer_get_data(descriptors['bounds_buffer'].rid, 0, tile_dims.x*tile_dims.y * 2*4).to_int32_array()
		#var maximum := 0
		#var mean := 0.0
		#var mean_sq := 0.0
		#var std := 0.0
		#for i in range(0, tile_dims.x*tile_dims.y * 2, 2):
			#var value := maxi(0, boundaries[i + 1] - boundaries[i]) # Num splats in tile
			#var t := 1.0 / float(i/2 + 1)
			#maximum = max(maximum, value)
			#mean = lerpf(mean, value, t)
			#mean_sq = lerpf(mean_sq, value**2, t)
		#std = sqrt(abs(mean_sq - mean*mean))
		#print('mean: %.2f, max: %d, std: %.3f' % [mean, maximum, std])

func get_splat_position(screen_position : Vector2i) -> Vector3:
	var tile := screen_position / TILE_SIZE
	var tile_id := tile.y * tile_dims.x + tile.x
	var bounds := context.device.buffer_get_data(descriptors['bounds_buffer'].rid, tile_id * 2*4, 2*4).to_int32_array()
	if bounds[1] - bounds[0] <= 0: return Vector3.INF
	var cull_idx := context.device.buffer_get_data(descriptors['sort_buffer0'].rid, roundi(lerpf(bounds[0], bounds[1], 0.1)) * 2*4 + 4, 4).decode_u32(0)
	var splat_idx := context.device.buffer_get_data(descriptors['culled_splats'].rid, cull_idx * 12*4 + 7*4, 4).decode_u32(0)
	var splat_pos := context.device.buffer_get_data(descriptors['splats'].rid, splat_idx * 60*4, 3*4)
	return Vector3(splat_pos.decode_float(0), splat_pos.decode_float(4), splat_pos.decode_float(8))*Vector3(-1,-1,1)

## Returns whether the view and projection matrices had changed since the last time this function
## was called.
func update_camera_matrices() -> bool:
	var view := Projection(camera.get_camera_transform())
	var proj := camera.get_camera_projection()
	if view != camera_transform or proj != camera_projection:
		camera_transform = view
		camera_projection = proj
		camera_push_constants = RenderingContext.create_push_constant([
			# --- View Matrix ---
			# Since (we assume) camera transform is orthonormal, the view matrix
			# (i.e., its inverse) is just the transpose.
			-view.x[0],  view.y[0], -view.z[0], 0.0, 
			-view.x[1],  view.y[1], -view.z[1], 0.0,
			 view.x[2], -view.y[2],  view.z[2], 0.0,
			-view.w.dot(view.x), -view.w.dot(-view.y), -view.w.dot(view.z), 1.0,
			# --- Projection Matrix ---
			proj.x[0], proj.x[1], proj.x[2], 0.0, 
			proj.y[0], proj.y[1], proj.y[2], 0.0,
			proj.z[0], proj.z[1], proj.z[2],-1.0,
			proj.w[0], proj.w[1], proj.w[2], 0.0 ])
		return true
	return false
