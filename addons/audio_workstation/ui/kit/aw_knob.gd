@tool
class_name AWKnob
extends Control
## Rotary control bound to one effect parameter. Drag up/down (Shift = fine), wheel,
## double-click to reset, right-click for curve options. When the parameter is driven
## by a curve it shows the live value, ringed in the automation colour, and a click
## selects the curve instead of editing.

const SWEEP := 270.0
const START := 135.0
const DRAG_PX := 220.0
const DRIVEN := Color("#e6c84a")

var binding: AWParamBinding
var accent := Color("#4f9edb")
var diameter := 64.0
var show_label := true
## Optional display range (linear) narrower than the parameter's own, e.g. an EQ band
## allows -60..+24 dB but its knob shows -18..+18.
var view_min := NAN
var view_max := NAN
## Draw the value arc from the middle (0 dB) instead of from the start.
var bipolar := false
var _start_norm := 0.0
var _press_y := 0.0
var _pressed := false

signal touched


func setup(p_binding: AWParamBinding, p_accent: Color, p_diameter := 64.0) -> void:
	binding = p_binding
	accent = p_accent
	diameter = p_diameter
	update_minimum_size()
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_VSIZE
	tooltip_text = "%s\nDrag: change   Shift: fine   Wheel: step   Double-click: reset\nRight-click: curve options" % binding.label


func _n(v: float) -> float:
	if is_nan(view_min):
		return binding.to_norm(v)
	return clampf((v - view_min) / (view_max - view_min), 0.0, 1.0)


func _v(n: float) -> float:
	if is_nan(view_min):
		return binding.from_norm(n)
	return snappedf(lerpf(view_min, view_max, clampf(n, 0.0, 1.0)), binding.step)


func _get_minimum_size() -> Vector2:
	var fs := get_theme_default_font_size()
	return Vector2(maxf(diameter + 24.0, 76.0), diameter + 4.0 + 2.0 * fs + 8.0)


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	if binding == null:
		return
	var driven := binding.has_curve()
	var v := binding.live_value()
	var f := _n(v)
	var c := Vector2(size.x * 0.5, diameter * 0.5 + 4.0)
	var r := diameter * 0.5 - 5.0
	var w := maxf(3.0, diameter * 0.075)
	if driven:
		var steps := 36
		for i in steps:
			var a := TAU * float(i) / steps
			draw_arc(c, r + 7.0, a, a + TAU / steps * 0.45, 4, Color(DRIVEN, 0.8), 1.2, true)
	var a0 := deg_to_rad(START)
	draw_arc(c, r, a0, deg_to_rad(START + SWEEP), 48, Color(0.23, 0.25, 0.31), w, true)
	var from_f := 0.5 if bipolar else 0.0
	if absf(f - from_f) > 0.002:
		draw_arc(c, r, deg_to_rad(START + SWEEP * minf(f, from_f)), deg_to_rad(START + SWEEP * maxf(f, from_f)), 48, DRIVEN if driven else accent, w, true)
	var ang := deg_to_rad(START + SWEEP * f)
	var dir := Vector2(cos(ang), sin(ang))
	draw_line(c + dir * r * 0.4, c + dir * (r * 0.72), AWTheme.text(self), 2.0, true)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size()
	var ty := diameter + 4.0 + fs + 2.0
	var vt := binding.text(v)
	_centered(font, vt, Vector2(size.x * 0.5, ty), fs + 1, DRIVEN if driven else AWTheme.text(self))
	if show_label:
		_centered(font, binding.label, Vector2(size.x * 0.5, ty + fs + 3.0), fs - 1, Color(AWTheme.text(self), 0.6))


func _centered(font: Font, t: String, base: Vector2, fs: int, col: Color) -> void:
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(base.x - w * 0.5, base.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


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
					_start_norm = _n(binding.value())
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
			var d := 0.01 if mb.shift_pressed else 0.04
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				d = -d
			binding.set_value(_v(_n(binding.value()) + d))
			accept_event()
	elif event is InputEventMouseMotion and _pressed:
		var mm := event as InputEventMouseMotion
		var k := 0.1 if mm.shift_pressed else 1.0
		binding.preview(_v(_start_norm + (_press_y - mm.position.y) / DRAG_PX * k))
		queue_redraw()
