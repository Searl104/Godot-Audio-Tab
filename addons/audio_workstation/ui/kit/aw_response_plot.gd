@tool
class_name AWResponsePlot
extends Control
## Log-frequency / dB plot for filter-style effects: grid, response curve with fill,
## and optional draggable handles. The owner supplies the sampled response and the
## handle positions; the plot only draws and reports drags.
##
## A handle is {f, db, driven, selected}. Signals: handle_pressed(i), handle_moved(i, f, db, fine),
## handle_released(i).

signal handle_pressed(i: int)
signal handle_moved(i: int, f: float, db: float, fine: bool)
signal handle_released(i: int)

const DRIVEN := Color("#e6c84a")
const PAD_L := 38.0
const PAD_B := 20.0
const PAD_T := 8.0
const PAD_R := 8.0

var accent := Color("#4f9edb")
var db_min := -36.0
var db_max := 24.0
var db_step := 12.0
var response := PackedFloat32Array()
var handles: Array = []
var mini := false
## Handles only move vertically (EQ bands have fixed frequencies).
var vertical_only := false
## Optional shaded band on the frequency axis, as [f_lo, f_hi] (the range a cutoff curve sweeps).
var sweep := Vector2.ZERO
var bubble_text := ""
var _active := -1
## Where the last press landed (for relative drags).
var press_pos := Vector2.ZERO
var _fine_base := Vector2.ZERO


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func _area() -> Rect2:
	if mini:
		return Rect2(Vector2.ZERO, size)
	return Rect2(PAD_L, PAD_T, size.x - PAD_L - PAD_R, size.y - PAD_T - PAD_B)


func x_of(f: float) -> float:
	var a := _area()
	return a.position.x + AWFilterResponse.norm_of(f) * a.size.x


func y_of(db: float) -> float:
	var a := _area()
	return a.position.y + (1.0 - clampf((db - db_min) / (db_max - db_min), 0.0, 1.0)) * a.size.y


func f_at(x: float) -> float:
	var a := _area()
	return AWFilterResponse.freq_at((x - a.position.x) / a.size.x)


func db_at(y: float) -> float:
	var a := _area()
	return lerpf(db_max, db_min, clampf((y - a.position.y) / a.size.y, 0.0, 1.0))


func _draw() -> void:
	var a := _area()
	draw_rect(a, Color(0.125, 0.145, 0.17), true)
	var txt := AWTheme.text(self)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 2
	if not mini:
		var db := db_min
		while db <= db_max + 0.01:
			var y := y_of(db)
			draw_line(Vector2(a.position.x, y), Vector2(a.end.x, y), Color(txt, 0.28 if is_zero_approx(db) else 0.1), 1.0)
			var t := "%+d" % int(db) if not is_zero_approx(db) else "0"
			draw_string(font, Vector2(2, y + fs * 0.4), t, HORIZONTAL_ALIGNMENT_RIGHT, PAD_L - 6, fs, Color(txt, 0.6))
			db += db_step
		for decade in [20.0, 100.0, 1000.0, 10000.0]:
			for m in [1, 2, 3, 4, 5, 6, 7, 8, 9]:
				var f: float = decade * m
				if f < 20.0 or f > 20000.0:
					continue
				var x := x_of(f)
				draw_line(Vector2(x, a.position.y), Vector2(x, a.end.y), Color(txt, 0.16 if m == 1 else 0.06), 1.0)
		for pair: Array in [[20.0, "20"], [100.0, "100"], [1000.0, "1k"], [10000.0, "10k"]]:
			draw_string(font, Vector2(x_of(pair[0]) - 8, size.y - 5), pair[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(txt, 0.6))
	if sweep.y > sweep.x and not mini:
		var x0 := x_of(sweep.x)
		draw_rect(Rect2(x0, a.position.y, x_of(sweep.y) - x0, a.size.y), Color(DRIVEN, 0.07), true)
	var n := response.size()
	if n > 1:
		var line := PackedVector2Array()
		for i in n:
			line.append(Vector2(a.position.x + a.size.x * float(i) / (n - 1), y_of(response[i])))
		var fill := PackedVector2Array(line)
		fill.append(Vector2(a.end.x, y_of(db_min)))
		fill.append(Vector2(a.position.x, y_of(db_min)))
		var fc := Geometry2D.triangulate_polygon(fill)
		if not fc.is_empty():
			draw_colored_polygon(fill, Color(accent, 0.14))
		draw_polyline(line, accent, 1.5 if mini else 2.5, true)
	if mini:
		return
	for i in handles.size():
		var h: Dictionary = handles[i]
		var p := Vector2(x_of(h.f), y_of(h.db))
		var sel: bool = h.get("selected", false) or i == _active
		if h.get("driven", false):
			draw_arc(p, 10.0, 0, TAU, 20, DRIVEN, 1.2, true)
		if sel:
			draw_circle(p, 13.0, Color(accent, 0.22))
		draw_circle(p, 8.0 if sel else 6.0, accent)
		if sel:
			draw_arc(p, 8.0, 0, TAU, 20, Color.WHITE, 2.0, true)
	if _active >= 0 and bubble_text != "":
		var h2: Dictionary = handles[_active]
		var bp := Vector2(x_of(h2.f) + 14, y_of(h2.db) - 30)
		var w := font.get_string_size(bubble_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 1).x + 16
		bp.x = minf(bp.x, a.end.x - w)
		bp.y = maxf(bp.y, a.position.y + 2)
		draw_rect(Rect2(bp, Vector2(w, 22)), Color(0.09, 0.105, 0.125), true)
		draw_rect(Rect2(bp, Vector2(w, 22)), accent, false, 1.0)
		draw_string(font, bp + Vector2(8, 15), bubble_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 1, txt)


func _hit(pos: Vector2) -> int:
	var best := -1
	var best_d := 14.0
	for i in handles.size():
		var d := pos.distance_to(Vector2(x_of(handles[i].f), y_of(handles[i].db)))
		if d < best_d:
			best_d = d
			best = i
	return best


func _gui_input(event: InputEvent) -> void:
	if mini:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			var i := _hit(mb.position)
			if i >= 0:
				_active = i
				press_pos = mb.position
				handle_pressed.emit(i)
				queue_redraw()
				accept_event()
		elif _active >= 0:
			var done := _active
			_active = -1
			handle_released.emit(done)
			queue_redraw()
			accept_event()
	elif event is InputEventMouseMotion and _active >= 0:
		var mm := event as InputEventMouseMotion
		var f: float = handles[_active].f if vertical_only else f_at(mm.position.x)
		handle_moved.emit(_active, f, db_at(mm.position.y), mm.shift_pressed)
		accept_event()
