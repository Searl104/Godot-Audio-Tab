@tool
class_name AWClipGrid
extends Control
## The layering grid: clips can sit at any time on any row.
##
## Mouse: drag a clip to move it (time and row, all selected clips together), drag its
## edges to trim, drag the small squares at its top corners to set fades.
## Drag on empty space to box-select; click empty space to deselect and move the playhead.
## Shift adds to the selection, Ctrl toggles. Double-click a clip to audition it.
## Ctrl+wheel zooms, Shift+wheel scrolls time, Alt+wheel changes the row height, plain wheel scrolls rows;
## middle-drag pans, Shift+middle-drag zooms (AWTimelinePane.nav_input).
## Drop audio files from the FileSystem dock; several files land on consecutive rows.

const ROW_H_DEFAULT := 48.0
const ROW_H_MIN := 28.0
const ROW_H_MAX := 160.0
const EDGE := 6.0
const FADE_HANDLE := 7.0
const MIN_ROWS := 16
const PEAKS_PER_SEC := 120.0
## Group strip (header) height; it sits in a band above the group's first row.
const STRIP_H := 18.0
## Row height inside a collapsed group.
const COLLAPSED_ROW_H := 12.0
## Rows handle: a grip in the bottom-left corner of a group's frame.
const HANDLE_W := 12.0
const HANDLE_H := 16.0

## Height of one grid row. Alt+wheel changes it (taller rows show the waveform better).
var row_h := ROW_H_DEFAULT

## Row height changed (Alt+wheel), or the number of rows (the row headers follow).
signal row_height_changed

enum Drag { NONE, MOVE, TRIM_L, TRIM_R, FADE_IN, FADE_OUT, MARQUEE, CLICK, CTRL_PENDING, GAIN, SLIP, GROUP_MOVE, GROUP_L, GROUP_R, GROUP_ROWS }

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
var _menu_pos := Vector2.ZERO
var _drop_ghost := Rect2()
var _color_menu: PopupMenu
var _chain_menu: PopupMenu
var _fade_menus: Array[PopupMenu] = []
var _rename_edit: LineEdit
var _rename_clip: AWClip = null
var _gain_readout := ""
var _gain_clip: AWClip = null
var _targets := PackedFloat64Array() # snap targets for the drag in progress
var _snap_hit := -1.0 # target the drag is snapped to (drawn as a guide), or -1
var _group: AWGroup = null # the group being dragged
var _group_orig := {}
var _group_clips: Array[AWClip] = []
var _group_clip_orig := {}
var _group_menu: PopupMenu
var _group_color_menu: PopupMenu
var _menu_group: AWGroup = null
var _rename_group: AWGroup = null
# Row layout (variable heights: group strips, collapsed groups). Rebuilt when dirty.
var _tops := PackedFloat32Array()
var _hs := PackedFloat32Array()
var _layout_dirty := true
## Callable(event) -> bool from the timeline pane: shared pan / zoom gestures.
var nav := Callable()


func setup(p_doc: AWDocument) -> void:
	doc = p_doc
	view = doc.timeline_view


func _ready() -> void:
	clip_contents = true
	tooltip_text = " "
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	_color_menu = PopupMenu.new()
	_color_menu.name = "ColourMenu"
	for i in AWProject.CLIP_COLORS.size():
		var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
		img.fill(AWProject.CLIP_COLORS[i])
		_color_menu.add_icon_item(ImageTexture.create_from_image(img), "", i)
	_color_menu.id_pressed.connect(func(i: int) -> void:
		if _menu_clip:
			doc.set_clip_color(_menu_clip, AWProject.CLIP_COLORS[i]))
	_menu.add_child(_color_menu)
	_chain_menu = PopupMenu.new()
	_chain_menu.name = "ChainMenu"
	_chain_menu.id_pressed.connect(func(i: int) -> void:
		if _menu_clip == null:
			return
		if i == 1000:
			doc.new_chain_for(_menu_clip)
		elif i == 1001:
			doc.set_clip_chain(_menu_clip, null)
		else:
			doc.set_clip_chain(_menu_clip, doc.project.chains[i]))
	_menu.add_child(_chain_menu)
	for side in 2:
		var fm := PopupMenu.new()
		fm.name = "FadeInShape" if side == 0 else "FadeOutShape"
		for k in AWClip.FADE_SHAPE_NAMES.size():
			fm.add_radio_check_item(AWClip.FADE_SHAPE_NAMES[k], k)
		var sd := "in" if side == 0 else "out"
		fm.id_pressed.connect(func(k: int) -> void:
			if _menu_clip:
				doc.set_fade_shape(_menu_clip, sd, k as AWClip.FadeShape))
		_menu.add_child(fm)
		_fade_menus.append(fm)
	_group_menu = PopupMenu.new()
	_group_menu.name = "GroupMenu"
	_group_menu.id_pressed.connect(_on_group_menu)
	add_child(_group_menu)
	_group_color_menu = PopupMenu.new()
	_group_color_menu.name = "GroupColour"
	for i in AWProject.CLIP_COLORS.size():
		var gimg := Image.create(14, 14, false, Image.FORMAT_RGBA8)
		gimg.fill(AWProject.CLIP_COLORS[i])
		_group_color_menu.add_icon_item(ImageTexture.create_from_image(gimg), "", i)
	_group_color_menu.id_pressed.connect(func(i: int) -> void:
		if _menu_group:
			doc.set_group_props(_menu_group, {"color": AWProject.CLIP_COLORS[i]}, "Group Colour"))
	_group_menu.add_child(_group_color_menu)
	_rename_edit = LineEdit.new()
	_rename_edit.visible = false
	_rename_edit.text_submitted.connect(func(_t: String) -> void: _finish_rename(true))
	_rename_edit.focus_exited.connect(func() -> void: _finish_rename(true))
	_rename_edit.gui_input.connect(func(e: InputEvent) -> void:
		var k := e as InputEventKey
		if k and k.pressed and k.keycode == KEY_ESCAPE:
			_finish_rename(false)
			_rename_edit.accept_event())
	add_child(_rename_edit)
	resized.connect(func() -> void: view.set_view_width(size.x))
	view.changed.connect(queue_redraw)
	doc.project_changed.connect(func(_s: bool) -> void: _layout_dirty = true; _update_height(); queue_redraw())
	doc.groups_changed.connect(func() -> void: _layout_dirty = true; _update_height(); queue_redraw())
	doc.export_settings_changed.connect(queue_redraw)
	doc.selection_changed.connect(queue_redraw)
	doc.chain_target_changed.connect(queue_redraw)
	doc.playhead_changed.connect(queue_redraw)
	doc.transport_changed.connect(queue_redraw)
	_update_height()


