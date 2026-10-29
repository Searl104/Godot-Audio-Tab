@tool
class_name AWFader
extends Control
## Vertical fader bound to one parameter, shown over a fixed view range (an EQ band's
## parameter allows -60..+24 dB but the fader shows -24..+24). Same gestures as AWKnob.

const DRIVEN := Color("#e6c84a")

var binding: AWParamBinding
var accent := Color("#5ec26a")
var vmin := -24.0
var vmax := 24.0
var selected := false
var _press_y := 0.0
var _start_v := 0.0
var _pressed := false

signal touched


func setup(p_binding: AWParamBinding, p_accent: Color, p_vmin: float, p_vmax: float) -> void:
	binding = p_binding
	accent = p_accent
	vmin = p_vmin
	vmax = p_vmax
	custom_minimum_size = Vector2(40, 110)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_VSIZE
	tooltip_text = "%s\nDrag: change   Shift: fine   Wheel: step   Double-click: reset\nRight-click: curve options" % binding.label


func refresh() -> void:
	queue_redraw()


func _frac(v: float) -> float:
	return clampf((v - vmin) / (vmax - vmin), 0.0, 1.0)


func _track() -> Vector2:
	return Vector2(10.0, size.y - 10.0)


func _y_of(v: float) -> float:
	var t := _track()
	return lerpf(t.y, t.x, _frac(v))


func _draw() -> void:
	if binding == null:
		return
	var driven := binding.has_curve()
	var v := binding.live_value()
	var cx := size.x * 0.5
	var t := _track()
	draw_line(Vector2(cx, t.x), Vector2(cx, t.y), Color(0.23, 0.25, 0.31), 4.0, true)
	var zero_y := _y_of(0.0)
	draw_line(Vector2(cx - 8, zero_y), Vector2(cx + 8, zero_y), Color(AWTheme.text(self), 0.35), 1.0)
	var y := _y_of(v)
	draw_line(Vector2(cx, zero_y), Vector2(cx, y), DRIVEN if driven else accent, 4.0, true)
	var thumb := Rect2(cx - 9, y - 6, 18, 12)
	var base := Color.WHITE if selected else AWTheme.text(self)
	draw_rect(thumb, base, true)
	if driven:
		draw_dashed_line(thumb.position, thumb.position + Vector2(thumb.size.x, 0), DRIVEN, 1.5, 3.0)
		draw_dashed_line(thumb.position + Vector2(0, thumb.size.y), thumb.end, DRIVEN, 1.5, 3.0)
		draw_dashed_line(thumb.position, thumb.position + Vector2(0, thumb.size.y), DRIVEN, 1.5, 3.0)
		draw_dashed_line(thumb.position + Vector2(thumb.size.x, 0), thumb.end, DRIVEN, 1.5, 3.0)


func _gui_input(event: InputEvent) -> void:
	if binding == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				touched.emit()
				if binding.has_curve():
					binding.select_curve()
				elif mb.double_click:
					binding.reset()
				else:
					binding.begin()
					_pressed = true
					var t := _track()
					if absf(mb.position.y - _y_of(binding.value())) > 8.0:
						binding.preview(snappedf(lerpf(vmin, vmax, clampf((t.y - mb.position.y) / (t.y - t.x), 0.0, 1.0)), binding.step))
					_start_v = binding.value()
					_press_y = mb.position.y
			elif _pressed:
				_pressed = false
				binding.commit()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			touched.emit()
			binding.open_menu(self, mb.position)
			accept_event()
		elif (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN) and mb.pressed and not binding.has_curve():
			var d := (vmax - vmin) * (0.005 if mb.shift_pressed else 0.02)
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				d = -d
			binding.set_value(snappedf(binding.value() + d, binding.step))
			accept_event()
	elif event is InputEventMouseMotion and _pressed:
		var mm := event as InputEventMouseMotion
		var t := _track()
		var k := 0.1 if mm.shift_pressed else 1.0
		var dv := (_press_y - mm.position.y) / (t.y - t.x) * (vmax - vmin) * k
		binding.preview(snappedf(_start_v + dv, binding.step))
		queue_redraw()
