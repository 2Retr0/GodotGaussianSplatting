extends ColorRect

const MAX_ALPHA := 0.6

@onready var fade_tween : Tween

func set_visibility(is_visible : bool) -> void:
	if fade_tween: fade_tween.stop()
	if is_visible:
		color.a = MAX_ALPHA
	else:
		fade_tween = get_tree().create_tween()
		fade_tween.tween_property(self, 'color:a', 0.0, 0.4)

func update_progress(progress : float) -> void:
	var width := DisplayServer.window_get_size(0).x
	size.x = width
	position.x = -width + width*progress
