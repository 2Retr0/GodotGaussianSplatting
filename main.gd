extends Node

const DEFAULT_SPLAT_PLY_FILE := 'res://resources/demo.ply'

@onready var viewport : Viewport = get_viewport()
@onready var camera : FreeLookCamera = $Camera
@onready var material : ShaderMaterial = $RenderedImage.get_surface_override_material(0)
@onready var camera_fov := [camera.fov]

var rasterizer : GaussianSplattingRasterizer
var loaded_file : String
var num_sorted_gaussians := '0'
var time_since_paused := 0.0
var should_render_imgui := true
var should_freeze_render := [true]

func _init() -> void:
	DisplayServer.window_set_size(DisplayServer.screen_get_size() * 0.75)
	DisplayServer.window_set_position(DisplayServer.screen_get_size() * 0.25 / 2.0)

func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_tree().root.get_viewport_rid(), true)
	should_render_imgui = not Engine.is_editor_hint()

	init_rasterizer(DEFAULT_SPLAT_PLY_FILE)
	
	viewport.files_dropped.connect(func(files : PackedStringArray):
		if files[0].ends_with('.ply'): init_rasterizer(files[0]))
	viewport.size_changed.connect(func():
		rasterizer.is_loaded = false
		rasterizer.texture_size = viewport.size
		material.set_shader_parameter('render_texture', rasterizer.render_texture))

func _render_imgui() -> void:
	var viewport_rid := get_tree().root.get_viewport_rid()
	var frame_time = RenderingServer.get_frame_setup_time_cpu() + RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid) + RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
	
	if Engine.get_frames_drawn() % 8 == 0 and rasterizer and rasterizer.descriptors.has('histogram'): 
		num_sorted_gaussians = add_number_separator(rasterizer.context.device.buffer_get_data(rasterizer.descriptors['histogram'].rid, 0, 4).decode_u32(0))
	
	ImGui.Begin(' ', [], ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove)
	ImGui.SetWindowPos(Vector2(20, 20))
	
	ImGui.Text('Drag and drop .ply files on the window to load!')
	ImGui.SeparatorText('GaussianSplatting')
	ImGui.Text('FPS:             %d (%s)' % [Engine.get_frames_per_second(), '%.2fms' % frame_time if time_since_paused <= 1.0 or not should_freeze_render[0] else 'paused'])
	ImGui.Text('Loaded File:     %s%s' % [loaded_file, ' (loading...)' if rasterizer and not rasterizer.is_loaded else ''])
	ImGui.Text('Sorted Splats:   %s' % num_sorted_gaussians)
	ImGui.Text('Allow pause:    '); ImGui.SameLine(); ImGui.Checkbox('##pause_bool', should_freeze_render)
	ImGui.SeparatorText('Camera')
	ImGui.Text('Camera Position:  %+.2v' % camera.global_position)
	ImGui.Text('Camera FOV:     '); ImGui.SameLine(); if ImGui.SliderFloat('##FOV', camera_fov, 20, 170): camera.fov = camera_fov[0]
	ImGui.Dummy(Vector2(0,0)); ImGui.Separator(); ImGui.Dummy(Vector2(0,0))
	ImGui.PushStyleColor(ImGui.Col_Text, Color.WEB_GRAY); 
	ImGui.Text('Press %s-H to toggle GUI visibility!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl']); 
	ImGui.Text('Press %s-F to toggle fullscreen!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl']); 
	ImGui.PopStyleColor()
	ImGui.End()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed('toggle_imgui'):
		should_render_imgui = not should_render_imgui
	elif event.is_action_pressed('toggle_fullscreen'):
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed('ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

func init_rasterizer(ply_file_path : String) -> void:
	if rasterizer: RenderingServer.call_on_render_thread(rasterizer.cleanup_gpu)
	
	var render_texture := Texture2DRD.new()
	rasterizer = GaussianSplattingRasterizer.new(PlyFile.new(ply_file_path), viewport.size, render_texture, camera)
	loaded_file = ply_file_path.get_file()
	material.set_shader_parameter('render_texture', render_texture)

func _process(delta: float) -> void:
	if should_render_imgui:
		_render_imgui()
	camera.enable_camera_movement = not ImGui.IsAnyItemActive()
	
	if camera.is_dirty or (rasterizer and not rasterizer.is_loaded): 
		camera.is_dirty = false
		time_since_paused = 0.0
	else:
		time_since_paused += delta
	
	if time_since_paused <= 1.0 or not should_freeze_render[0]:
		RenderingServer.call_on_render_thread(rasterizer.rasterize)
		Engine.max_fps = 0
	else:
		Engine.max_fps = 30

func _notification(what):
	if what == NOTIFICATION_PREDELETE and rasterizer: 
		RenderingServer.call_on_render_thread(rasterizer.cleanup_gpu)

## Source: https://sh.reddit.com/r/godot/comments/yljjmd/comment/iuz0x43/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button
static func add_number_separator(number : int, separator : String = ',') -> String:
	var in_str := str(number)
	var out_chars := PackedStringArray()
	var length := in_str.length()
	for i in range(1, length + 1):
		out_chars.append(in_str[length - i])
		if i < length and i % 3 == 0:
			out_chars.append(separator)
	out_chars.reverse()
	return ''.join(out_chars)
