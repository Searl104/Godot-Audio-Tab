@tool
class_name AWClipGrid
extends Control
## The layering grid: clips can sit at any time on any row.
##
## Mouse: drag a clip to move it (time and row, all selected clips together), drag its
## edges to trim, drag the small squares at its top corners to set fades.
## Drag on empty space to box-select; click empty space to deselect and move the playhead.
## Shift adds to the selection, Ctrl toggles. Double-click a clip to audition it.
## Ctrl+wheel zooms, Shift+wheel scrolls time, Alt+wheel changes the row height, plain wheel scrolls rows.
## Drop audio files from the FileSystem dock; several files land on consecutive rows.

const ROW_H_DEFAULT := 48.0
const ROW_H_MIN := 28.0
const ROW_H_MAX := 160.0
const EDGE := 6.0
const FADE_HANDLE := 7.0
const MIN_ROWS := 6
const PEAKS_PER_SEC := 120.0

## Height of one grid row. Alt+wheel changes it (taller rows show the waveform better).
var row_h := ROW_H_DEFAULT

enum Drag { NONE, MOVE, TRIM_L, TRIM_R, FADE_IN, FADE_OUT, MARQUEE, CLICK }

var doc: AWDocument
var view: AWTimeView

var _drag := Drag.NONE
var _press_pos := Vector2.ZERO
var _press_t := 0.0
var _press_clip: AWClip = null
var _items: Array = []
var _orig_curve_keys: Array = []
## The clip's time warp as it was when the drag started (edits during a left trim change it).
var _press_warp: AWClipWarp = null
var _marquee_base: Array[AWClip] = []
var _marquee_rect := Rect2()
var _menu: PopupMenu
var _menu_clip: AWClip = null
var _menu_t := 0.0
var _drop_ghost := Rect2()


func setup(p_doc: AWDocument) -> void:
	doc = p_doc
	view = doc.timeline_view


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	resized.connect(func() -> void: view.set_view_width(size.x))
	view.changed.connect(queue_redraw)
	doc.project_changed.connect(func(_s: bool) -> void: _update_height(); queue_redraw())
	doc.selection_changed.connect(queue_redraw)
	doc.chain_target_changed.connect(queue_redraw)
	doc.playhead_changed.connect(queue_redraw)
	doc.transport_changed.connect(queue_redraw)
	_update_height()


func set_row_height(h: float) -> void:
	row_h = clampf(h, ROW_H_MIN, ROW_H_MAX)
	_update_height()
	queue_redraw()


func _update_height() -> void:
	custom_minimum_size.y = maxi(doc.project.max_row() + 2, MIN_ROWS) * row_h


## Rows drawn: enough to fill the visible area, plus one spare below the lowest clip.
func row_count() -> int:
	return maxi(ceili(size.y / row_h), doc.project.max_row() + 2)


# --- Geometry -----------------------------------------------------------------

## On the timeline a clip spans its played duration, which grows when it's pitched down.
func clip_rect(c: AWClip) -> Rect2:
	return Rect2(view.time_to_x(c.start_sec), c.row * row_h + 3.0, c.play_length() * view.pixels_per_sec, row_h - 6.0)


## Fade positions in pixels from the clip's left / right edge (fades are in clip time).
func _fade_px(c: AWClip) -> Vector2:
	var w := c.warp()
	var fi := w.warp(minf(c.fade_in_sec, c.length_sec)) * view.pixels_per_sec
	var fo := (w.warp(c.length_sec) - w.warp(maxf(c.length_sec - c.fade_out_sec, 0.0))) * view.pixels_per_sec
	return Vector2(fi, fo)


func row_at(y: float) -> int:
	return maxi(0, floori(y / row_h))


func clip_at(pos: Vector2) -> AWClip:
	for i in range(doc.project.clips.size() - 1, -1, -1):
		var c := doc.project.clips[i]
		if clip_rect(c).grow_individual(0, 0, 0, 0).has_point(pos):
			return c
	return null


