@tool
class_name AWTimeRuler
extends Control
## Seconds ruler for one AWTimeView. Click or drag to move the playhead.
## With show_loop, a strip along the top edits the loop region (drag to create/move/resize).

const LOOP_H := 10.0
const HANDLE := 6.0

var doc: AWDocument
var view: AWTimeView
var show_loop := false
## view time -> project time, and back (the curve graph's clip-time mode offsets them).
var to_project: Callable = func(t: float) -> float: return t
var from_project: Callable = func(t: float) -> float: return t
## Optional Callable() -> Vector2(start, end) in view time, shaded as the editable range.
var domain: Callable

var _mode := ""
var _anchor := 0.0
var _orig := {}


func setup(p_doc: AWDocument, p_view: AWTimeView, p_show_loop := false) -> void:
	doc = p_doc
	view = p_view
	show_loop = p_show_loop


func _ready() -> void:
	custom_minimum_size = Vector2(0, 30 if show_loop else 22)
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	view.changed.connect(queue_redraw)
	doc.playhead_changed.connect(queue_redraw)
	doc.transport_changed.connect(queue_redraw)
	doc.project_changed.connect(func(_s: bool) -> void: queue_redraw())
	doc.export_settings_changed.connect(queue_redraw)


func _top() -> float:
	return LOOP_H if show_loop else 0.0


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if view.handle_wheel(mb, mb.position.x):
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press(mb.position)
			else:
				_release()
			accept_event()
	elif event is InputEventMouseMotion and _mode != "":
		_motion((event as InputEventMouseMotion).position)
		accept_event()


func _press(pos: Vector2) -> void:
	var p := doc.project
	var ex := view.time_to_x(from_project.call(doc.export_end_sec()))
	if pos.y >= _top() and absf(pos.x - ex) <= HANDLE and doc.export_end_sec() > 0.0:
		# The export end marker: drag to place it (this switches it from automatic to manual).
		_orig = {"export_end_sec": p.export_end_sec}
		_mode = "export_end"
	elif show_loop and pos.y < LOOP_H:
		var xs := view.time_to_x(p.loop_start_sec)
		var xe := view.time_to_x(p.loop_end_sec)
		_orig = {"loop_start_sec": p.loop_start_sec, "loop_end_sec": p.loop_end_sec, "loop_enabled": p.loop_enabled}
		if absf(pos.x - xs) <= HANDLE:
			_mode = "loop_start"
		elif absf(pos.x - xe) <= HANDLE:
			_mode = "loop_end"
		elif pos.x > xs and pos.x < xe:
			_mode = "loop_move"
			_anchor = view.x_to_time(pos.x) - p.loop_start_sec
		else:
			_mode = "loop_new"
			_anchor = maxf(0.0, doc.snap(view.x_to_time(pos.x)))
	else:
		_mode = "seek"
		_motion(pos)


func _motion(pos: Vector2) -> void:
	var p := doc.project
	var t := maxf(0.0, doc.snap(view.x_to_time(pos.x)))
	match _mode:
		"export_end":
			doc.preview_set(p, {"export_end_sec": clampf(to_project.call(t), 0.0, AWProject.MAX_END_SEC)})
		"seek":
			doc.seek(to_project.call(doc.snap(view.x_to_time(pos.x))))
		"loop_start":
			doc.preview_set(p, {"loop_start_sec": minf(t, p.loop_end_sec - AWDocument.MIN_LEN)})
		"loop_end":
			doc.preview_set(p, {"loop_end_sec": maxf(t, p.loop_start_sec + AWDocument.MIN_LEN)})
		"loop_move":
			var length: float = _orig["loop_end_sec"] - _orig["loop_start_sec"]
			var s := maxf(0.0, doc.snap(view.x_to_time(pos.x) - _anchor))
			doc.preview_set(p, {"loop_start_sec": s, "loop_end_sec": s + length})
		"loop_new":
			if absf(t - _anchor) >= AWDocument.MIN_LEN:
				doc.preview_set(p, {"loop_start_sec": minf(_anchor, t), "loop_end_sec": maxf(_anchor, t), "loop_enabled": true})


func _release() -> void:
	if _mode == "export_end":
		doc.commit_drags([[doc.project, _orig]], "Set Export End")
	elif _mode.begins_with("loop_"):
		doc.commit_drags([[doc.project, _orig]], "Edit Loop Region")
	_mode = ""


func _draw() -> void:
	var c_text := AWTheme.text(self)
	var c_acc := AWTheme.accent(self)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 3
	var top := _top()
	draw_rect(Rect2(Vector2.ZERO, size), AWTheme.color(self, &"dark_color_1", Color(0.16, 0.18, 0.22)))

	if domain.is_valid():
		var d: Vector2 = domain.call()
		var x0 := view.time_to_x(d.x)
		var x1 := view.time_to_x(d.y)
		draw_rect(Rect2(0, top, maxf(x0, 0.0), size.y - top), Color(0, 0, 0, 0.25))
		draw_rect(Rect2(x1, top, maxf(size.x - x1, 0.0), size.y - top), Color(0, 0, 0, 0.25))

	if show_loop:
		var p := doc.project
		draw_rect(Rect2(0, 0, size.x, LOOP_H), Color(0, 0, 0, 0.25))
		var xs := view.time_to_x(p.loop_start_sec)
		var xe := view.time_to_x(p.loop_end_sec)
		var lc := Color(c_acc, 0.6) if p.loop_enabled else Color(c_text, 0.22)
		draw_rect(Rect2(xs, 1, xe - xs, LOOP_H - 2), lc)
		draw_rect(Rect2(xs, 0, 2, LOOP_H), c_text if p.loop_enabled else Color(c_text, 0.5))
		draw_rect(Rect2(xe - 2, 0, 2, LOOP_H), c_text if p.loop_enabled else Color(c_text, 0.5))

	var major := view.label_step()
	var minor := AWTheme.minor_step(major)
	var t0 := view.x_to_time(0.0)
	var t1 := view.x_to_time(size.x)
	if minor * view.pixels_per_sec >= 6.0:
		var j := floori(t0 / minor)
		while j * minor <= t1:
			var mx := roundf(view.time_to_x(j * minor)) + 0.5
			draw_line(Vector2(mx, size.y - 4), Vector2(mx, size.y), Color(c_text, 0.3))
			j += 1
	var i := floori(t0 / major)
	while i * major <= t1:
		var x := roundf(view.time_to_x(i * major)) + 0.5
		draw_line(Vector2(x, top), Vector2(x, size.y), Color(c_text, 0.45))
		draw_string(font, Vector2(x + 3, top + fs + 2), AWTimeView.format_time(i * major, major),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(c_text, 0.8))
		i += 1

	var end_sec := doc.export_end_sec()
	if end_sec > 0.0:
		AWTheme.draw_export_end(self, view.time_to_x(from_project.call(end_sec)), top, size.y, true, doc.project.export_end_is_auto())

	var px: float = view.time_to_x(from_project.call(doc.playhead_sec))
	draw_line(Vector2(px, top), Vector2(px, size.y), c_acc, 2.0)
	draw_colored_polygon(PackedVector2Array([Vector2(px - 5, top), Vector2(px + 5, top), Vector2(px, top + 7)]), c_acc)
	draw_line(Vector2(0, size.y - 0.5), Vector2(size.x, size.y - 0.5), Color(0, 0, 0, 0.5))
