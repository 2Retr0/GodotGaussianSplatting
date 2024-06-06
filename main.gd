extends Node

## How many times the rasterizer should update per second
@export var update_rate := 144.0

var rasterizer : GaussianSplattingRasterizer

@onready var camera : Camera3D = $Camera
@onready var material : ShaderMaterial = $RenderedImage.get_surface_override_material(0)

var num_sorted_gaussians := 0
var camera_fov := [75.0]

func _ready() -> void:
	init_rasterizer('res://resources/demo.ply')
	get_viewport().files_dropped.connect(func(files : PackedStringArray):
		if files[0].ends_with('.ply'): init_rasterizer(files[0]))

func _render_imgui() -> void:
	if OS.get_name() != 'Windows': return
	
	if Engine.get_frames_drawn() % 8 == 0 and rasterizer and rasterizer.descriptors.has('histogram'): 
		num_sorted_gaussians = rasterizer.context.device.buffer_get_data(rasterizer.descriptors['histogram'].rid, 0, 4).decode_u32(0)
	
	var pos := camera.global_position
	var fps := Engine.get_frames_per_second()
	ImGui.Begin(' ', [], ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove)
	ImGui.SetWindowPos(Vector2(20, 20))
	
	ImGui.Text('Drag and drop .ply files on the window to load!')
	ImGui.Text('')
	ImGui.Text('FPS:             %d (%.2fms)' % [fps, 1e3 / fps])
	ImGui.Text('Camera Position: %+.2f %+.2f %+.2f' % [pos.x, pos.y, pos.z])
	ImGui.Text('#Sorted Splats:  %.3fM' % [num_sorted_gaussians * 1e-6])
	if ImGui.SliderFloat('Camera FOV:', camera_fov, 20, 170):
		$Camera.fov = camera_fov[0]
	ImGui.End()

func init_rasterizer(ply_file_path : String) -> void:
	var render_texture := Texture2DRD.new()
	rasterizer = GaussianSplattingRasterizer.new(PlyFile.new(ply_file_path))
	rasterizer.texture = render_texture
	material.set_shader_parameter('render_texture', render_texture)

func _process(delta: float) -> void:
	_render_imgui()
	
	if not rasterizer: return
	RenderingServer.call_on_render_thread(rasterizer.rasterize.bind(camera))

func _notification(what):
	if what == NOTIFICATION_PREDELETE: 
		RenderingServer.call_on_render_thread(rasterizer.cleanup_gpu)
