extends Node

const DEFAULT_SPLAT_PLY_FILE := 'res://resources/demo.ply'

@onready var viewport : Viewport = get_viewport()
@onready var camera : FreeLookCamera = $Camera
@onready var material : ShaderMaterial = $RenderedImage.get_surface_override_material(0)
@onready var camera_fov := [camera.fov]

var rasterizer : GaussianSplattingRasterizer
var loaded_file : String
var num_sorted_gaussians := '0'
var video_memory_used := '0.00MB'
var time_since_paused := 0.0
var should_render_imgui := true
var should_freeze_render := [true]
var render_scale := [1.0]

func _init() -> void:
	DisplayServer.window_set_size(DisplayServer.screen_get_size() * 0.75)
	DisplayServer.window_set_position(DisplayServer.screen_get_size() * 0.25 / 2.0)

func _ready() -> void:
	should_render_imgui = not Engine.is_editor_hint()

	init_rasterizer(DEFAULT_SPLAT_PLY_FILE)
	
	viewport.files_dropped.connect(func(files : PackedStringArray):
		if files[0].ends_with('.ply'): init_rasterizer(files[0]))
	viewport.size_changed.connect(reset_rasterizer_texture)

func _render_imgui() -> void:
	if Engine.get_frames_drawn() % 8 == 0 and rasterizer and rasterizer.descriptors.has('histogram'): 
		num_sorted_gaussians = add_number_separator(rasterizer.context.device.buffer_get_data(rasterizer.descriptors['histogram'].rid, 0, 4).decode_u32(0))
		var vram_bytes := rasterizer.context.device.get_memory_usage(RenderingDevice.MEMORY_TOTAL)
		video_memory_used = '%.2f%s' % [vram_bytes * (1e-6 if vram_bytes < 1e9 else 1e-9), 'MB' if vram_bytes < 1e9 else 'GB']
	var fps := Engine.get_frames_per_second()
	
	ImGui.Begin(' ', [], ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove)
	ImGui.SetWindowPos(Vector2(20, 20))
	
	ImGui.Text('Drag and drop .ply files on the window to load!')
	ImGui.SeparatorText('GaussianSplatting')
	ImGui.Text('FPS:             %d (%s)' % [fps, '%.2fms' % (1e3 / fps) if time_since_paused <= 1.0 or not should_freeze_render[0] else 'paused'])
	ImGui.Text('Loaded File:     %s' % ['(loading...)' if rasterizer and not rasterizer.is_loaded else loaded_file])
	ImGui.Text('VRAM Used:       %s' % video_memory_used)
	ImGui.Text('Sorted Splats:   %s' % num_sorted_gaussians)
	ImGui.Text('Allow Pause:    '); ImGui.SameLine(); ImGui.Checkbox('##pause_bool', should_freeze_render)
	ImGui.Text('Render Scale:   '); ImGui.SameLine(); if ImGui.SliderFloat('##scale_float', render_scale, 0.05, 1.5): reset_rasterizer_texture()
	ImGui.SeparatorText('Camera')
	ImGui.Text('Cursor Position: %+.2v' % $Camera/Cursor.global_position)
	ImGui.Text('Camera Position: %+.2v' % camera.global_position)
	ImGui.Text('Camera Mode:     %s' % FreeLookCamera.RotationMode.keys()[camera.rotation_mode].capitalize())
	ImGui.Text('Camera FOV:     '); ImGui.SameLine(); if ImGui.SliderFloat('##fov_float', camera_fov, 20, 170): camera.fov = camera_fov[0]; camera.is_dirty = true
	ImGui.Dummy(Vector2(0,0)); ImGui.Separator(); ImGui.Dummy(Vector2(0,0))
	ImGui.PushStyleColor(ImGui.Col_Text, Color.WEB_GRAY); 
	ImGui.Text('Press %s-H to toggle GUI visibility!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl']); 
	ImGui.Text('Press %s-F to toggle fullscreen!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl']); 
	ImGui.PopStyleColor()
	ImGui.End()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed('toggle_imgui'):
		should_render_imgui = not should_render_imgui
		$Camera/Cursor.visible = should_render_imgui
	elif event.is_action_pressed('toggle_fullscreen'):
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed('ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and camera.rotation_mode == FreeLookCamera.RotationMode.NONE:
			var splat_pos := rasterizer.get_splat_position(event.position * render_scale[0])
			if splat_pos == Vector3.INF: return
			camera.set_focused_position(splat_pos)

func init_rasterizer(ply_file_path : String) -> void:
	if rasterizer: RenderingServer.call_on_render_thread(rasterizer.cleanup_gpu)
	
	var render_texture := Texture2DRD.new()
	rasterizer = GaussianSplattingRasterizer.new(PlyFile.new(ply_file_path), viewport.size * render_scale[0], render_texture, camera)
	loaded_file = ply_file_path.get_file()
	material.set_shader_parameter('render_texture', render_texture)
	camera.reset()

func reset_rasterizer_texture() -> void:
	rasterizer.is_loaded = false
	rasterizer.texture_size = viewport.size * render_scale[0]
	material.set_shader_parameter('render_texture', rasterizer.render_texture)

func _process(delta: float) -> void:
	if should_render_imgui:
		_render_imgui()
	camera.enable_camera_movement = not ImGui.IsAnyItemHovered()
	
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