## Which part of a clip is under `pos`: "fade_in", "fade_out", "trim_l", "trim_r" or "body".
func clip_zone(c: AWClip, pos: Vector2) -> String:
	var r := clip_rect(c)
	var f := _fade_px(c)
	var fi_x := r.position.x + f.x
	var fo_x := r.end.x - f.y
	if pos.y <= r.position.y + FADE_HANDLE + 2.0:
		if absf(pos.x - fi_x) <= FADE_HANDLE:
			return "fade_in"
		if absf(pos.x - fo_x) <= FADE_HANDLE:
			return "fade_out"
	var edge := minf(EDGE, r.size.x * 0.25)
	if pos.x - r.position.x <= edge:
		return "trim_l"
	if r.end.x - pos.x <= edge:
		return "trim_r"
	return "body"


# --- Input --------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.alt_pressed and mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			set_row_height(row_h * (1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12))
			accept_event()
			return
		if view.handle_wheel(mb, mb.position.x):
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					var c := clip_at(mb.position)
					if c:
						doc.engine.audition_clip(c)
						doc.message.emit("Audition \"%s\"" % c.name)
				else:
					_press(mb)
			else:
				_release(mb)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_open_menu(mb.position)
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag == Drag.NONE:
			_update_cursor(mm.position)
		else:
			_motion(mm)
			accept_event()


func _press(mb: InputEventMouseButton) -> void:
	_press_pos = mb.position
	_press_t = view.x_to_time(mb.position.x)
	var c := clip_at(mb.position)
	_press_clip = c
	_items.clear()
	if c == null:
		_drag = Drag.CLICK
		_marquee_base = doc.selection.duplicate() if (mb.shift_pressed or mb.ctrl_pressed) else ([] as Array[AWClip])
		return
	if mb.ctrl_pressed:
		doc.select_clip(c, "toggle")
	elif mb.shift_pressed:
		doc.select_clip(c, "add")
	elif not doc.is_selected(c):
		doc.select_clip(c)
	else:
		doc._focus(c) # keep a multi-selection so it can be dragged together
	if not doc.is_selected(c):
		_drag = Drag.NONE
		return
	match clip_zone(c, mb.position):
		"fade_in": _drag = Drag.FADE_IN
		"fade_out": _drag = Drag.FADE_OUT
		"trim_l": _drag = Drag.TRIM_L
		"trim_r": _drag = Drag.TRIM_R
		_: _drag = Drag.MOVE
	if _drag == Drag.MOVE:
		for s in doc.selection:
			_items.append([s, {"start_sec": s.start_sec, "row": s.row}])
	else:
		_items.append([c, {"start_sec": c.start_sec, "length_sec": c.length_sec,
			"source_offset_sec": c.source_offset_sec, "fade_in_sec": c.fade_in_sec, "fade_out_sec": c.fade_out_sec}])
		_orig_curve_keys = doc.clip_curve_keys(c) if _drag == Drag.TRIM_L else []
		if _drag == Drag.TRIM_R:
			for cv in c.chain.curves:
				if cv.lfo and absf(cv.lfo.end_sec - c.length_sec) < 0.001:
					_items.append([cv.lfo, {"end_sec": cv.lfo.end_sec}])
		_press_warp = c.warp()


func _motion(mm: InputEventMouseMotion) -> void:
	var pos := mm.position
	match _drag:
		Drag.CLICK:
			if pos.distance_to(_press_pos) > 4.0:
				_drag = Drag.MARQUEE
				_motion(mm)
		Drag.MARQUEE:
			_marquee_rect = Rect2(_press_pos, pos - _press_pos).abs()
			var picked: Array[AWClip] = _marquee_base.duplicate()
			for c in doc.project.clips:
				if _marquee_rect.intersects(clip_rect(c)) and not picked.has(c):
					picked.append(c)
			doc.set_selection(picked)
			queue_redraw()
		Drag.MOVE:
			_move_selection(pos, mm.alt_pressed)
		Drag.TRIM_L, Drag.TRIM_R, Drag.FADE_IN, Drag.FADE_OUT:
			_edit_edge(pos)