func set_row_height(h: float) -> void:
	row_h = clampf(h, ROW_H_MIN, ROW_H_MAX)
	_layout_dirty = true
	_update_height()
	queue_redraw()
	row_height_changed.emit()


func _update_height() -> void:
	var h := content_height()
	if not is_equal_approx(custom_minimum_size.y, h):
		custom_minimum_size.y = h
		row_height_changed.emit()


## Rows the content needs (at least MIN_ROWS, one spare below the lowest clip or group).
func used_rows() -> int:
	return maxi(doc.project.max_row() + 2, MIN_ROWS)


func content_height() -> float:
	var n := used_rows()
	return row_top(n - 1) + row_height(n - 1)


## Rows drawn: enough to fill the visible area, plus one spare below the lowest clip.
func row_count() -> int:
	var n := used_rows()
	while row_top(n) < size.y:
		n += 1
	return n


# --- Row layout -----------------------------------------------------------------
# Rows are row_h tall, except inside a collapsed group (COLLAPSED_ROW_H). A row that is a group's
# first row has a STRIP_H band above it for the group's strip.

func _layout() -> void:
	if not _layout_dirty and not _tops.is_empty():
		return
	_layout_dirty = false
	var n := used_rows() + 1
	_tops.resize(n)
	_hs.resize(n)
	var band := {}
	var thin := {}
	for g in doc.project.groups:
		band[g.row] = true
		if g.collapsed:
			for r in range(g.row, g.row + g.row_count):
				thin[r] = true
	var y := 0.0
	for r in n:
		if band.has(r):
			y += STRIP_H
		_tops[r] = y
		_hs[r] = COLLAPSED_ROW_H if thin.has(r) else row_h
		y += _hs[r]


## Top of row r's clip area (below any group strip band).
func row_top(r: int) -> float:
	_layout()
	if r < 0:
		return 0.0
	if r < _tops.size():
		return _tops[r]
	var last := _tops.size() - 1
	return _tops[last] + _hs[last] + (r - last - 1) * row_h


func row_height(r: int) -> float:
	_layout()
	return _hs[r] if r >= 0 and r < _hs.size() else row_h


## Where row r's band begins (its strip band, if any, else its top).
func row_band_top(r: int) -> float:
	return 0.0 if r <= 0 else row_top(r - 1) + row_height(r - 1)


## Fractional row at y (a row's strip band counts as part of it), and back.
func y_to_rowf(y: float) -> float:
	var r := row_at(y)
	var a := row_band_top(r)
	var b := row_top(r) + row_height(r)
	return r + clampf((y - a) / maxf(b - a, 1e-6), 0.0, 1.0)


func rowf_to_y(f: float) -> float:
	var r := maxi(floori(f), 0)
	var a := row_band_top(r)
	var b := row_top(r) + row_height(r)
	return lerpf(a, b, f - r)


# --- Geometry -----------------------------------------------------------------

## On the timeline a clip spans its played duration, which grows when it's pitched down.
func clip_rect(c: AWClip) -> Rect2:
	var h := row_height(c.row)
	var m := 3.0 if h > COLLAPSED_ROW_H else 1.5
	return Rect2(view.time_to_x(c.start_sec), row_top(c.row) + m, c.play_length() * view.pixels_per_sec, h - m * 2.0)


## Fade positions in pixels from the clip's left / right edge (fades are in clip time).
func _fade_px(c: AWClip) -> Vector2:
	var w := c.warp()
	var fi := w.warp(minf(c.fade_in_sec, c.length_sec)) * view.pixels_per_sec
	var fo := (w.warp(c.length_sec) - w.warp(maxf(c.length_sec - c.fade_out_sec, 0.0))) * view.pixels_per_sec
	return Vector2(fi, fo)


func row_at(y: float) -> int:
	if y <= 0.0:
		return 0
	var r := 0
	while row_top(r) + row_height(r) <= y:
		r += 1
		if r > 100000:
			break
	return r


# --- Groups ---------------------------------------------------------------------

## The whole frame: strip band plus the rows' clip area.
func group_rect(g: AWGroup) -> Rect2:
	var x0 := view.time_to_x(g.start_sec)
	var x1 := view.time_to_x(g.end_sec)
	var y0 := row_top(g.row) - STRIP_H
	var y1 := row_top(g.last_row()) + row_height(g.last_row())
	return Rect2(x0, y0, x1 - x0, y1 - y0)


func strip_rect(g: AWGroup) -> Rect2:
	var r := group_rect(g)
	return Rect2(r.position, Vector2(r.size.x, STRIP_H))


## The rows handle: a grip in the frame's bottom-left corner (drag it down for more rows).
func handle_rect(g: AWGroup) -> Rect2:
	var r := group_rect(g)
	var h := minf(HANDLE_H, r.size.y - STRIP_H - 2.0)
	return Rect2(r.position.x + 1.0, r.end.y - h - 1.0, HANDLE_W, h)


