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

const MARKER_COLOR := Color("#e8c547")
const MARKER_HIT := 5.0

var _mode := ""
var _anchor := 0.0
var _orig := {}
var _press_pos := Vector2.ZERO
var _targets := PackedFloat64Array()
var _marker: AWMarker = null
var _menu: PopupMenu
var _menu_marker: AWMarker = null
var _menu_t := 0.0
var _rename: LineEdit
var _rename_marker: AWMarker = null


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
	doc.time_selection_changed.connect(queue_redraw)
	if _is_timeline():
		tooltip_text = " "
		_menu = PopupMenu.new()
		_menu.id_pressed.connect(_on_menu)
		add_child(_menu)
		_rename = LineEdit.new()
		_rename.visible = false
		_rename.text_submitted.connect(func(_t: String) -> void: _finish_rename(true))
		_rename.focus_exited.connect(func() -> void: _finish_rename(true))
		_rename.gui_input.connect(func(e: InputEvent) -> void:
			var k := e as InputEventKey
			if k and k.pressed and k.keycode == KEY_ESCAPE:
				_finish_rename(false)
				_rename.accept_event())
		add_child(_rename)


func _top() -> float:
	return LOOP_H if show_loop else 0.0


## The timeline ruler (with the loop strip) also scrubs, selects time and holds markers.
func _is_timeline() -> bool:
	return show_loop


func marker_at(pos: Vector2) -> AWMarker:
	if not _is_timeline() or pos.y < _top():
		return null
	for i in range(doc.project.markers.size() - 1, -1, -1):
		var m := doc.project.markers[i]
		if absf(view.time_to_x(m.time_sec) - pos.x) <= MARKER_HIT:
			return m
	return null


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if view.handle_wheel(mb, mb.position.x):
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click and marker_at(mb.position):
					start_marker_rename(marker_at(mb.position))
				else:
					_press(mb.position, mb.shift_pressed)
			else:
				_release()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and _is_timeline():
			_open_menu(mb.position)
			accept_event()
	elif event is InputEventMouseMotion and _mode != "":
		_motion((event as InputEventMouseMotion).position)
		accept_event()


func _press(pos: Vector2, shift := false) -> void:
	var p := doc.project
	_press_pos = pos
	var ex := view.time_to_x(from_project.call(doc.export_end_sec()))
	var mk := marker_at(pos)
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
		else:
			# Dragging anywhere else on the strip sets new loop bounds.
			_mode = "loop_new"
			_anchor = maxf(0.0, doc.snap_to(view.x_to_time(pos.x), doc.snap_targets()))
	elif mk != null:
		_marker = mk
		_orig = {"time_sec": mk.time_sec}
		_targets = doc.snap_targets()
		var i := _targets.find(mk.time_sec)
		if i >= 0:
			_targets.remove_at(i)
		_mode = "marker"
	elif shift and _is_timeline():
		_mode = "select"
		_targets = doc.snap_targets()
		_anchor = maxf(0.0, doc.snap_to(view.x_to_time(pos.x), _targets))
		doc.set_time_selection(_anchor, _anchor)
	else:
		# Click: move the playhead. On the timeline, dragging turns into a scrub.
		_mode = "seek"
		_targets = doc.snap_targets() if _is_timeline() else PackedFloat64Array()
		doc.seek(to_project.call(maxf(0.0, doc.snap_to(view.x_to_time(pos.x), _targets) if _is_timeline() else doc.snap(view.x_to_time(pos.x)))))


func _motion(pos: Vector2) -> void:
	var p := doc.project
	var t := maxf(0.0, doc.snap(view.x_to_time(pos.x)))
	match _mode:
		"export_end":
			doc.preview_set(p, {"export_end_sec": clampf(to_project.call(t), 0.0, AWProject.MAX_END_SEC)})
		"seek":
			if _is_timeline() and absf(pos.x - _press_pos.x) > 3.0:
				_mode = "scrub"
				doc.scrub_begin(maxf(0.0, view.x_to_time(pos.x)))
			elif not _is_timeline():
				doc.seek(to_project.call(doc.snap(view.x_to_time(pos.x))))
		"scrub":
			doc.scrub_to(maxf(0.0, view.x_to_time(pos.x)))
		"select":
			doc.set_time_selection(_anchor, maxf(0.0, doc.snap_to(view.x_to_time(pos.x), _targets)))
		"marker":
			_marker.time_sec = maxf(0.0, doc.snap_to(view.x_to_time(pos.x), _targets))
			doc.project_changed.emit(false)
		"loop_start":
			doc.preview_set(p, {"loop_start_sec": minf(t, p.loop_end_sec - AWDocument.MIN_LEN)})
		"loop_end":
			doc.preview_set(p, {"loop_end_sec": maxf(t, p.loop_start_sec + AWDocument.MIN_LEN)})
		"loop_new":
			var lt := maxf(0.0, doc.snap_to(view.x_to_time(pos.x), doc.snap_targets()))
			if absf(lt - _anchor) >= AWDocument.MIN_LEN:
				doc.preview_set(p, {"loop_start_sec": minf(_anchor, lt), "loop_end_sec": maxf(_anchor, lt), "loop_enabled": true})