func _move_selection(pos: Vector2, free_time: bool) -> void:
	var anchor: Dictionary = _items[0][1]
	for it: Array in _items:
		if it[0] == _press_clip:
			anchor = it[1]
	var raw: float = anchor.start_sec + (view.x_to_time(pos.x) - _press_t)
	var dt: float = (raw if free_time else doc.snap(raw)) - anchor.start_sec
	var drow := row_at(pos.y) - row_at(_press_pos.y)
	var min_start := INF
	var min_row := 1 << 30
	for it: Array in _items:
		min_start = minf(min_start, it[1].start_sec)
		min_row = mini(min_row, it[1].row)
	dt = maxf(dt, -min_start)
	drow = maxi(drow, -min_row)
	for it: Array in _items:
		doc.preview_set(it[0], {"start_sec": it[1].start_sec + dt, "row": it[1].row + drow})


## Edge drags: the mouse is in project time; the warp captured at press converts it to clip
## (audio) time, so trims and fades land on the sound you see under the cursor.
func _edit_edge(pos: Vector2) -> void:
	var c: AWClip = _items[0][0]
	var o: Dictionary = _items[0][1]
	var w := _press_warp
	var start: float = o.start_sec
	var length: float = o.length_sec
	var t := doc.snap(view.x_to_time(pos.x))
	match _drag:
		Drag.TRIM_L:
			# Can't reveal audio before the file's start, or cross the right edge.
			var min_start := maxf(0.0, start + w.warp(-o.source_offset_sec))
			var max_start := start + w.warp(length - AWDocument.MIN_LEN)
			var s := clampf(t, min_start, max_start)
			var cut := w.unwarp(s - start) # audio time removed (negative = revealed)
			doc.preview_shift_curves(c, _orig_curve_keys, cut)
			doc.preview_set(c, {"start_sec": s, "length_sec": length - cut,
				"source_offset_sec": o.source_offset_sec + cut,
				"fade_in_sec": minf(o.fade_in_sec, length - cut)})
		Drag.TRIM_R:
			var new_len := maxf(AWDocument.MIN_LEN, w.unwarp(t - start))
			for i in range(1, _items.size()):
				doc.preview_set(_items[i][0], {"end_sec": new_len})
			doc.preview_set(c, {"length_sec": new_len, "fade_out_sec": minf(o.fade_out_sec, new_len)})
		Drag.FADE_IN:
			doc.preview_set(c, {"fade_in_sec": clampf(w.unwarp(t - start), 0.0, c.length_sec - c.fade_out_sec)})
		Drag.FADE_OUT:
			doc.preview_set(c, {"fade_out_sec": clampf(length - w.unwarp(t - start), 0.0, c.length_sec - c.fade_in_sec)})


func _release(mb: InputEventMouseButton) -> void:
	match _drag:
		Drag.CLICK:
			if not (mb.shift_pressed or mb.ctrl_pressed):
				doc.clear_selection()
			doc.seek(maxf(0.0, doc.snap(view.x_to_time(mb.position.x))))
		Drag.MARQUEE:
			_marquee_rect = Rect2()
		Drag.MOVE:
			doc.commit_drags(_items, "Move Clips" if _items.size() > 1 else "Move Clip")
		Drag.TRIM_L:
			doc.commit_clip_trim(_items[0][0], _items[0][1], _orig_curve_keys, "Trim Clip")
		Drag.TRIM_R:
			doc.commit_drags(_items, "Trim Clip")
		Drag.FADE_IN, Drag.FADE_OUT:
			doc.commit_drags(_items, "Edit Fade")
	_drag = Drag.NONE
	_items.clear()
	queue_redraw()


func _update_cursor(pos: Vector2) -> void:
	var shape := Control.CURSOR_ARROW
	var c := clip_at(pos)
	if c:
		match clip_zone(c, pos):
			"trim_l", "trim_r": shape = Control.CURSOR_HSIZE
			"fade_in", "fade_out": shape = Control.CURSOR_POINTING_HAND
			_: shape = Control.CURSOR_MOVE
	mouse_default_cursor_shape = shape


# --- Context menu -------------------------------------------------------------