## Strip buttons: [collapse] at the left, [M] [S] at the right (when there's room).
func _strip_buttons(g: AWGroup) -> Dictionary:
	var sr := strip_rect(g)
	var out := {"collapse": Rect2(sr.position + Vector2(6, 2), Vector2(14, STRIP_H - 4))}
	if sr.size.x >= 110.0:
		out["solo"] = Rect2(Vector2(sr.end.x - 24, sr.position.y + 2), Vector2(16, STRIP_H - 4))
		out["mute"] = Rect2(Vector2(sr.end.x - 42, sr.position.y + 2), Vector2(16, STRIP_H - 4))
	return out


## [group, part] under pos: part is "handle", "span_l", "span_r", "collapse", "mute", "solo" or
## "strip"; [null, ""] when no group part is there.
func group_part_at(pos: Vector2) -> Array:
	for g in doc.project.groups:
		if handle_rect(g).grow(1.0).has_point(pos):
			return [g, "handle"]
		var sr := strip_rect(g)
		if not sr.grow_individual(4, 0, 4, 0).has_point(pos):
			continue
		var buttons := _strip_buttons(g)
		for k: String in buttons:
			if (buttons[k] as Rect2).has_point(pos):
				return [g, k]
		if pos.x <= sr.position.x + 5.0:
			return [g, "span_l"]
		if pos.x >= sr.end.x - 5.0:
			return [g, "span_r"]
		return [g, "strip"]
	return [null, ""]


func _begin_group_drag(g: AWGroup, kind: Drag) -> void:
	_group = g
	_drag = kind
	_group_orig = {"start_sec": g.start_sec, "end_sec": g.end_sec, "row": g.row, "row_count": g.row_count}
	_group_clips = doc.project.group_clips(g) if kind == Drag.GROUP_MOVE else ([] as Array[AWClip])
	_group_clip_orig = {}
	for c in _group_clips:
		_group_clip_orig[c] = {"start_sec": c.start_sec, "row": c.row}
	if kind == Drag.GROUP_MOVE:
		_targets = doc.snap_targets(_group_clips)


func _group_motion(pos: Vector2) -> void:
	var g := _group
	var o := _group_orig
	var t := view.x_to_time(pos.x)
	match _drag:
		Drag.GROUP_MOVE:
			var s: float = maxf(0.0, doc.snap_to(o.start_sec + t - _press_t, _targets))
			var dt: float = s - o.start_sec
			var drow := maxi(row_at(pos.y) - row_at(_press_pos.y), -int(o.row))
			doc.preview_group(g, {"start_sec": o.start_sec + dt, "end_sec": o.end_sec + dt, "row": o.row + drow},
				_group_clips, _group_clip_orig, dt, drow)
		Drag.GROUP_L:
			doc.preview_group(g, {"start_sec": clampf(doc.snap(t), 0.0, o.end_sec - 0.05)})
		Drag.GROUP_R:
			doc.preview_group(g, {"end_sec": maxf(doc.snap(t), o.start_sec + 0.05)})
		Drag.GROUP_ROWS:
			var last := maxi(row_at(pos.y), int(o.row))
			doc.preview_group(g, {"row_count": last - int(o.row) + 1})


func _group_release() -> void:
	var g := _group
	var o := _group_orig
	var now := {"start_sec": g.start_sec, "end_sec": g.end_sec, "row": g.row, "row_count": g.row_count}
	# Back to where the drag started, then one undo step to the result.
	for key: String in o:
		g.set(key, o[key])
	for c in _group_clips:
		c.start_sec = _group_clip_orig[c].start_sec
		c.row = _group_clip_orig[c].row
	match _drag:
		Drag.GROUP_MOVE:
			if not is_equal_approx(now.start_sec, o.start_sec) or now.row != o.row:
				doc.move_group(g, now.start_sec - o.start_sec, now.row - o.row)
		Drag.GROUP_L, Drag.GROUP_R:
			doc.set_group_props(g, {"start_sec": now.start_sec, "end_sec": now.end_sec}, "Resize Group")
		Drag.GROUP_ROWS:
			doc.set_group_props(g, {"row_count": now.row_count}, "Group Rows")
	doc.project_changed.emit(false)
	_group = null
	_group_clips.clear()


func _open_group_menu(g: AWGroup, pos: Vector2) -> void:
	_menu_group = g
	doc.select_group(g)
	var m := _group_menu
	m.clear()
	m.add_item("Rename Group", 1)
	m.add_submenu_node_item("Group Colour", _group_color_menu)
	m.add_separator()
	m.add_check_item("Mute Group", 2)
	m.set_item_checked(-1, g.muted)
	m.add_check_item("Solo Group", 3)
	m.set_item_checked(-1, g.solo)
	m.add_check_item("Collapse", 4)
	m.set_item_checked(-1, g.collapsed)
	m.add_separator("Effect chain (a bus: the group's clips mixed, then processed once)")
	if g.chain:
		m.add_item("Show Group Chain", 5)
		m.add_item("Remove Group Chain", 6)
	else:
		m.add_item("New Group Chain", 5)
	m.add_separator()
	m.add_item("Ungroup", 7)
	AWTheme.popup_at(m, self, pos)


func _on_group_menu(id: int) -> void:
	var g := _menu_group
	if g == null:
		return
	match id:
		1: start_group_rename(g)
		2: doc.set_group_props(g, {"muted": not g.muted}, "Mute Group")
		3: doc.set_group_props(g, {"solo": not g.solo}, "Solo Group")
		4: doc.set_group_props(g, {"collapsed": not g.collapsed}, "Collapse Group")
		5: doc.new_group_chain(g)
		6: doc.remove_group_chain(g)
		7: doc.remove_group(g)


func start_group_rename(g: AWGroup) -> void:
	_rename_group = g
	var r := strip_rect(g)
	_rename_edit.text = g.name
	_rename_edit.position = Vector2(maxf(r.position.x + 20.0, 0.0), r.position.y - 4.0)
	_rename_edit.size = Vector2(clampf(r.size.x - 20.0, 120.0, 320.0), 0)
	_rename_edit.visible = true
	_rename_edit.grab_focus()
	_rename_edit.select_all()


