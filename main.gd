extends Node

const DEFAULT_SPLAT_PLY_FILE := 'res://resources/demo.ply'

@onready var viewport : Viewport = get_viewport()
@onready var camera : FreeLookCamera = $Camera
@onready var material : ShaderMaterial = $RenderedImage.get_surface_override_material(0)
@onready var camera_fov := [$Camera.fov]

var rasterizer : GaussianSplattingRasterizer
var loaded_file : String
var num_sorted_gaussians := 0

func _ready() -> void:
	resize_window(DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()) * 0.7)
	init_rasterizer(DEFAULT_SPLAT_PLY_FILE)
	
	viewport.files_dropped.connect(func(files : PackedStringArray):
		if files[0].ends_with('.ply'): init_rasterizer(files[0]))
	viewport.size_changed.connect(func():
		rasterizer.texture_size = viewport.size)

func _render_imgui() -> void:
	if OS.get_name() != 'Windows': return
	
	if Engine.get_frames_drawn() % 8 == 0 and rasterizer and rasterizer.descriptors.has('histogram'): 
		num_sorted_gaussians = rasterizer.context.device.buffer_get_data(rasterizer.descriptors['histogram'].rid, 0, 4).decode_u32(0)
	
	var pos := camera.global_position
	var fps := Engine.get_frames_per_second()
	ImGui.Begin(' ', [], ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove)
	ImGui.SetWindowPos(Vector2(20, 20))
	
	ImGui.Text('Drag and drop .ply files on the window to load!')
	ImGui.SeparatorText('')
	ImGui.Text('FPS:             %d (%s)' % [fps, '%.2fms' % [1e3 / fps] if camera.is_dirty or not (rasterizer and rasterizer.is_loaded) else 'paused'])
	ImGui.Text('Loaded File:     %s%s' % [loaded_file, ' (loading...)' if rasterizer and rasterizer.load_thread.is_alive() else ''])
	ImGui.Text('Camera Position: %+.2f %+.2f %+.2f' % [pos.x, pos.y, pos.z])
	ImGui.Text('#Sorted Splats:  %d' % [num_sorted_gaussians])
	ImGui.Text('Camera FOV:     ')
	ImGui.SameLine()
	if ImGui.SliderFloat('##FOV', camera_fov, 20, 170): 
		camera.fov = camera_fov[0]
		camera.is_dirty = true
	ImGui.End()

func init_rasterizer(ply_file_path : String) -> void:
	if rasterizer: RenderingServer.call_on_render_thread(rasterizer.cleanup_gpu)
	
	var render_texture := Texture2DRD.new()
	rasterizer = GaussianSplattingRasterizer.new(PlyFile.new(ply_file_path), viewport.size, render_texture, camera)
	loaded_file = ply_file_path.get_file()
	material.set_shader_parameter('render_texture', render_texture)

func resize_window(size : Vector2i) -> void:
	var old_size := DisplayServer.window_get_size()
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(DisplayServer.window_get_position() + (size - old_size).abs() / 2)

func _process(delta: float) -> void:
	_render_imgui()
	
	if rasterizer and (camera.is_dirty or not rasterizer.is_loaded): 
		RenderingServer.call_on_render_thread(rasterizer.rasterize)
		camera.is_dirty = false

func _notification(what):
	if what == NOTIFICATION_PREDELETE and rasterizer: 
		RenderingServer.call_on_render_thread(rasterizer.cleanup_gpu)
