@tool
class_name AWTransferPlot
extends Control
## Input/output plot for distortion and dynamics: grid, optional 1:1 diagonal, the curve from
## `fn` (x -> y), and one optional draggable handle {x, y, driven}.
## Signals: handle_pressed, handle_moved(x, y), handle_released.

signal handle_pressed
signal handle_moved(x: float, y: float)
signal handle_released

const DRIVEN := Color("#e6c84a")
const PAD_L := 34.0
const PAD_B := 18.0
const PAD_T := 8.0
const PAD_R := 8.0

var accent := Color("#e8834a")
var x_min := -60.0
var x_max := 0.0
var y_min := -60.0
var y_max := 12.0
var grid_step := 12.0
var diagonal := true
var mini := false
var fn: Callable
## {x, y, driven}; empty = none.
var handle := {}
var bubble_text := ""
var _dragging := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func _area() -> Rect2:
	if mini:
		return Rect2(Vector2.ZERO, size)
	return Rect2(PAD_L, PAD_T, size.x - PAD_L - PAD_R, size.y - PAD_T - PAD_B)


func px(x: float) -> float:
	var a := _area()
	return a.position.x + (x - x_min) / (x_max - x_min) * a.size.x


func py(y: float) -> float:
	var a := _area()
	return a.position.y + (1.0 - (y - y_min) / (y_max - y_min)) * a.size.y


func x_at(pixel: float) -> float:
	var a := _area()
	return x_min + (pixel - a.position.x) / a.size.x * (x_max - x_min)


func y_at(pixel: float) -> float:
	var a := _area()
	return y_max - (pixel - a.position.y) / a.size.y * (y_max - y_min)


func _draw() -> void:
	var a := _area()
	draw_rect(a, Color(0.125, 0.145, 0.17), true)
	var txt := AWTheme.text(self)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 2
	var g := ceilf(x_min / grid_step) * grid_step
	while g <= x_max + 0.001:
		var x := px(g)
		draw_line(Vector2(x, a.position.y), Vector2(x, a.end.y), Color(txt, 0.28 if is_zero_approx(g) else 0.09), 1.0)
		if not mini:
			draw_string(font, Vector2(x - 8, size.y - 4), "%d" % int(g), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(txt, 0.6))
		g += grid_step
	g = ceilf(y_min / grid_step) * grid_step
	while g <= y_max + 0.001:
		var y := py(g)
		draw_line(Vector2(a.position.x, y), Vector2(a.end.x, y), Color(txt, 0.28 if is_zero_approx(g) else 0.09), 1.0)
		if not mini:
			draw_string(font, Vector2(2, y + fs * 0.4), "%d" % int(g), HORIZONTAL_ALIGNMENT_RIGHT, PAD_L - 6, fs, Color(txt, 0.6))
		g += grid_step
	if diagonal:
		draw_dashed_line(Vector2(px(maxf(x_min, y_min)), py(maxf(x_min, y_min))), Vector2(px(minf(x_max, y_max)), py(minf(x_max, y_max))), Color(txt, 0.3), 1.0, 4.0)
	if fn.is_valid():
		var pts := PackedVector2Array()
		var n := 160
		for i in n + 1:
			var xv := lerpf(x_min, x_max, float(i) / n)
			pts.append(Vector2(px(xv), clampf(py(fn.call(xv)), a.position.y, a.end.y)))
		draw_polyline(pts, accent, 1.5 if mini else 2.5, true)
	if mini or handle.is_empty():
		return
	var p := Vector2(px(handle.x), py(handle.y))
	if handle.get("driven", false):
		draw_arc(p, 10.0, 0, TAU, 20, DRIVEN, 1.2, true)
	if _dragging:
		draw_circle(p, 13.0, Color(accent, 0.22))
	draw_circle(p, 8.0 if _dragging else 6.0, accent)
	if _dragging:
		draw_arc(p, 8.0, 0, TAU, 20, Color.WHITE, 2.0, true)
	if _dragging and bubble_text != "":
		var w := font.get_string_size(bubble_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 1).x + 16
		var bp := Vector2(minf(p.x + 14, a.end.x - w), maxf(p.y - 30, a.position.y + 2))
		draw_rect(Rect2(bp, Vector2(w, 22)), Color(0.09, 0.105, 0.125), true)
		draw_rect(Rect2(bp, Vector2(w, 22)), accent, false, 1.0)
		draw_string(font, bp + Vector2(8, 15), bubble_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 1, txt)


func _gui_input(event: InputEvent) -> void:
	if mini or handle.is_empty():
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.position.distance_to(Vector2(px(handle.x), py(handle.y))) < 14.0:
				_dragging = true
				handle_pressed.emit()
				queue_redraw()
				accept_event()
		elif _dragging:
			_dragging = false
			handle_released.emit()
			queue_redraw()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		handle_moved.emit(x_at(mm.position.x), y_at(mm.position.y))
		accept_event()