## The clip under `pos` (clips on locked rows are ignored).
func clip_at(pos: Vector2) -> AWClip:
	for i in range(doc.project.clips.size() - 1, -1, -1):
		var c := doc.project.clips[i]
		if doc.project.row_locked(c.row):
			continue
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
	if nav.is_valid() and nav.call(event):
		accept_event()
		return
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
					if c and mb.position.y <= clip_rect(c).position.y + 13.0:
						start_rename(c)
					elif c:
						doc.engine.audition_clip(c)
						doc.message.emit("Audition \"%s\"" % c.name)
					else:
						doc.import_requested.emit(row_at(mb.position.y), maxf(0.0, doc.snap(view.x_to_time(mb.position.x))))
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
	var gp := group_part_at(mb.position)
	if gp[0] != null:
		var g: AWGroup = gp[0]
		match gp[1]:
			"collapse": doc.set_group_props(g, {"collapsed": not g.collapsed}, "Collapse Group")
			"mute": doc.set_group_props(g, {"muted": not g.muted}, "Mute Group")
			"solo": doc.set_group_props(g, {"solo": not g.solo}, "Solo Group")
			"handle": _begin_group_drag(g, Drag.GROUP_ROWS)
			"span_l": _begin_group_drag(g, Drag.GROUP_L)
			"span_r": _begin_group_drag(g, Drag.GROUP_R)
			_:
				doc.select_group(g)
				_begin_group_drag(g, Drag.GROUP_MOVE)
		return
	var c := clip_at(mb.position)
	_press_clip = c
	_items.clear()
	if c == null:
		_drag = Drag.CLICK
		_marquee_base = doc.selection.duplicate() if (mb.shift_pressed or mb.ctrl_pressed) else ([] as Array[AWClip])
		return
	if mb.ctrl_pressed and mb.alt_pressed:
		# Ctrl+Alt+drag: slip the audio inside the clip(s), always unsnapped.
		if not doc.is_selected(c):
			doc.select_clip(c)
		_drag = Drag.SLIP
		for s in doc.selection:
			_items.append([s, {"source_offset_sec": s.source_offset_sec}])
		_press_warp = c.warp()
		return
	if mb.ctrl_pressed:
		# Ctrl+click toggles the selection on release; Ctrl+vertical drag changes clip gain.
		_drag = Drag.CTRL_PENDING
		return
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
	_targets = doc.snap_targets(doc.selection if _drag == Drag.MOVE else [c])
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
	if _drag in [Drag.GROUP_MOVE, Drag.GROUP_L, Drag.GROUP_R, Drag.GROUP_ROWS]:
		_group_motion(pos)
		return
	match _drag:
		Drag.CLICK:
			if pos.distance_to(_press_pos) > 4.0:
				_drag = Drag.MARQUEE
				_motion(mm)
		Drag.MARQUEE:
			_marquee_rect = Rect2(_press_pos, pos - _press_pos).abs()
			var picked: Array[AWClip] = _marquee_base.duplicate()
			for c in doc.project.clips:
				if _marquee_rect.intersects(clip_rect(c)) and not picked.has(c) and not doc.project.row_locked(c.row):
					picked.append(c)
			doc.set_selection(picked)
			queue_redraw()
		Drag.MOVE:
			_move_selection(pos, mm.alt_pressed)
		Drag.CTRL_PENDING:
			var d := pos - _press_pos
			if absf(d.y) > 4.0 and absf(d.y) > absf(d.x):
				_start_gain_drag()
				_motion(mm)
		Drag.GAIN:
			var delta := -(pos.y - _press_pos.y) * (0.05 if mm.shift_pressed else 0.25)
			for it: Array in _items:
				var p: Dictionary = (it[1].params as Dictionary).duplicate()
				p["gain_db"] = clampf(float(p.get("gain_db", 0.0)) + delta, -60.0, 24.0)
				doc.preview_set(it[0], {"params": p})
			_gain_readout = "%+.1f dB" % delta if _items.size() > 1 else "%.1f dB" % float(_gain_clip.chain.effects[0].get_param("gain_db"))
			queue_redraw()
		Drag.SLIP:
			_slip(pos)
		Drag.TRIM_L, Drag.TRIM_R, Drag.FADE_IN, Drag.FADE_OUT:
			_edit_edge(pos)


func _move_selection(pos: Vector2, free_time: bool) -> void:
	var anchor: Dictionary = _items[0][1]
	for it: Array in _items:
		if it[0] == _press_clip:
			anchor = it[1]
	var raw: float = anchor.start_sec + (view.x_to_time(pos.x) - _press_t)
	var snapped := raw if free_time else doc.snap_span(raw, _press_clip.play_length(), _targets)
	_snap_hit = _guide_for([snapped, snapped + _press_clip.play_length()]) if not free_time else -1.0
	var dt: float = snapped - anchor.start_sec
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


## Ctrl+vertical drag: gain of the pressed clip, or of every selected clip (relative) if it's selected.
func _start_gain_drag() -> void:
	_drag = Drag.GAIN
	_gain_clip = _press_clip
	var targets: Array[AWClip] = doc.selection if doc.is_selected(_press_clip) else ([_press_clip] as Array[AWClip])
	_items.clear()
	for c in targets:
		var src: AWEffect = c.chain.effects[0]
		_items.append([src, {"params": src.params.duplicate()}])
	if _press_clip.chain.get_curve(_press_clip.chain.effects[0].id, "gain_db"):
		doc.message.emit("This clip's Gain has a curve, which overrides the gain set here.")


## Ctrl+Alt+drag: moves the audio under the clip; the clip, its fades and curves stay put.
func _slip(pos: Vector2) -> void:
	var c := _press_clip
	var start := c.start_sec
	var w := _press_warp
	var d_audio := w.unwarp(view.x_to_time(pos.x) - start) - w.unwarp(_press_t - start)
	for it: Array in _items:
		var clip: AWClip = it[0]
		var src_len := doc.engine.get_source_length(clip.source_path)
		var max_off := maxf(0.0, src_len - clip.length_sec) if src_len > 0.0 else INF
		var off: float = it[1].source_offset_sec + (d_audio if clip.reversed else -d_audio)
		doc.preview_set(clip, {"source_offset_sec": clampf(off, 0.0, max_off)})


