class_name PlyFile extends Resource

var num_vertices : int
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
			'element':  num_vertices = int(line[2])
			'property': properties.push_back(line[2])
	vertices = file.get_buffer(num_vertices * len(properties) * 4).to_float32_array()
	
func get_vertex(index : int) -> Dictionary:
	var start_index := len(properties) * index
	var vertex := {}
	for i in len(properties):
		vertex[properties[i]] = vertices[start_index + i]
	return vertex
	
static func load_gaussian_splats(point_cloud : PlyFile, device : RenderingDevice, buffer : RID, stride := 10000):
	var sigmoid = func(z): return 1.0 / (1.0 + exp(-z))
	# We swizzle point data so that it matches the std430 layout struct in our kernels
	var points := PackedFloat32Array(); points.resize(60*stride)
	var p := point_cloud.vertices
	for i in range(ceili(float(point_cloud.num_vertices) / stride)):
		var tile_size := mini(point_cloud.num_vertices - i*stride - 1, stride)
		for j in range(tile_size):
			var v := len(point_cloud.properties)*(i*stride + j) # Vertex index
			var b := j*60                                       # Point index
			
			for k in range(0, 3):  points[b+k+0] = p[v+k+0]       # Position
			for k in range(0, 3):  points[b+k+4] = exp(p[v+k+55]) # Scale
			points[b+7] = sigmoid.call(p[v+54])                   # Opacity
			for k in range(0, 4):  points[b+k+8] = p[v+k+58]      # Quaternion
			# Spherical harmonic coefficients 
			for k in range(0, 3): points[b+k+12] = p[v+k+6]
			for k in range(0, 45, 3): 
				points[b+(k+0)+15] = p[v+(k/3+0)+9]
				points[b+(k+1)+15] = p[v+(k/3+15)+9]
				points[b+(k+2)+15] = p[v+(k/3+30)+9]
		device.buffer_update(buffer, i*60*4*stride, 60*4*tile_size, points.to_byte_array())
