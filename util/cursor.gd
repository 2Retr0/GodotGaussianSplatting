extends MeshInstance3D

const MAX_ALPHA := 0.35

@onready var fade_tween : Tween
@onready var material : StandardMaterial3D = get_surface_override_material(0)

func set_alpha(alpha : float) -> void:
	material.albedo_color.a = alpha

func update_position(new_position : Vector3) -> void:
	if material.albedo_color.a == 0:
		global_position = new_position
	elif global_position != new_position:
		var displacement = new_position - global_position
		var direction = displacement.normalized()
		global_basis = Basis.IDENTITY.rotated(Vector3.UP.cross(direction).normalized(), acos(Vector3.UP.dot(direction)))

		var move_tween := create_tween().set_parallel()
		move_tween.tween_property(self, 'global_position', new_position, 0.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CIRC)
		# Squash and stretch for fun :3
		move_tween.tween_property(self, 'mesh:height', displacement.length()*0.3, 0.05)
		move_tween.tween_property(self, 'mesh:radius', 0.025 / (1.0 + displacement.length()*0.9), 0.05)
		move_tween.tween_property(self, 'mesh:height', 0.05, 0.05).set_delay(0.075)
		move_tween.tween_property(self, 'mesh:radius', 0.025, 0.05).set_delay(0.075)
	if fade_tween: fade_tween.stop()
	fade_tween = create_tween().set_parallel()
	fade_tween.tween_property(self, 'material:albedo_color:a', MAX_ALPHA, 0.25)
	fade_tween.tween_property(self, 'material:albedo_color:a', 0.0, 0.5).set_delay(2.0)