func start_rename(c: AWClip) -> void:
	_rename_clip = c
	var r := clip_rect(c)
	_rename_edit.text = c.name
	_rename_edit.position = Vector2(maxf(r.position.x, 0.0), r.position.y - 2.0)
	_rename_edit.size = Vector2(clampf(r.size.x, 120.0, 320.0), 0)
	_rename_edit.visible = true
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _finish_rename(apply: bool) -> void:
	if _rename_group:
		var g := _rename_group
		_rename_group = null
		_rename_edit.visible = false
		if apply and _rename_edit.text.strip_edges() != "":
			doc.set_group_props(g, {"name": _rename_edit.text.strip_edges()}, "Rename Group")
		return
	if _rename_clip == null:
		return
	var c := _rename_clip
	_rename_clip = null
	_rename_edit.visible = false
	if apply:
		doc.rename_clip(c, _rename_edit.text)


## Edge drags: the mouse is in project time; the warp captured at press converts it to clip
## (audio) time, so trims and fades land on the sound you see under the cursor.
func _edit_edge(pos: Vector2) -> void:
	var c: AWClip = _items[0][0]
	var o: Dictionary = _items[0][1]
	var w := _press_warp
	var start: float = o.start_sec
	var length: float = o.length_sec
	var t := doc.snap(view.x_to_time(pos.x))
	if _drag == Drag.TRIM_L or _drag == Drag.TRIM_R:
		t = doc.snap_to(view.x_to_time(pos.x), _targets)
		_snap_hit = _guide_for([t])
	match _drag:
		Drag.TRIM_L:
			# Can't reveal audio past the file's edge, or cross the right edge. A reversed clip
			# starts at the source's end, so trimming its start reveals later audio.
			var spare: float = o.source_offset_sec
			if c.reversed:
				var src_len := doc.engine.get_source_length(c.source_path)
				spare = maxf(0.0, src_len - o.source_offset_sec - length) if src_len > 0.0 else 3600.0
			var min_start := maxf(0.0, start + w.warp(-spare))
			var max_start := start + w.warp(length - AWDocument.MIN_LEN)
			var s := clampf(t, min_start, max_start)
			var cut := w.unwarp(s - start) # audio time removed (negative = revealed)
			doc.preview_shift_curves(c, _orig_curve_keys, cut)
			var props := {"start_sec": s, "length_sec": length - cut,
				"source_offset_sec": o.source_offset_sec + (0.0 if c.reversed else cut),
				"fade_in_sec": minf(o.fade_in_sec, length - cut)}
			doc.preview_set(c, props)
		Drag.TRIM_R:
			var new_len := maxf(AWDocument.MIN_LEN, w.unwarp(t - start))
			if c.reversed: # the end of a reversed clip is the source's start
				new_len = minf(new_len, o.source_offset_sec + length)
				doc.preview_set(c, {"source_offset_sec": o.source_offset_sec + length - new_len})
			for i in range(1, _items.size()):
				doc.preview_set(_items[i][0], {"end_sec": new_len})
			doc.preview_set(c, {"length_sec": new_len, "fade_out_sec": minf(o.fade_out_sec, new_len)})
		Drag.FADE_IN:
			doc.preview_set(c, {"fade_in_sec": clampf(w.unwarp(t - start), 0.0, c.length_sec - c.fade_out_sec)})
		Drag.FADE_OUT:
			doc.preview_set(c, {"fade_out_sec": clampf(length - w.unwarp(t - start), 0.0, c.length_sec - c.fade_in_sec)})


## The target one of `times` landed on (for the guide line), or -1.
func _guide_for(times: Array) -> float:
	for t: float in times:
		for x in _targets:
			if absf(x - t) < 1e-6:
				return x
	return -1.0


func _release(mb: InputEventMouseButton) -> void:
	_snap_hit = -1.0
	match _drag:
		Drag.CLICK:
			if not (mb.shift_pressed or mb.ctrl_pressed):
				doc.clear_selection()
			doc.seek(maxf(0.0, doc.snap_to(view.x_to_time(mb.position.x), doc.snap_targets())))
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
		Drag.CTRL_PENDING:
			doc.select_clip(_press_clip, "toggle")
		Drag.GAIN:
			doc.commit_drags(_items, "Clip Gain")
			_gain_readout = ""
			_gain_clip = null
		Drag.SLIP:
			doc.commit_drags(_items, "Slip Clip")
		Drag.GROUP_MOVE, Drag.GROUP_L, Drag.GROUP_R, Drag.GROUP_ROWS:
			_group_release()
	_drag = Drag.NONE
	_items.clear()
	queue_redraw()


func _update_cursor(pos: Vector2) -> void:
	var shape := Control.CURSOR_ARROW
	var gp := group_part_at(pos)
	if gp[0] != null:
		match gp[1]:
			"handle": shape = Control.CURSOR_VSIZE
			"span_l", "span_r": shape = Control.CURSOR_HSIZE
			"strip": shape = Control.CURSOR_MOVE
			_: shape = Control.CURSOR_POINTING_HAND
		mouse_default_cursor_shape = shape
		return
	var c := clip_at(pos)
	if c:
		match clip_zone(c, pos):
			"trim_l", "trim_r": shape = Control.CURSOR_HSIZE
			"fade_in", "fade_out": shape = Control.CURSOR_POINTING_HAND
			_: shape = Control.CURSOR_MOVE
	mouse_default_cursor_shape = shape


# --- Context menu -------------------------------------------------------------

