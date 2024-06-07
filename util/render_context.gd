class_name RenderingContext extends Object
## A wrapper around [RenderingDevice] that handles basic memory management/allocation 

class DeletionQueue:
	var queue : Array[RID] = []
	
	func push(rid : RID) -> RID:
		queue.push_back(rid)
		return rid
	
	func flush(device : RenderingDevice) -> void:
		# We work backwards in order of allocation when freeing resources
		for i in range(queue.size() - 1, -1, -1):
			device.free_rid(queue[i])
			queue[i] = RID()
		queue.clear()
	
class Descriptor:
	var rid : RID
	var type : RenderingDevice.UniformType
	
	func _init(rid_ : RID, type_ : RenderingDevice.UniformType) -> void:
		rid = rid_; type = type_
		
var device : RenderingDevice
var deletion_queue := DeletionQueue.new()
var needs_sync := false

static func create(device : RenderingDevice=null) -> RenderingContext:
	var context := RenderingContext.new()
	context.device = RenderingServer.create_local_rendering_device() if not device else device
	return context
	
func free() -> void:
	if not device: return
	
	# All resources must be freed after use to avoid memory leaks.
	deletion_queue.flush(device)
	device.free()
	device = null
	
# --- WRAPPER FUNCTIONS ---
func submit() -> void: device.submit(); needs_sync = true
func sync() -> void: device.sync(); needs_sync = false
func compute_list_begin() -> int: return device.compute_list_begin()
func compute_list_end() -> void: device.compute_list_end()

# --- HELPER FUNCTIONS ---
## Loads and compiles a [code].glsl[/code] compute shader.
func load_shader(path : String) -> RID:
	var shader_spirv : RDShaderSPIRV = load(path).get_spirv()
	return deletion_queue.push(device.shader_create_from_spirv(shader_spirv))

func create_storage_buffer(size : int, data : PackedByteArray=[], usage:=RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT) -> Descriptor:
	if size > len(data):
		var padding := PackedByteArray(); padding.resize(size - len(data))
		data += padding
	return Descriptor.new(deletion_queue.push(device.storage_buffer_create(max(size, len(data)), data, usage)), RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)

func create_uniform_buffer(size : int, data : PackedByteArray=[]) -> Descriptor:
	if size > len(data):
		var padding := PackedByteArray(); padding.resize(size - len(data))
		data += padding
	return Descriptor.new(deletion_queue.push(device.uniform_buffer_create(max(size, len(data)), data)), RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)

func create_texture(dimensions : Vector2, format : RenderingDevice.DataFormat, usage:=0x10B, view:=RDTextureView.new(), data : PackedByteArray=[]) -> Descriptor:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format
	texture_format.width = int(dimensions.x)
	texture_format.height = int(dimensions.y)
	texture_format.usage_bits = usage # Default: RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return Descriptor.new(deletion_queue.push(device.texture_create(texture_format, view, data)), RenderingDevice.UNIFORM_TYPE_IMAGE)

## Creates a descriptor set. The ordering of the provided descriptors matches the binding ordering
## within the shader.
func create_descriptor_set(descriptors : Array[Descriptor], shader : RID, descriptor_set_index :=0) -> RID:
	var uniforms : Array[RDUniform]
	for i in range(len(descriptors)):
		var uniform := RDUniform.new()
		uniform.uniform_type = descriptors[i].type
		uniform.binding = i  # This matches the binding in the shader.
		uniform.add_id(descriptors[i].rid)
		uniforms.push_back(uniform)
	return deletion_queue.push(device.uniform_set_create(uniforms, shader, descriptor_set_index))

## Returns a [Callable] which will dispatch a compute pipeline (within a compute) list based on the
## provided block dimensions. The ordering of the provided descriptor sets matches the set ordering
## within the shader.
func create_pipeline(block_dimensions : Array, descriptor_sets : Array, shader : RID) -> Callable:
	var pipeline = deletion_queue.push(device.compute_pipeline_create(shader))
	return func(context : RenderingContext, compute_list : int, push_constant:=[], descriptor_set_overwrites:=[], block_dimension_overwrites:=[]) -> void:
		var device := context.device
		var dims := block_dimensions if block_dimension_overwrites.is_empty() else block_dimension_overwrites
		var sets = descriptor_sets if descriptor_set_overwrites.is_empty() else descriptor_set_overwrites
		assert(len(dims) == 3, 'Must specify block dimensions for all x, y, z dimensions!')
		assert(len(sets) >= 1, 'Must specify at least on descriptor set!')
		
		device.compute_list_bind_compute_pipeline(compute_list, pipeline)
		for i in range(len(sets)):
			device.compute_list_bind_uniform_set(compute_list, sets[i], i)
			
		if not push_constant.is_empty():
			var packed_push_constant := create_push_constant(push_constant)
			device.compute_list_set_push_constant(compute_list, packed_push_constant, packed_push_constant.size())
			
		device.compute_list_dispatch(compute_list, dims[0], dims[1], dims[2])
		device.compute_list_add_barrier(compute_list) # FIXME: Barrier may not always be needed, but whatever...

## Returns a [PackedFloat32Array] from the provided data, whose size is rounded up to the nearest
## multiple of 16
func create_push_constant(data : Array) -> PackedByteArray:
	var packed_size := len(data)*4
	assert(packed_size <= 128, 'Push constant size must be at most 128 bytes!')
	
	var padding := ceili(packed_size/16.0)*16 - packed_size
	var packed_data := PackedByteArray(); 
	packed_data.resize(packed_size + (padding if padding > 0 else 0)); 
	packed_data.fill(0);
	
	for i in range(len(data)):
		match typeof(data[i]):
			TYPE_INT, TYPE_BOOL:   packed_data.encode_s32(i*4, data[i])
			TYPE_FLOAT: packed_data.encode_float(i*4, data[i])
	return packed_data