func _open_menu(pos: Vector2) -> void:
	_menu.clear()
	_menu_clip = clip_at(pos)
	_menu_t = maxf(0.0, doc.snap(view.x_to_time(pos.x)))
	if _menu_clip:
		if not doc.is_selected(_menu_clip):
			doc.select_clip(_menu_clip)
		_menu.add_item("Show Effect Chain", 1)
		_menu.add_separator()
		_menu.add_item("Split at Playhead", 2)
		_menu.add_item("Split Here", 3)
		_menu.add_item("Duplicate", 4)
		_menu.add_item("Unmute" if _menu_clip.muted else "Mute", 5)
		_menu.add_separator()
		_menu.add_item("Delete", 6)
	else:
		_menu.add_item("Select All", 10)
		_menu.add_item("Clear Selection", 11)
		_menu.add_separator()
		_menu.add_item("Move Playhead Here", 12)
	AWTheme.popup_at(_menu, self, pos)


func _on_menu(id: int) -> void:
	match id:
		1: doc._focus(_menu_clip)
		2: doc.split_clip(_menu_clip, doc.playhead_sec)
		3: doc.split_clip(_menu_clip, _menu_t)
		4: doc.duplicate_selected()
		5: doc.set_props(_menu_clip, {"muted": not _menu_clip.muted}, "Mute Clip")
		6: doc.delete_selected_clips()
		10: doc.select_all_clips()
		11: doc.clear_selection()
		12: doc.seek(_menu_t)


# --- Drag and drop from the FileSystem dock ----------------------------------

