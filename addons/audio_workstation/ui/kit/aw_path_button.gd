@tool
class_name AWPathButton
extends Button
## A flat, left-aligned button showing a path such as "Clip 2\Low Pass\Cutoff". When it is
## too narrow the middle is replaced with "…" (the Apple convention) so the start and the end
## stay readable; the tooltip carries the full path.

var full_text := ""


func set_path(p: String) -> void:
	full_text = p
	tooltip_text = p
	clip_text = true
	_fit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		_fit()


func _fit() -> void:
	if full_text == "":
		return
	var pad := get_theme_stylebox("normal").get_minimum_size().x + 6.0
	text = AWTheme.middle_truncate(get_theme_default_font(), get_theme_default_font_size(), full_text, size.x - pad)
