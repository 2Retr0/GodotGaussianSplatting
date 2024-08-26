@tool
class_name GaussianSplattingRasterizer extends Resource

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512 # Same as defined in `radix_sort_upsweep.glsl`
const RADIX := 256 # Same as defined in `radix_sort_upsweep.glsl`
const PARTITION_DIVISION := 8 # Same as defined in `radix_sort_upsweep.glsl`
const PARTITION_SIZE := PARTITION_DIVISION * WORKGROUP_SIZE # Same as defined in `radix_sort_upsweep.glsl`

signal loaded

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

var tile_dims := Vector2i.ZERO
var texture_size : Vector2i :
	set(value):
		texture_size = (value * render_scale[0]).max(Vector2i.ONE)
		tile_dims = (texture_size + Vector2i.ONE*(TILE_SIZE - 1)) / TILE_SIZE
		if not descriptors.has('render_texture') or not context: return
		# Rebuild gsplat_boundaries and gsplat_render pielines (since those depend on texture size)
		render_texture = Texture2DRD.new() # FIXME: idk why I have to do this
		context.deletion_queue.free_rid(context.device, descriptors['tile_bounds'].rid)
		context.deletion_queue.free_rid(context.device, descriptors['render_texture'].rid)
		
		# FIXME: ERM MEMORY LEAK?!
		#context.device.free_rid(pipelines['gsplat_boundaries'])
		#context.device.free_rid(pipelines['gsplat_render'])
		
		descriptors['tile_bounds'] = context.create_storage_buffer(tile_dims.x*tile_dims.y * 2*4)
		descriptors['render_texture'] = context.create_texture(texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
		
		var boundaries_set := context.create_descriptor_set([descriptors['histogram'], descriptors['sort_keys'], descriptors['tile_bounds']], shaders['boundaries'], 0)
		var render_set := context.create_descriptor_set([descriptors['culled_splats'], descriptors['sort_values'], descriptors['tile_bounds'], descriptors['tile_splat_pos'], descriptors['render_texture']], shaders['render'], 0)
		
		pipelines['gsplat_boundaries'] = context.create_pipeline([], [boundaries_set], shaders['boundaries'])
		pipelines['gsplat_render'] = context.create_pipeline([tile_dims.x, tile_dims.y, 1], [render_set], shaders['render'])
		render_texture.texture_rd_rid = descriptors['render_texture'].rid

var load_thread := Thread.new()
var is_loaded := false
var should_enable_heatmap := [false]
var render_scale := [1.0]
var model_scale := [1.0]
var should_terminate_thread : Array[bool] = [false]
var num_splats_loaded : Array[int] = [0]
var basis_override := Basis.IDENTITY

func _init(point_cloud : PlyFile, output_texture_size : Vector2i, render_texture : Texture2DRD, camera : Camera3D) -> void:
	self.point_cloud = point_cloud
	self.texture_size = output_texture_size
	self.render_texture = render_texture
	self.camera = camera

func init_gpu() -> void:
	assert(render_texture, 'An output Texture2DRD must be set!')
	# --- DEVICE/SHADER CREATION ---
	# We have to use `RenderingServer.get_rendering_device()` as Texture2DRD can only be used
	# on the main rendering device.
	context = RenderingContext.create(RenderingServer.get_rendering_device())
	var projection_shader := context.load_shader('res://resources/shaders/compute/gsplat_projection.glsl')
	var radix_sort_upsweep_shader := context.load_shader('res://resources/shaders/compute/radix_sort_upsweep.glsl')
	var radix_sort_spine_shader := context.load_shader('res://resources/shaders/compute/radix_sort_spine.glsl')
	var radix_sort_downsweep_shader := context.load_shader('res://resources/shaders/compute/radix_sort_downsweep.glsl')
	shaders['boundaries'] = context.load_shader('res://resources/shaders/compute/gsplat_boundaries.glsl')
	shaders['render'] = context.load_shader('res://resources/shaders/compute/gsplat_render.glsl')
	
	# --- DESCRIPTOR PREPARATION ---
	var num_sort_elements_max := point_cloud.size * 10 # FIXME: This should not be a static value!
	var num_partitions := (num_sort_elements_max + PARTITION_SIZE - 1) / PARTITION_SIZE
	var block_dims : PackedInt32Array; block_dims.resize(2*3); block_dims.fill(1)
	
	descriptors['splats'] = context.create_storage_buffer(point_cloud.size * 60*4)
	descriptors['uniforms'] = context.create_uniform_buffer(8*4)
	descriptors['culled_splats'] = context.create_storage_buffer(point_cloud.size * 12*4)
	descriptors['grid_dimensions'] = context.create_storage_buffer(2*3*4, block_dims.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	descriptors['histogram'] = context.create_storage_buffer(4 + (1 + 4*RADIX + num_partitions*RADIX)*4)
	descriptors['sort_keys'] = context.create_storage_buffer(num_sort_elements_max*4*2)
	descriptors['sort_values'] = context.create_storage_buffer(num_sort_elements_max*4*2)
	descriptors['tile_bounds'] = context.create_storage_buffer(tile_dims.x*tile_dims.y * 2*4)
	descriptors['tile_splat_pos'] = context.create_storage_buffer(4*4)
	descriptors['render_texture'] = context.create_texture(texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	
	var projection_set := context.create_descriptor_set([descriptors['splats'], descriptors['culled_splats'], descriptors['histogram'], descriptors['sort_keys'], descriptors['sort_values'], descriptors['grid_dimensions'], descriptors['uniforms']], projection_shader, 0)
	var radix_sort_upsweep_set := context.create_descriptor_set([descriptors['histogram'], descriptors['sort_keys']], radix_sort_upsweep_shader, 0)
	var radix_sort_spine_set := context.create_descriptor_set([descriptors['histogram']], radix_sort_spine_shader, 0)
	var radix_sort_downsweep_set := context.create_descriptor_set([descriptors['histogram'], descriptors['sort_keys'], descriptors['sort_values']], radix_sort_downsweep_shader, 0)
	var boundaries_set := context.create_descriptor_set([descriptors['histogram'], descriptors['sort_keys'], descriptors['tile_bounds']], shaders['boundaries'], 0)
	var render_set := context.create_descriptor_set([descriptors['culled_splats'], descriptors['sort_values'], descriptors['tile_bounds'], descriptors['tile_splat_pos'], descriptors['render_texture']], shaders['render'], 0)
	
	render_texture.texture_rd_rid = descriptors['render_texture'].rid
	
	# --- COMPUTE PIPELINE CREATION ---
	pipelines['gsplat_projection'] = context.create_pipeline([ceili(point_cloud.size/256.0), 1, 1], [projection_set], projection_shader)
	pipelines['radix_sort_upsweep'] = context.create_pipeline([], [radix_sort_upsweep_set], radix_sort_upsweep_shader)
	pipelines['radix_sort_spine'] = context.create_pipeline([RADIX, 1, 1], [radix_sort_spine_set], radix_sort_spine_shader)
	pipelines['radix_sort_downsweep'] = context.create_pipeline([], [radix_sort_downsweep_set], radix_sort_downsweep_shader)
	pipelines['gsplat_boundaries'] = context.create_pipeline([], [boundaries_set], shaders['boundaries'])
	pipelines['gsplat_render'] = context.create_pipeline([tile_dims.x, tile_dims.y, 1], [render_set], shaders['render'])
	
	# Begin loading splats asynchronously
	should_terminate_thread[0] = false
	num_splats_loaded[0] = 0
	load_thread.start(PlyFile.load_gaussian_splats.bind(point_cloud, point_cloud.size / 1000, context.device, descriptors['splats'].rid, should_terminate_thread, num_splats_loaded, loaded.emit))
	
func cleanup_gpu():
	should_terminate_thread[0] = true
	load_thread.wait_to_finish()
	if context: context.free()
	if render_texture: render_texture.texture_rd_rid = RID()

func rasterize() -> void:
	if not context: init_gpu()
	
	var camera_pos := basis_override * camera.global_position
	context.device.buffer_update(descriptors['uniforms'].rid, 0, 8*4, RenderingContext.create_push_constant([-camera_pos.x, -camera_pos.y, camera_pos.z, model_scale[0], texture_size.x, texture_size.y, Time.get_ticks_msec()*1e-3]))
	context.device.buffer_clear(descriptors['histogram'].rid, 0, 4 + 4*RADIX*4) # Clear the sort buffer size and reset global histogram
	context.device.buffer_clear(descriptors['tile_bounds'].rid, 0, tile_dims.x*tile_dims.y * 2*4) # Clear gsplat_boundaries buffer
	#context.device.buffer_update(descriptors['grid_dimensions'].rid, 0, 3*4*2, default_block_dims)
	#context.device.texture_clear(descriptors['render_texture'].rid, Color.BLACK, 0, 1, 0, 1)
	is_loaded = not load_thread.is_alive()
	
	# Run the projection pipeline. This will return how many duplicated points
	# we will actually need to sort after culling.
	context.device.capture_timestamp('Start')
	var compute_list := context.compute_list_begin()
	pipelines['gsplat_projection'].call(context, compute_list, camera_push_constants)
	context.compute_list_end()
	context.device.capture_timestamp('Projection')
	
	# Then, run the sort and gsplat_rasterize pipelines with block sizes based on the
	# amount of points to sort determined in the projection pipeline.
	compute_list = context.compute_list_begin()
	for radix_shift_pass in range(4):
		var push_constant := RenderingContext.create_push_constant([radix_shift_pass, point_cloud.size*10 * (radix_shift_pass % 2), point_cloud.size*10 * (1 - (radix_shift_pass % 2))])
		pipelines['radix_sort_upsweep'].call(context, compute_list, push_constant, [], descriptors['grid_dimensions'].rid, 0)
		pipelines['radix_sort_spine'].call(context, compute_list, push_constant)
		pipelines['radix_sort_downsweep'].call(context, compute_list, push_constant, [], descriptors['grid_dimensions'].rid, 0)
	context.compute_list_end()
	context.device.capture_timestamp('Sort')
	
	compute_list = context.compute_list_begin()
	pipelines['gsplat_boundaries'].call(context, compute_list, [], [], descriptors['grid_dimensions'].rid, 3*4)
	context.compute_list_end()
	context.device.capture_timestamp('Boundaries')
	
	compute_list = context.compute_list_begin()
	pipelines['gsplat_render'].call(context, compute_list, RenderingContext.create_push_constant([float(should_enable_heatmap[0]), -1]))
	context.compute_list_end()
	context.device.capture_timestamp('Render')

func get_splat_position(screen_position : Vector2i) -> Vector3:
	var tile : Vector2i = screen_position * render_scale[0] / TILE_SIZE
	var tile_id := tile.y*tile_dims.x + tile.x
	
	var compute_list := context.compute_list_begin()
	pipelines['gsplat_render'].call(context, compute_list, RenderingContext.create_push_constant([float(should_enable_heatmap[0]), tile_id]))
	context.compute_list_end()

	var splat_data := context.device.buffer_get_data(descriptors['tile_splat_pos'].rid, 0, 4*4).to_float32_array()
	return Vector3.INF if splat_data[3] == 0 else basis_override.inverse() * Vector3(-splat_data[0], -splat_data[1], splat_data[2])

## Returns whether the view and projection matrices had changed since the last time this function
## was called.
func update_camera_matrices() -> bool:
	var view := Projection(Transform3D(basis_override, Vector3.ZERO) * camera.get_camera_transform())
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
