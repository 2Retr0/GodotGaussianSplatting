class_name PlyFile extends Resource

var size : int
var vertices : PackedFloat32Array
var properties : Array[StringName]

func _init(path:='') -> void:
	if not path.is_empty(): parse(path)

func parse(path : String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	var line := file.get_line().split(' ')
	while not line[0] == 'end_header':
		line = file.get_line().split(' ')
		match line[0]:
			'format':   file.big_endian = line[1] == 'binary_big_endian'
			'element':  size = int(line[2])
			'property': properties.push_back(line[2])
	vertices = file.get_buffer(size*len(properties) * 4).to_float32_array()
	
func get_vertex(index : int) -> Dictionary:
	var start_index := len(properties) * index
	var vertex := {}
	for i in len(properties):
		vertex[properties[i]] = vertices[start_index + i]
	return vertex

static func load_gaussian_splats(point_cloud : PlyFile, stride : int, device : RenderingDevice, buffer : RID, should_terminate_reference : Array[bool], num_points_loaded : Array[int], callback : Callable):
	const STRUCT_SIZE := 60 # floats
	assert(len(should_terminate_reference) == 1 and len(num_points_loaded) == 1)
	var num_propoerties := len(point_cloud.properties)
	var p := point_cloud.vertices
	var mutex := Mutex.new()
	var task_id = WorkerThreadPool.add_group_task(func(i : int):
		if should_terminate_reference[0]: return
		# We swizzle point data so that it matches the std430 layout struct in our kernels
		var points := PackedFloat32Array(); points.resize(STRUCT_SIZE*stride)
		var tile_size := mini(point_cloud.size - i*stride, stride)
		var creation_time := Time.get_ticks_msec()*1e-3
		for j in tile_size:
			var v := num_propoerties*(i*stride + j) # Vertex index
			var b := j*STRUCT_SIZE                  # Point index
			
			### Position ###
			for k in range(3):  points[b+k+0] = p[v+k+0]
			points[b+3] = creation_time
			
			### 3D Covariance (precomputed) ###
			var scale := Basis.from_scale(Vector3(exp(p[v+0+55]), exp(p[v+1+55]), exp(p[v+2+55])))
			var rotation := Basis(Quaternion(p[v+1+58], p[v+2+58], p[v+3+58], p[v+0+58])).transposed()
			var cov_3d := (scale * rotation).transposed() * (scale * rotation)
			
			# We only store the top triangle of the covariance since the matrix is symmetric!
			points[b+0+4] = cov_3d.x[0]
			points[b+1+4] = cov_3d.y[0]
			points[b+2+4] = cov_3d.z[0]
			points[b+3+4] = cov_3d.y[1]
			points[b+4+4] = cov_3d.z[1]
			points[b+5+4] = cov_3d.z[2]
			
			### Opacity ###
			points[b+6+4] = 1.0 / (1.0 + exp(-p[v+54]))
			
			### Spherical Harmonic Coefficients ###
			for k in range(3): points[b+k+12] = p[v+k+6]
			for k in range(0, 45, 3): 
				points[b+(k+0)+15] = p[v+(k/3+ 0)+9]
				points[b+(k+1)+15] = p[v+(k/3+15)+9]
				points[b+(k+2)+15] = p[v+(k/3+30)+9]
		if should_terminate_reference[0]: return
		device.buffer_update(buffer, i*STRUCT_SIZE*stride * 4, STRUCT_SIZE*tile_size * 4, points.to_byte_array())
		mutex.lock()
		num_points_loaded[0] += tile_size
		mutex.unlock()
		, ceili(point_cloud.size / stride + 1))
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	callback.call()