func _open_menu(pos: Vector2) -> void:
	var gp := group_part_at(pos)
	if gp[0] != null:
		_open_group_menu(gp[0], pos)
		return
	_menu.clear()
	_menu_clip = clip_at(pos)
	_menu_pos = pos
	_menu_t = maxf(0.0, doc.snap(view.x_to_time(pos.x)))
	if _menu_clip:
		if not doc.is_selected(_menu_clip):
			doc.select_clip(_menu_clip)
		_menu.add_item("Show Effect Chain", 1)
		_chain_menu.clear()
		_chain_menu.add_item("New Chain", 1000)
		_chain_menu.add_separator()
		_chain_menu.add_radio_check_item("None (dry)", 1001)
		_chain_menu.set_item_checked(_chain_menu.item_count - 1, _menu_clip.fx_chain == null)
		for i in doc.project.chains.size():
			_chain_menu.add_radio_check_item(doc.project.chains[i].name, i)
			_chain_menu.set_item_checked(_chain_menu.item_count - 1, _menu_clip.fx_chain == doc.project.chains[i])
		_menu.add_submenu_node_item("Effect Chain", _chain_menu)
		_menu.add_separator()
		_menu.add_item("Split at Playhead", 2)
		_menu.add_item("Split Here", 3)
		_menu.add_item("Duplicate", 4)
		_menu.add_item("Unmute" if _menu_clip.muted else "Mute", 5)
		_menu.add_item("Rename  (F2)", 14)
		_menu.add_submenu_node_item("Colour", _color_menu)
		_menu.add_item("Unreverse" if _menu_clip.reversed else "Reverse", 15)
		_menu.add_submenu_node_item("Fade In Shape", _fade_menus[0])
		_menu.add_submenu_node_item("Fade Out Shape", _fade_menus[1])
		for side in 2:
			var cur: int = _menu_clip.fade_in_shape if side == 0 else _menu_clip.fade_out_shape
			for k in _fade_menus[side].item_count:
				_fade_menus[side].set_item_checked(k, k == cur)
		if doc.selection.size() >= 2:
			_menu.add_item("Crossfade Overlaps", 16)
		_menu.add_separator()
		_menu.add_item("Delete", 6)
		if doc.is_clip_missing(_menu_clip):
			_menu.add_separator()
			_menu.add_item("Relink Sound File...", 7)
			_menu.add_item("Relink From Folder...", 8)
		elif doc.is_clip_external(_menu_clip):
			_menu.add_separator()
			_menu.add_item("Copy Into Project", 9)
		_menu.add_separator()
		_menu.add_item("Import Sound...", 13)
	else:
		_menu.add_item("Import Sound...", 13)
		_menu.add_separator()
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
		5: doc.toggle_mute_clips(_menu_clip)
		6: doc.delete_selected_clips()
		7: doc.relink_requested.emit(_menu_clip, "file")
		8: doc.relink_requested.emit(_menu_clip, "folder")
		9: doc.copy_clip_into_project(_menu_clip)
		13: doc.import_requested.emit(row_at(_menu_pos.y), _menu_t)
		14: start_rename(_menu_clip)
		15: doc.toggle_reverse_clips(_menu_clip)
		16: doc.crossfade_selected()
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
	var r0 := row_at(at_position.y)
	var r1 := r0 + files.size() - 1
	_drop_ghost = Rect2(view.time_to_x(t), row_top(r0) + 3.0, 1.0 * view.pixels_per_sec, row_top(r1) + row_height(r1) - row_top(r0) - 6.0)
	queue_redraw()
	return true