func _release() -> void:
	match _mode:
		"export_end":
			doc.commit_drags([[doc.project, _orig]], "Set Export End")
		"scrub":
			doc.scrub_end()
		"select":
			if not doc.has_time_selection():
				doc.clear_time_selection()
		"marker":
			doc.sort_markers()
			doc.commit_drags([[_marker, _orig]], "Move Marker")
			_marker = null
		_:
			if _mode.begins_with("loop_"):
				doc.commit_drags([[doc.project, _orig]], "Edit Loop Region")
	_mode = ""


# --- Menu and marker rename -------------------------------------------------------------

func _open_menu(pos: Vector2) -> void:
	_menu_marker = marker_at(pos)
	_menu_t = maxf(0.0, doc.snap_to(view.x_to_time(pos.x), doc.snap_targets()))
	_menu.clear()
	if _menu_marker:
		_menu.add_item("Rename Marker", 1)
		_menu.add_item("Delete Marker", 2)
		_menu.add_separator()
	_menu.add_item("Add Marker Here", 3)
	if doc.has_time_selection():
		_menu.add_separator()
		_menu.add_item("Loop Selection", 4)
		_menu.add_item("Split Clips at Selection", 5)
		_menu.add_item("Delete Inside Selection", 6)
		_menu.add_item("Zoom to Selection", 8)
		_menu.add_item("Clear Time Selection", 7)
	AWTheme.popup_at(_menu, self, pos)


func _on_menu(id: int) -> void:
	match id:
		1: start_marker_rename(_menu_marker)
		2: doc.remove_marker(_menu_marker)
		3: doc.add_marker(_menu_t)
		4: doc.loop_time_selection()
		5: doc.split_at_time_selection()
		6: doc.delete_in_time_selection()
		7: doc.clear_time_selection()
		8: view.frame(doc.time_sel.x, doc.time_sel.y)


func start_marker_rename(m: AWMarker) -> void:
	if m == null:
		return
	_rename_marker = m
	_rename.text = m.name
	_rename.position = Vector2(clampf(view.time_to_x(m.time_sec) + 4.0, 0.0, maxf(size.x - 140.0, 0.0)), 0)
	_rename.size = Vector2(140, size.y)
	_rename.visible = true
	_rename.grab_focus()
	_rename.select_all()


func _finish_rename(apply: bool) -> void:
	if _rename_marker == null:
		return
	var m := _rename_marker
	_rename_marker = null
	_rename.visible = false
	var t := _rename.text.strip_edges()
	if apply and t != "" and t != m.name:
		doc.set_props(m, {"name": t}, "Rename Marker")


func _get_tooltip(at: Vector2) -> String:
	var m := marker_at(at)
	if m:
		return "%s at %s. Drag to move, double-click to rename, right-click to delete." % [m.name, doc.format_clock(m.time_sec)]
	if _is_timeline():
		if at.y < _top():
			return "Loop: drag to set its start and end; drag its edges to adjust."
		return "Click: move the playhead. Drag: scrub. Shift+drag: select time. Right-click: markers and selection."
	return ""


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

	if _is_timeline():
		if doc.has_time_selection():
			var sx0 := view.time_to_x(doc.time_sel.x)
			var sx1 := view.time_to_x(doc.time_sel.y)
			draw_rect(Rect2(sx0, top, sx1 - sx0, size.y - top), Color(c_acc, 0.22))
		for m in doc.project.markers:
			var mx := view.time_to_x(m.time_sec)
			if mx < -60.0 or mx > size.x + 2.0:
				continue
			draw_line(Vector2(mx, top), Vector2(mx, size.y), MARKER_COLOR, 1.0)
			var flag := PackedVector2Array([Vector2(mx, top), Vector2(mx + 7, top + 4), Vector2(mx, top + 8)])
			draw_colored_polygon(flag, MARKER_COLOR)
			draw_string(font, Vector2(mx + 9, size.y - 3), m.name, HORIZONTAL_ALIGNMENT_LEFT, 90, fs, MARKER_COLOR)

	var end_sec := doc.export_end_sec()
	if end_sec > 0.0:
		AWTheme.draw_export_end(self, view.time_to_x(from_project.call(end_sec)), top, size.y, true, doc.project.export_end_is_auto())

	var px: float = view.time_to_x(from_project.call(doc.playhead_sec))
	draw_line(Vector2(px, top), Vector2(px, size.y), c_acc, 2.0)
	draw_colored_polygon(PackedVector2Array([Vector2(px - 5, top), Vector2(px + 5, top), Vector2(px, top + 7)]), c_acc)
	draw_line(Vector2(0, size.y - 0.5), Vector2(size.x, size.y - 0.5), Color(0, 0, 0, 0.5))