func _audio_files(data: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if data is Dictionary and data.get("type", "") == "files":
		for f: String in data.get("files", []):
			if doc.is_audio_file(f):
				out.append(f)
	return out


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	var files := _audio_files(data)
	if files.is_empty():
		return false
	var t := maxf(0.0, doc.snap(view.x_to_time(at_position.x)))
	_drop_ghost = Rect2(view.time_to_x(t), row_at(at_position.y) * row_h + 3.0, 1.0 * view.pixels_per_sec, files.size() * row_h - 6.0)
	queue_redraw()
	return true


func _drop_data(at_position: Vector2, data: Variant) -> void:
	_drop_ghost = Rect2()
	var t := maxf(0.0, doc.snap(view.x_to_time(at_position.x)))
	var row := row_at(at_position.y)
	var added: Array[AWClip] = []
	for f in _audio_files(data):
		added.append(doc.add_clip_from_path(f, row, t))
		row += 1
	doc.set_selection(added)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END or what == NOTIFICATION_MOUSE_EXIT:
		if _drop_ghost.size != Vector2.ZERO:
			_drop_ghost = Rect2()
			queue_redraw()


# --- Drawing ------------------------------------------------------------------

func _draw() -> void:
	var c_text := AWTheme.text(self)
	var c_acc := AWTheme.accent(self)
	var rows := row_count()
	draw_rect(Rect2(Vector2.ZERO, size), AWTheme.bg(self))
	for r in rows:
		if r % 2 == 1:
			draw_rect(Rect2(0, r * row_h, size.x, row_h), Color(1, 1, 1, 0.015))
		draw_line(Vector2(0, (r + 1) * row_h - 0.5), Vector2(size.x, (r + 1) * row_h - 0.5), Color(0, 0, 0, 0.25))
	AWTheme.draw_time_grid(self, view, 0.0, size.y)

	var p := doc.project
	if p.loop_enabled:
		var xs := view.time_to_x(p.loop_start_sec)
		draw_rect(Rect2(xs, 0, view.time_to_x(p.loop_end_sec) - xs, size.y), Color(c_acc, 0.06))

	for c in p.clips:
		_draw_clip(c, c_text, c_acc)

	if _drop_ghost.size != Vector2.ZERO:
		draw_rect(_drop_ghost, Color(c_acc, 0.2))
		draw_rect(_drop_ghost, c_acc, false, 1.0)
	if _drag == Drag.MARQUEE:
		draw_rect(_marquee_rect, Color(c_acc, 0.12))
		draw_rect(_marquee_rect, Color(c_acc, 0.8), false, 1.0)

	var px := view.time_to_x(doc.playhead_sec)
	draw_line(Vector2(px, 0), Vector2(px, size.y), c_acc, 2.0)


func _draw_clip(c: AWClip, c_text: Color, c_acc: Color) -> void:
	var r := clip_rect(c)
	if r.end.x < -2.0 or r.position.x > size.x + 2.0:
		return
	var base := c.color
	if c.muted:
		base = base.lerp(Color(0.45, 0.45, 0.45), 0.75)
	var body := base.darkened(0.45)
	draw_rect(r, body)
	draw_rect(Rect2(r.position, Vector2(r.size.x, 13.0)), base.darkened(0.15))

	# Placeholder waveform, indexed by source time so trimming reveals/hides the same audio.
	# Columns are mapped through the clip's warp, so pitched-down audio is drawn stretched.
	var w := c.warp()
	var key := c.source_path if c.source_path != "" else c.name
	var real := doc.engine.get_peaks(c.source_path, PEAKS_PER_SEC) if c.source_path != "" else PackedFloat32Array()
	var has_real := not real.is_empty()
	var peaks := real if has_real else doc.engine.get_waveform_peaks(key, 512)
	var wave_top := r.position.y + 14.0
	var wave_h := r.size.y - 15.0
	var mid := wave_top + wave_h * 0.5
	var amp := wave_h * 0.5 * clampf(db_to_linear(c.chain.effects[0].get_param("gain_db")) if c.chain else 1.0, 0.05, 1.3)
	var wave := Color(base.lightened(0.35), 0.9 if not c.muted else 0.4)
	var x := maxf(r.position.x, 0.0)
	var x_end := minf(r.end.x, size.x)
	while x < x_end:
		var local := w.unwarp((x - r.position.x) / view.pixels_per_sec)
		var src := local + c.source_offset_sec
		var peak := peaks[clampi(int(src * PEAKS_PER_SEC), 0, peaks.size() - 1)] if src * PEAKS_PER_SEC < peaks.size() else (0.0 if has_real else 0.05)
		var g := 1.0
		if c.fade_in_sec > 0.0 and local < c.fade_in_sec:
			g = local / c.fade_in_sec
		if c.fade_out_sec > 0.0 and local > c.length_sec - c.fade_out_sec:
			g = minf(g, (c.length_sec - local) / c.fade_out_sec)
		var h := peak * amp * g
		draw_line(Vector2(x, mid - h), Vector2(x, mid + h), wave)
		x += 2.0

	# Fades
	var fpx := _fade_px(c)
	var fi := fpx.x
	var fo := fpx.y
	if fi > 1.0:
		draw_colored_polygon(PackedVector2Array([Vector2(r.position.x, wave_top), Vector2(r.position.x + fi, wave_top), Vector2(r.position.x, r.end.y)]), Color(0, 0, 0, 0.35))
		draw_line(Vector2(r.position.x, r.end.y), Vector2(r.position.x + fi, wave_top), Color(c_text, 0.6))
	if fo > 1.0:
		draw_colored_polygon(PackedVector2Array([Vector2(r.end.x - fo, wave_top), Vector2(r.end.x, wave_top), r.end]), Color(0, 0, 0, 0.35))
		draw_line(Vector2(r.end.x - fo, wave_top), r.end, Color(c_text, 0.6))

	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 3
	var label := c.name + ("  (muted)" if c.muted else "")
	draw_string(font, r.position + Vector2(5, 10), label, HORIZONTAL_ALIGNMENT_LEFT, maxf(r.size.x - 10.0, 0.0), fs, c_text)
	var fx_count := c.chain.effects.size() - 1 if c.chain else 0
	if fx_count > 0 and r.size.x > 90.0:
		var badge := "fx %d" % fx_count + ("  ~%d" % c.chain.curves.size() if not c.chain.curves.is_empty() else "")
		draw_string(font, Vector2(r.position.x, r.position.y + 10), badge, HORIZONTAL_ALIGNMENT_RIGHT, r.size.x - 5.0, fs - 1, Color(c_text, 0.7))

	var selected := doc.is_selected(c)
	var focused := c == doc.focus_clip and doc.chain_tab == AWDocument.ChainTab.CLIP
	if focused:
		draw_rect(Rect2(r.position.x, r.end.y - 3.0, r.size.x, 3.0), c_acc)
	draw_rect(r, c_text if selected else base.lightened(0.1), false, 2.0 if selected else 1.0)
	if selected and r.size.x > 24.0:
		draw_rect(Rect2(r.position.x + fi - 3, r.position.y, 6, 6), c_text)
		draw_rect(Rect2(r.end.x - fo - 3, r.position.y, 6, 6), c_text)
