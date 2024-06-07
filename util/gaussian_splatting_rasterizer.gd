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

var texture_size : Vector2i :
	set(value):
		texture_size = value
		if not descriptors.has('output_texture') or not context: return
		# Rebuild boundaries and rasterize pielines (since those depend on texture size)
		descriptors['boundaries'] = context.create_storage_buffer(ceili(float(value.x * value.y) / (TILE_SIZE*TILE_SIZE)) * 2*4)
		descriptors['output_texture'] = context.create_texture(value, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)

		pipelines['boundaries'] = context.create_pipeline([], [context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['boundaries']], shaders['boundaries'], 0)], shaders['boundaries'])
		pipelines['rasterize'] = context.create_pipeline([ceili(float(value.x)/TILE_SIZE), ceili(float(value.y)/TILE_SIZE), 1], [context.create_descriptor_set([descriptors['culled_points'], descriptors['sort_buffer0'], descriptors['boundaries'], descriptors['output_texture']], shaders['rasterize'], 0)], shaders['rasterize'])
		render_texture.texture_rd_rid = descriptors['output_texture'].rid
		
var load_thread := Thread.new()
var is_loaded := false
var should_terminate_thread := false

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
	var radix_sort_histogram_shader := context.load_shader('res://resources/shaders/compute/radix_sort_histogram.glsl')
	var radix_sort_shader := context.load_shader('res://resources/shaders/compute/radix_sort.glsl')
	shaders['boundaries'] = context.load_shader('res://resources/shaders/compute/gsplat_boundaries.glsl')
	shaders['rasterize'] = context.load_shader('res://resources/shaders/compute/gsplat_rasterize.glsl')
	
	# --- DESCRIPTOR PREPARATION ---
	var num_sort_elements_max := ceili(point_cloud.num_vertices * 10) # FIXME: This should not be a static value!
	var num_workgroups := ceili(num_sort_elements_max / WORKGROUP_SIZE)
	
	descriptors['points'] = context.create_storage_buffer(point_cloud.num_vertices*60*4)
	descriptors['uniforms'] = context.create_uniform_buffer(8*4)
	descriptors['culled_points'] = context.create_storage_buffer(point_cloud.num_vertices * 16*4)
	descriptors['sort_buffer0'] = context.create_storage_buffer(num_sort_elements_max * 2*4)
	descriptors['sort_buffer1'] = context.create_storage_buffer(num_sort_elements_max * 2*4)
	descriptors['boundaries'] = context.create_storage_buffer(ceili(float(texture_size.x * texture_size.y) / (TILE_SIZE*TILE_SIZE)) * 2*4)
	descriptors['histogram'] = context.create_storage_buffer(4 + num_workgroups * RADIX_SORT_BINS * 4)
	descriptors['output_texture'] = context.create_texture(texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	
	var projection_set := context.create_descriptor_set([descriptors['points'], descriptors['culled_points'], descriptors['histogram'], descriptors['sort_buffer0'], descriptors['uniforms']], projection_shader, 0)
	var boundaries_set := context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['boundaries']], shaders['boundaries'], 0)
	var rasterize_set := context.create_descriptor_set([descriptors['culled_points'], descriptors['sort_buffer0'], descriptors['boundaries'], descriptors['output_texture']], shaders['rasterize'], 0)
	descriptor_sets['radix_sort0'] = context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer0'], descriptors['sort_buffer1']], radix_sort_shader, 0)
	descriptor_sets['radix_sort1'] = context.create_descriptor_set([descriptors['histogram'], descriptors['sort_buffer1'], descriptors['sort_buffer0']], radix_sort_shader, 0)
	
	render_texture.texture_rd_rid = descriptors['output_texture'].rid
	
	# --- COMPUTE PIPELINE CREATION ---
	pipelines['projection'] = context.create_pipeline([ceili(point_cloud.num_vertices/256.0), 1, 1], [projection_set], projection_shader)
	pipelines['radix_sort_histogram'] = context.create_pipeline([], [], radix_sort_histogram_shader)
	pipelines['radix_sort'] = context.create_pipeline([], [], radix_sort_shader)
	pipelines['boundaries'] = context.create_pipeline([], [boundaries_set], shaders['boundaries'])
	pipelines['rasterize'] = context.create_pipeline([ceili(float(texture_size.x)/TILE_SIZE), ceili(float(texture_size.y)/TILE_SIZE), 1], [rasterize_set], shaders['rasterize'])
	
	# Begin loading splats asynchronously
	load_thread.start(PlyFile.load_gaussian_splats.bind(point_cloud, context.device, descriptors['points'].rid, func(): return should_terminate_thread))
	
func cleanup_gpu():
	if load_thread.is_alive():
		should_terminate_thread = true
		load_thread.wait_to_finish()
	if context: context.free()
	if render_texture: render_texture.texture_rd_rid = RID()
	
func rasterize() -> void:
	if not context: init_gpu()
	context.device.buffer_clear(descriptors['histogram'].rid, 0, 4)
	context.device.buffer_update(descriptors['uniforms'].rid, 0, 8*4, context.create_push_constant([camera.global_position.x, camera.global_position.y, camera.global_position.z, point_cloud.num_vertices, texture_size.x, texture_size.y]))
	
	is_loaded = not load_thread.is_alive()
	
	# Run the projection pipeline. This will return how many duplicated points
	# we will actually need to sort after culling.
	var compute_list := context.compute_list_begin()
	pipelines['projection'].call(context, compute_list, _get_projection_pipeline_push_constant())
	context.compute_list_end()
	
	var num_to_sort := float(context.device.buffer_get_data(descriptors['histogram'].rid, 0, 4).decode_u32(0))
	var radix_sort_dims := [ceili(num_to_sort / NUM_BLOCKS_PER_WORKGROUP), 1, 1]
	var boundaries_dims := [ceili(num_to_sort / 256), 1, 1]
	if num_to_sort <= 0: return
	
	# Then, run the sort and rasterize pipelines with block sizes based on the
	# amount of points to sort determined in the projection pipeline.
	compute_list = context.compute_list_begin()
	for shift in range(0, 32, 8):
		var descriptor_set = [descriptor_sets['radix_sort%d' % ((shift / 8) % 2)]]
		pipelines['radix_sort_histogram'].call(context, compute_list, [shift], descriptor_set, radix_sort_dims)
		pipelines['radix_sort'].call(context, compute_list, [shift], descriptor_set, radix_sort_dims)
	pipelines['boundaries'].call(context, compute_list, [], [], boundaries_dims)
	pipelines['rasterize'].call(context, compute_list)
	context.compute_list_end()

func _get_projection_pipeline_push_constant() -> Array:
	assert(camera and point_cloud, 'A Camera3D and PlyFile must be set!')
	var proj := camera.get_camera_projection()
	var view := Projection(camera.get_camera_transform())
	return [
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
		proj.w[0], proj.w[1], proj.w[2], 0.0]
