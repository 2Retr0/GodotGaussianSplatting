class_name FreeLookCamera extends Camera3D

enum RotationMode { FREE_LOOK, ORBIT, NONE }

@export_range(0.0, 1.0) var mouse_sensitivity: float = 0.4
@export var enable_camera_movement := true :
	set(value):
		enable_camera_movement = value
		if not value: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
@export var run_speed_multiplier := 2.5

# Movement state
var direction = Vector3(0.0, 0.0, 0.0)
var velocity = Vector3(0.0, 0.0, 0.0)
var acceleration = 30
var deceleration = -10
var vel_multiplier = 4

# Keyboard state
var _w = false
var _s = false
var _a = false
var _d = false
var _q = false
var _e = false
var _shift = false
var _alt = false

var orbit_position := -Vector3.FORWARD * 2.0
var target_orbit_position := Vector3.ZERO
var rotation_mode := RotationMode.NONE
var orbit_time := 0.0 # Used for interpolation

@onready var target : Node3D = $Target

func _ready() -> void:
	$OrbitSwapTimer.timeout.connect(func(): 
		target.global_transform = global_transform
		target.look_at_from_position(global_position, orbit_position)
		# Skip interpolation time if camera is already facing orbit position
		orbit_time = 0.0 if 1.0 - global_basis.get_rotation_quaternion().dot(target.global_basis.get_rotation_quaternion()) > 1e-5 else 1.0
		rotation_mode = RotationMode.ORBIT)

func _input(event):
	if not enable_camera_movement: return
	
	# Receives mouse motion
	if event is InputEventMouseMotion and rotation_mode != RotationMode.NONE:
		var offset : Vector2 = -event.relative * mouse_sensitivity
		match rotation_mode:
			RotationMode.FREE_LOOK:
				rotation_degrees += Vector3(offset.y, offset.x, 0.0)
				rotation_degrees.x = clamp(rotation_degrees.x, -80.0, 70.0)
			RotationMode.ORBIT:
				var pitch : float = target.rotation_degrees.x - offset.y
				var rotated_pos : Vector3 = target.global_position - orbit_position
				if pitch >= -80.0 and pitch <= 70.0:
					rotated_pos = rotated_pos.rotated(target.global_basis.x, deg_to_rad(-offset.y))
				rotated_pos = rotated_pos.rotated(target.global_basis.y, deg_to_rad(-offset.x)*cos(deg_to_rad(pitch)))
				rotated_pos += orbit_position
				target.look_at_from_position(rotated_pos, orbit_position)

	# Receives mouse button input
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if not event.pressed: 
					$OrbitSwapTimer.stop()
					await get_tree().create_timer(1e-2).timeout # << peak code
					rotation_mode = RotationMode.NONE
				else:
					$OrbitSwapTimer.start()
			MOUSE_BUTTON_RIGHT: # Only allows rotation if right click down
				rotation_mode = RotationMode.FREE_LOOK if event.pressed else RotationMode.NONE
			MOUSE_BUTTON_WHEEL_UP:
				if orbit_position.distance_to(target.position) > 0.75:
					target.position += (orbit_position - target.position).normalized()*0.25
				$Cursor.update_position(orbit_position)
			MOUSE_BUTTON_WHEEL_DOWN:
				target.position -= (orbit_position - target.position).normalized()*0.25
				$Cursor.update_position(orbit_position)

	# Receives key input
	if event is InputEventKey:
		match event.keycode:
			KEY_A: _a = event.pressed
			KEY_D: _d = event.pressed
			KEY_Q: _q = event.pressed
			KEY_E: _e = event.pressed
			KEY_W: _w = event.pressed
			KEY_S: _s = event.pressed
			KEY_SHIFT: _shift = event.pressed
			KEY_ALT: _alt = event.pressed

# Updates mouselook and movement every frame
func _process(delta):
	_update_movement(delta)

func _physics_process(delta: float) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if rotation_mode != RotationMode.NONE else Input.MOUSE_MODE_VISIBLE
	if rotation_mode == RotationMode.ORBIT: $Cursor.update_position(orbit_position)

# Updates camera movement
func _update_movement(delta):
	if rotation_mode != RotationMode.ORBIT:
		# Computes desired direction from key states
		direction = Vector3(
			(_d as float) - (_a as float), 
			(_e as float) - (_q as float),
			(_s as float) - (_w as float)
		)
		
		# Computes the change in velocity due to desired direction and "drag"
		# The "drag" is a constant acceleration on the camera to bring it's velocity to 0
		var offset = (direction.normalized() * acceleration + velocity.normalized() * deceleration) * vel_multiplier * delta
		
		# Compute modifiers' speed multiplier
		var speed_multi = 1
		if _shift: speed_multi *= run_speed_multiplier
		if _alt: speed_multi *= 1.0 / run_speed_multiplier
		
		# Checks if we should bother translating the camera
		if direction == Vector3.ZERO and offset.length_squared() > velocity.length_squared():
			velocity = Vector3.ZERO
		else:
			velocity = (velocity + offset).clampf(-vel_multiplier, vel_multiplier)
			translate(velocity * delta * speed_multi)
		if not velocity.is_zero_approx(): target.position = global_position
	else:
		orbit_time += delta
		# Our target position will be the target position from the cursor, but with a distance
		# that is the current distance of the camera. This way we can still have smooth interpolation
		# for zooming.
		var target_pos_same_radius := orbit_position + (target.global_position - orbit_position).normalized() * (orbit_position - global_position).length()
		# Smoothing is less at lower fps
		var t := 1.0 - (1.0 - orbit_time*lerpf(1.0, 0.1, minf(Engine.get_frames_per_second() / 180.0, 1.0)))**3 if orbit_time < 0.4 else 1.0
		global_basis = Basis(global_basis.get_rotation_quaternion().slerp(target.global_basis.get_rotation_quaternion(), t))
		global_position = global_position.slerp(target_pos_same_radius, t)
	
	# Smooth camera distance transition
	if global_position.distance_squared_to(target.position) > 1e-6:
		global_position = global_position.lerp(target.position, minf(delta*5.0, 1.0))

func set_focused_position(target_position : Vector3) -> void:
	if not enable_camera_movement: return
	
	orbit_position = target_position
	target.position = target_position + global_basis.z*2.0
	$Cursor.update_position(orbit_position)

func reset() -> void:
	position = Vector3.ZERO
	rotation = Vector3.UP * -PI
	target_orbit_position = Vector3.ZERO
	orbit_position = -Vector3.FORWARD * 2.0
	rotation_mode = RotationMode.NONE
	target.position = target_orbit_position
	$Cursor.set_alpha(0.0)
	$Cursor.update_position(orbit_position)