func _drop_data(at_position: Vector2, data: Variant) -> void:
	_drop_ghost = Rect2()
	var t := maxf(0.0, doc.snap(view.x_to_time(at_position.x)))
	var row := row_at(at_position.y)
	doc.import_files(_audio_files(data), row, t, AWImporter.copy_by_default())


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
		var ry := row_top(r)
		var rh := row_height(r)
		if r % 2 == 1:
			draw_rect(Rect2(0, ry, size.x, rh), Color(1, 1, 1, 0.015))
		var rr := doc.project.row(r)
		if rr and rr.color.a > 0.0:
			draw_rect(Rect2(0, ry, size.x, rh), Color(rr.color, 0.06))
		draw_line(Vector2(0, ry + rh - 0.5), Vector2(size.x, ry + rh - 0.5), Color(0, 0, 0, 0.25))
	AWTheme.draw_time_grid(self, view, 0.0, size.y)
	for g in doc.project.groups:
		_draw_group_frame(g, c_text, c_acc)

	var p := doc.project
	if p.loop_enabled:
		var xs := view.time_to_x(p.loop_start_sec)
		draw_rect(Rect2(xs, 0, view.time_to_x(p.loop_end_sec) - xs, size.y), Color(c_acc, 0.06))

	# Time selection (Shift+drag on the ruler) and markers, under the clips.
	if doc.has_time_selection():
		var sx0 := view.time_to_x(doc.time_sel.x)
		var sx1 := view.time_to_x(doc.time_sel.y)
		draw_rect(Rect2(sx0, 0, sx1 - sx0, size.y), Color(c_acc, 0.10))
		draw_line(Vector2(sx0, 0), Vector2(sx0, size.y), Color(c_acc, 0.6))
		draw_line(Vector2(sx1, 0), Vector2(sx1, size.y), Color(c_acc, 0.6))
	for m in p.markers:
		var mx := view.time_to_x(m.time_sec)
		if mx >= -1.0 and mx <= size.x + 1.0:
			draw_dashed_line(Vector2(mx, 0), Vector2(mx, size.y), Color(AWTimeRuler.MARKER_COLOR, 0.45), 1.0, 4.0)

	for c in p.clips:
		_draw_clip(c, c_text, c_acc)
	for g in p.groups:
		_draw_group_strip(g, c_text, c_acc)
	if p.clips.is_empty():
		var font := get_theme_default_font()
		var fs := get_theme_default_font_size()
		var msg := "Drag audio files here from the FileSystem dock (WAV, Ogg, MP3)"
		var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2((size.x - w) * 0.5, minf(size.y * 0.5, row_h * 1.5)), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(c_text, 0.5))

	if _snap_hit >= 0.0:
		var gx := view.time_to_x(_snap_hit)
		draw_line(Vector2(gx, 0), Vector2(gx, size.y), Color(c_acc, 0.9), 1.0)
	if _gain_readout != "" and _gain_clip:
		var gr := clip_rect(_gain_clip)
		var font := get_theme_default_font()
		var fs := get_theme_default_font_size()
		var tw := font.get_string_size(_gain_readout, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var box := Rect2(Vector2(clampf(gr.get_center().x - tw * 0.5 - 6.0, 0.0, size.x - tw - 12.0), gr.position.y + gr.size.y * 0.5 - fs * 0.5 - 4.0), Vector2(tw + 12.0, fs + 8.0))
		draw_rect(box, Color(0, 0, 0, 0.75))
		draw_string(font, box.position + Vector2(6, fs + 2), _gain_readout, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
	if _drop_ghost.size != Vector2.ZERO:
		draw_rect(_drop_ghost, Color(c_acc, 0.2))
		draw_rect(_drop_ghost, c_acc, false, 1.0)
	if _drag == Drag.MARQUEE:
		draw_rect(_marquee_rect, Color(c_acc, 0.12))
		draw_rect(_marquee_rect, Color(c_acc, 0.8), false, 1.0)

	var end_sec := doc.export_end_sec()
	if end_sec > 0.0:
		var ex := view.time_to_x(end_sec)
		draw_rect(Rect2(ex, 0, maxf(size.x - ex, 0.0), size.y), Color(0, 0, 0, 0.18))
		AWTheme.draw_export_end(self, ex, 0.0, size.y, false, doc.project.export_end_is_auto())

	var px := view.time_to_x(doc.playhead_sec)
	draw_line(Vector2(px, 0), Vector2(px, size.y), c_acc, 2.0)


## A group's frame, under the clips: a tint over its rows and an outline.
func _draw_group_frame(g: AWGroup, _c_text: Color, c_acc: Color) -> void:
	var r := group_rect(g)
	if r.end.x < -2.0 or r.position.x > size.x + 2.0:
		return
	var sel := doc.selected_group == g
	var heard := not g.muted and (not doc.project.any_solo() or g.solo)
	var col := g.color if heard else g.color.lerp(Color(0.45, 0.45, 0.45), 0.7)
	draw_rect(Rect2(r.position + Vector2(0, STRIP_H), r.size - Vector2(0, STRIP_H)), Color(col, 0.07))
	draw_rect(r, Color(c_acc, 0.95) if sel else Color(col, 0.55), false, 2.0 if sel else 1.0)


## A group's strip (header), over everything: collapse arrow, name, chain mark, M / S.
func _draw_group_strip(g: AWGroup, c_text: Color, c_acc: Color) -> void:
	var sr := strip_rect(g)
	if sr.end.x < -2.0 or sr.position.x > size.x + 2.0:
		return
	var heard := not g.muted and (not doc.project.any_solo() or g.solo)
	var col := g.color if heard else g.color.lerp(Color(0.45, 0.45, 0.45), 0.7)
	# Rows handle (bottom-left corner): drag down to take in more rows.
	var hr := handle_rect(g)
	var hb := StyleBoxFlat.new()
	hb.bg_color = col.darkened(0.25)
	hb.set_corner_radius_all(2)
	hb.border_color = Color(0, 0, 0, 0.5)
	hb.set_border_width_all(1)
	draw_style_box(hb, hr)
	var cx := hr.get_center().x
	var cy := hr.get_center().y
	draw_colored_polygon(PackedVector2Array([Vector2(cx - 3.5, cy - 1.5), Vector2(cx + 3.5, cy - 1.5), Vector2(cx, cy + 3.0)]), Color.WHITE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.25)
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	if doc.selected_group == g:
		sb.border_color = c_acc
		sb.set_border_width_all(1)
	draw_style_box(sb, sr)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 3
	var buttons := _strip_buttons(g)
	var cr: Rect2 = buttons["collapse"]
	var arrow := "▸" if g.collapsed else "▾"
	draw_string(font, Vector2(cr.position.x, sr.position.y + STRIP_H - 5.0), arrow, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
	var right := sr.end.x - 6.0
	for k: String in ["mute", "solo"]:
		if buttons.has(k):
			var br: Rect2 = buttons[k]
			var on: bool = g.muted if k == "mute" else g.solo
			var bcol := Color("#e0b030") if (on and k == "solo") else (Color("#d05050") if on else Color(0, 0, 0, 0.25))
			draw_rect(br, bcol)
			draw_string(font, br.position + Vector2(4, br.size.y - 3.0), "M" if k == "mute" else "S", HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color.WHITE)
			right = minf(right, br.position.x - 4.0)
	var label := g.name + ("  ▣ chain" if g.chain else "")
	var lx := cr.end.x + 4.0
	if right - lx > 12.0:
		draw_string(font, Vector2(lx, sr.position.y + STRIP_H - 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, right - lx, fs, Color.WHITE)


func _draw_clip(c: AWClip, c_text: Color, c_acc: Color) -> void:
	var r := clip_rect(c)
	if r.end.x < -2.0 or r.position.x > size.x + 2.0:
		return
	var base := c.color
	if not doc.project.is_clip_audible(c):
		base = base.lerp(Color(0.45, 0.45, 0.45), 0.75)
	var body := base.darkened(0.45)
	draw_rect(r, body)
	if r.size.y < 20.0:
		# A collapsed group's row: just the clip's extent.
		draw_rect(Rect2(r.position, Vector2(r.size.x, 2.0)), base)
		if doc.is_selected(c):
			draw_rect(r, c_acc, false, 1.0)
		return
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
		var src := c.source_time(local)
		var peak := peaks[clampi(int(src * PEAKS_PER_SEC), 0, peaks.size() - 1)] if src >= 0.0 and src * PEAKS_PER_SEC < peaks.size() else (0.0 if has_real else 0.05)
		var h := peak * amp * c.fade_at(local)
		draw_line(Vector2(x, mid - h), Vector2(x, mid + h), wave)
		x += 2.0

	# Fades
	var fpx := _fade_px(c)
	var fi := fpx.x
	var fo := fpx.y
	# The fade curves follow their shape (Linear, Fast, Slow, S-Curve, Equal Power).
	for side in 2:
		var span := fi if side == 0 else fo
		if span <= 1.0:
			continue
		var shape := c.fade_in_shape if side == 0 else c.fade_out_shape
		var line := PackedVector2Array()
		var n := clampi(int(span / 3.0), 4, 48)
		for k in n + 1:
			var u := float(k) / n # 0 = silent end, 1 = full
			var fx := r.position.x + u * span if side == 0 else r.end.x - u * span
			line.append(Vector2(fx, r.end.y - (r.end.y - wave_top) * AWClip.fade_gain(shape, u)))
		var shade := line.duplicate()
		shade.append(Vector2(line[n].x, wave_top))
		shade.append(Vector2(line[0].x, wave_top))
		draw_colored_polygon(shade, Color(0, 0, 0, 0.35))
		draw_polyline(line, Color(c_text, 0.6), 1.0, true)

	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 3
	var missing := doc.is_clip_missing(c)
	if missing:
		var red := Color("#e5484d")
		draw_rect(Rect2(r.position.x, r.position.y + 13.0, r.size.x, r.size.y - 13.0), Color(red, 0.18))
		var hx := r.position.x - r.size.y
		while hx < r.end.x:
			var a := Vector2(maxf(hx, r.position.x), r.end.y - (maxf(hx, r.position.x) - hx))
			var b := Vector2(minf(hx + r.size.y, r.end.x), r.end.y - (minf(hx + r.size.y, r.end.x) - hx))
			draw_line(a, b, Color(red, 0.35), 1.0)
			hx += 12.0
	var external := not missing and doc.is_clip_external(c)
	var label := ("◂ " if c.reversed else "") + c.name + ("  (muted)" if c.muted else "") + ("  (locked)" if doc.project.row_locked(c.row) else "") + ("  (sound file missing)" if missing else "") + ("  ↗ outside project" if external else "")
	draw_string(font, r.position + Vector2(5, 10), label, HORIZONTAL_ALIGNMENT_LEFT, maxf(r.size.x - 10.0, 0.0), fs, c_text)
	if doc.snap_sec > 0.0 and doc.snap_target_on("transients") and r.size.y > 20.0:
		for tt in doc.clip_transients(c):
			var tx := view.time_to_x(tt)
			draw_line(Vector2(tx, r.end.y - 6.0), Vector2(tx, r.end.y), Color(1, 1, 1, 0.75), 1.0)
	var fx_count := (c.chain.effects.size() - 1 if c.chain else 0) + (c.fx_chain.effects.size() if c.fx_chain else 0)
	if (fx_count > 0 or c.fx_chain) and r.size.x > 90.0:
		var badge := (c.fx_chain.name + " " if c.fx_chain else "") + ("fx %d" % fx_count) + ("  ~%d" % c.chain.curves.size() if not c.chain.curves.is_empty() else "")
		draw_string(font, Vector2(r.position.x, r.position.y + 10), badge, HORIZONTAL_ALIGNMENT_RIGHT, r.size.x - 5.0, fs - 1, Color(c_text, 0.7))

	var selected := doc.is_selected(c)
	var focused := c == doc.focus_clip and doc.chain_tab == AWDocument.ChainTab.CLIP
	if focused:
		draw_rect(Rect2(r.position.x, r.end.y - 3.0, r.size.x, 3.0), c_acc)
	draw_rect(r, Color("#e5484d") if missing else (c_text if selected else base.lightened(0.1)), false, 2.0 if (selected or missing) else 1.0)
	if selected and r.size.x > 24.0:
		draw_rect(Rect2(r.position.x + fi - 3, r.position.y, 6, 6), c_text)
		draw_rect(Rect2(r.end.x - fo - 3, r.position.y, 6, 6), c_text)


## Hover info: file, length, gain, pitch, offset, fades.
func _get_tooltip(at: Vector2) -> String:
	var c := clip_at(at)
	if c == null:
		return "Double-click to import a sound here. Drag to box-select."
	var src: AWEffect = c.chain.effects[0] if c.chain and not c.chain.effects.is_empty() else null
	var lines := PackedStringArray()
	lines.append(c.name + ("  (reversed)" if c.reversed else ""))
	lines.append(c.source_path if c.source_path != "" else "(no sound file)")
	lines.append("Start %s · Length %.3f s on the timeline (%.3f s of audio)" % [doc.format_clock(c.start_sec), c.play_length(), c.length_sec])
	if src:
		lines.append("Gain %.1f dB · Pitch %+.2f st · Pan %+.2f" % [float(src.get_param("gain_db")), float(src.get_param("pitch_semitones")), float(src.get_param("pan"))])
	lines.append("File offset %.3f s · Fades %.3f / %.3f s (%s / %s)" % [c.source_offset_sec, c.fade_in_sec, c.fade_out_sec,
		AWClip.FADE_SHAPE_NAMES[c.fade_in_shape], AWClip.FADE_SHAPE_NAMES[c.fade_out_shape]])
	if c.fx_chain:
		lines.append("Chain: %s (%d effect%s)" % [c.fx_chain.name, c.fx_chain.effects.size(), "" if c.fx_chain.effects.size() == 1 else "s"])
	else:
		lines.append("No effect chain (dry)")
	var g := doc.project.group_of(c)
	if g:
		lines.append("In group \"%s\" (drag its strip to move it; Ctrl+Shift+G ungroups)" % g.name)
	return "\n".join(lines)
