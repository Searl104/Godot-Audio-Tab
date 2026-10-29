@tool
class_name AWCurveGraph
extends Control
## Overlaid Bezier automation curves for the active chain. Each curve fills the plot's height
## on its own scale (linear, log for Hz, fader for dB), so different units share one plot.
## Key values here are in that 0..1 space; hover shows the real parameter value.
##
## Controls follow Godot's Bezier editor:
##   Click a key to select (Shift add, Ctrl toggle); drag to move (Shift locks an axis).
##   Drag the handles of selected keys. Drag empty space to box-select keys.
##   Double-click or Ctrl+click to insert a key on the active curve.
##   Delete removes selected keys, Ctrl+A selects all, F frames the curves.
##   Wheel zooms, Shift+wheel scrolls, middle-drag pans. Right-click for handle modes and more.
## Curves set to Dim are drawn faintly and can't be edited; Off curves are hidden.

const PAD_Y := 16.0
const KEY_R := 4.5
const HANDLE_R := 3.5
const HIT := 7.0

enum Drag { NONE, MOVE, HANDLE, MARQUEE, PAN, CLICK }

var doc: AWDocument
var view: AWTimeView

## Selected key indices on the active curve.
var selected_keys: Array[int] = []

var _drag := Drag.NONE
var _press_pos := Vector2.ZERO
var _orig_keys: Array = []
var _handle := [-1, ""]
var _marquee := Rect2()
var _marquee_base: Array[int] = []
var _hover_curve: AWCurve = null
var _hover_pos := Vector2.ZERO
var _menu: PopupMenu
var _menu_pos := Vector2.ZERO
var _menu_curve: AWCurve = null
var _last_active: AWCurve = null


func setup(p_doc: AWDocument) -> void:
	doc = p_doc
	view = doc.curve_view


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
	doc.project_changed.connect(func(_s: bool) -> void: _validate_selection(); queue_redraw())
	doc.export_settings_changed.connect(queue_redraw)
	doc.chain_target_changed.connect(func() -> void: selected_keys.clear(); queue_redraw())
	doc.curve_view_changed.connect(_on_curve_view_changed)
	doc.lfo_panel_changed.connect(queue_redraw)
	doc.playhead_changed.connect(queue_redraw)


func _on_curve_view_changed() -> void:
	if doc.active_curve != _last_active:
		selected_keys.clear()
		_last_active = doc.active_curve
	queue_redraw()


func _validate_selection() -> void:
	var c := doc.active_curve
	var n := chain().get_keys(c).size() if (c and chain()) else 0
	selected_keys = selected_keys.filter(func(i: int) -> bool: return i < n)


func chain() -> AWChain:
	return doc.active_chain()


# --- Mapping ------------------------------------------------------------------

func _plot_h() -> float:
	return maxf(size.y - PAD_Y * 2.0, 1.0)


## 0..1 curve height -> y. (`c` is kept so per-curve vertical zoom can be added later.)
func val_to_y(_c: AWCurve, n: float) -> float:
	return PAD_Y + (1.0 - n) * _plot_h()


func y_to_val(_c: AWCurve, y: float) -> float:
	return clampf(1.0 - (y - PAD_Y) / _plot_h(), 0.0, 1.0)


func y_to_val_unclamped(y: float) -> float:
	return 1.0 - (y - PAD_Y) / _plot_h()


func local_to_x(t: float) -> float:
	return view.time_to_x(doc.local_to_view(t))


func x_to_local(x: float) -> float:
	return doc.view_to_local(view.x_to_time(x))


## Pixels per (curve-time second, 0..1 unit) around curve time t. Horizontal scale varies
## with playback rate in Project Time view, so it's measured locally.
func px_per_unit(_c: AWCurve, t := 0.0) -> Vector2:
	var dx := (local_to_x(t + 0.001) - local_to_x(t)) / 0.001
	return Vector2(maxf(dx, 0.0001), _plot_h())


func key_pos(c: AWCurve, k: Dictionary) -> Vector2:
	return Vector2(local_to_x(k.t), val_to_y(c, k.v))


func handle_pos(c: AWCurve, k: Dictionary, which: String) -> Vector2:
	var h: Vector2 = k[which]
	return Vector2(local_to_x(k.t + h.x), val_to_y(c, k.v + h.y))


func _editable_curves() -> Array[AWCurve]:
	var out: Array[AWCurve] = []
	if chain() == null:
		return out
	for c in chain().curves:
		if doc.is_curve_editable(c):
			out.append(c)
	# Active curve first so it wins hit tests.
	if doc.active_curve and out.has(doc.active_curve):
		out.erase(doc.active_curve)
		out.push_front(doc.active_curve)
	return out


# --- Hit tests ----------------------------------------------------------------

func hit_handle(pos: Vector2) -> Array:
	var c := doc.active_curve
	if c == null or not doc.is_curve_editable(c):
		return [-1, ""]
	var keys := chain().get_keys(c)
	for i in selected_keys:
		if i >= keys.size() or keys[i].mode == AWCurve.HandleMode.LINEAR:
			continue
		for which: String in ["in", "out"]:
			if (keys[i][which] as Vector2) != Vector2.ZERO and handle_pos(c, keys[i], which).distance_to(pos) <= HIT:
				return [i, which]
	return [-1, ""]


## [curve, key index] or [null, -1].
func hit_key(pos: Vector2) -> Array:
	for c in _editable_curves():
		var keys := chain().get_keys(c)
		for i in range(keys.size() - 1, -1, -1):
			if key_pos(c, keys[i]).distance_to(pos) <= HIT:
				return [c, i]
	return [null, -1]


func hit_curve(pos: Vector2, editable_only := true) -> AWCurve:
	if chain() == null:
		return null
	var t := x_to_local(pos.x)
	if t < 0.0 or t > doc.curve_domain_len():
		return null
	var candidates: Array[AWCurve] = _editable_curves()
	if not editable_only:
		for c in chain().curves:
			if doc.is_curve_visible(c) and not candidates.has(c):
				candidates.append(c)
	for c in candidates:
		if absf(val_to_y(c, chain().sample_norm(c, t)) - pos.y) <= HIT:
			return c
	return null


# --- Input --------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if view.handle_wheel(mb, mb.position.x, true):
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag = Drag.PAN if mb.pressed else Drag.NONE
			_press_pos = mb.position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				grab_focus()
				if mb.double_click or mb.ctrl_pressed and hit_key(mb.position)[0] == null:
					insert_key_at(mb.position)
				else:
					_press(mb)
			else:
				_release()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			grab_focus()
			_open_menu(mb.position)
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag == Drag.NONE:
			_hover(mm.position)
		else:
			_motion(mm)
			accept_event()
	elif event is InputEventKey and event.pressed and not event.echo:
		if _key(event as InputEventKey):
			accept_event()


func _key(k: InputEventKey) -> bool:
	match k.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			delete_selected_keys()
			return true
		KEY_F:
			doc.frame_curves()
			return true
		KEY_A:
			if k.ctrl_pressed or k.meta_pressed:
				select_all_keys()
				return true
		KEY_ESCAPE:
			selected_keys.clear()
			queue_redraw()
			return true
	return false


func _press(mb: InputEventMouseButton) -> void:
	_press_pos = mb.position
	if chain() == null:
		return
	var h := hit_handle(mb.position)
	if h[0] >= 0:
		_handle = h
		_orig_keys = chain().get_keys(doc.active_curve)
		_drag = Drag.HANDLE
		return
	var hk := hit_key(mb.position)
	if hk[0] != null:
		var c: AWCurve = hk[0]
		var i: int = hk[1]
		if c != doc.active_curve:
			doc.set_active_curve(c)
			selected_keys.clear()
		if mb.ctrl_pressed:
			if selected_keys.has(i):
				selected_keys.erase(i)
			else:
				selected_keys.append(i)
		elif mb.shift_pressed:
			if not selected_keys.has(i):
				selected_keys.append(i)
		elif not selected_keys.has(i):
			selected_keys = [i]
		_orig_keys = chain().get_keys(c)
		_drag = Drag.MOVE if selected_keys.has(i) else Drag.NONE
		queue_redraw()
		return
	var hc := hit_curve(mb.position)
	if hc:
		doc.set_active_curve(hc)
		selected_keys.clear()
		_drag = Drag.NONE
		queue_redraw()
		return
	_marquee_base = selected_keys.duplicate() if (mb.shift_pressed or mb.ctrl_pressed) else ([] as Array[int])
	_drag = Drag.CLICK


func _motion(mm: InputEventMouseMotion) -> void:
	var pos := mm.position
	match _drag:
		Drag.PAN:
			view.scroll_by(_press_pos.x - pos.x)
			_press_pos = pos
		Drag.CLICK:
			if pos.distance_to(_press_pos) > 4.0:
				_drag = Drag.MARQUEE
				_motion(mm)
		Drag.MARQUEE:
			_marquee = Rect2(_press_pos, pos - _press_pos).abs()
			var c := doc.active_curve
			selected_keys = _marquee_base.duplicate()
			if c and doc.is_curve_editable(c):
				var keys := chain().get_keys(c)
				for i in keys.size():
					if _marquee.has_point(key_pos(c, keys[i])) and not selected_keys.has(i):
						selected_keys.append(i)
			queue_redraw()
		Drag.MOVE:
			_move_keys(pos, mm.shift_pressed, mm.alt_pressed)
		Drag.HANDLE:
			var c := doc.active_curve
			var keys := _orig_keys.duplicate(true)
			var k: Dictionary = keys[_handle[0]]
			var new_handle := Vector2(x_to_local(pos.x) - k.t, y_to_val_unclamped(pos.y) - k.v)
			AWCurveMath.drag_handle(k, _handle[1], new_handle, px_per_unit(c, k.t))
			doc.preview_curve_keys(chain(), c, keys)


func _move_keys(pos: Vector2, lock_axis: bool, free_time: bool) -> void:
	var c := doc.active_curve
	var d := pos - _press_pos
	if lock_axis:
		if absf(d.x) > absf(d.y):
			d.y = 0.0
		else:
			d.x = 0.0
	var dv := -d.y / _plot_h()
	var keys := _orig_keys.duplicate(true)
	var domain := doc.curve_domain_len()
	for i in keys.size():
		keys[i]["_sel"] = selected_keys.has(i)
		if selected_keys.has(i):
			var t: float = keys[i].t
			if d.x != 0.0:
				# Move in view time (so warped Project Time view feels right), snap there, map back.
				var v := view.x_to_time(local_to_x(t) + d.x)
				t = doc.view_to_local(v if free_time else doc.snap(v))
			keys[i]["t"] = clampf(t, 0.0, domain)
			keys[i]["v"] = clampf(keys[i].v + dv, 0.0, 1.0)
	keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.t < b.t)
	selected_keys.clear()
	for i in keys.size():
		if keys[i]["_sel"]:
			selected_keys.append(i)
		keys[i].erase("_sel")
	doc.preview_curve_keys(chain(), c, keys)


func _release() -> void:
	match _drag:
		Drag.CLICK:
			selected_keys = _marquee_base.duplicate()
			var hc := hit_curve(_press_pos, false)
			if hc == null and _marquee_base.is_empty():
				doc.seek(doc.view_to_project(maxf(0.0, view.x_to_time(_press_pos.x))))
		Drag.MOVE:
			doc.commit_curve_drag(chain(), doc.active_curve, _orig_keys, "Move Keys")
		Drag.HANDLE:
			doc.commit_curve_drag(chain(), doc.active_curve, _orig_keys, "Edit Handle")
	_drag = Drag.NONE
	_marquee = Rect2()
	queue_redraw()


func _hover(pos: Vector2) -> void:
	_hover_pos = pos
	var c := hit_curve(pos, false)
	var hk := hit_key(pos)
	if hk[0] != null:
		c = hk[0]
	if c != _hover_curve or c != null:
		_hover_curve = c
		queue_redraw()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if (hk[0] != null or hit_handle(pos)[0] >= 0) else Control.CURSOR_ARROW


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover_curve:
		_hover_curve = null
		queue_redraw()


# --- Key operations -----------------------------------------------------------

func insert_key_at(pos: Vector2) -> void:
	var c := doc.active_curve
	var hc := hit_curve(pos)
	if hc:
		c = hc
	if c == null or not doc.is_curve_editable(c):
		doc.message.emit("Select a curve first (click it, or its dot's right-click menu > Select).")
		return
	doc.set_active_curve(c)
	var t := clampf(doc.view_to_local(doc.snap(view.x_to_time(pos.x))), 0.0, doc.curve_domain_len())
	var v := chain().sample_norm(c, t) if hc else y_to_val(c, pos.y)
	var keys := chain().get_keys(c)
	for k: Dictionary in keys:
		if is_equal_approx(k.t, t):
			return
	keys.append({"t": t, "v": v, "in": Vector2.ZERO, "out": Vector2.ZERO, "mode": AWCurve.HandleMode.BALANCED, "_new": true})
	keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.t < b.t)
	var idx := 0
	for i in keys.size():
		if keys[i].has("_new"):
			idx = i
			keys[i].erase("_new")
	AWCurveMath.smooth(keys, idx)
	doc.set_curve_keys(chain(), c, keys, "Insert Key")
	selected_keys = [idx]
	queue_redraw()


func delete_selected_keys() -> void:
	var c := doc.active_curve
	if c == null or selected_keys.is_empty():
		return
	var keys := chain().get_keys(c)
	if selected_keys.size() >= keys.size():
		doc.message.emit("A curve needs at least one key. Use Remove Curve to delete it.")
		return
	var kept := []
	for i in keys.size():
		if not selected_keys.has(i):
			kept.append(keys[i])
	doc.set_curve_keys(chain(), c, kept, "Delete Keys")
	selected_keys.clear()


func select_all_keys() -> void:
	var c := doc.active_curve
	if c == null:
		return
	selected_keys.clear()
	for i in chain().get_keys(c).size():
		selected_keys.append(i)
	queue_redraw()


func _apply_to_selected(op: Callable, action_name: String) -> void:
	var c := doc.active_curve
	if c == null or selected_keys.is_empty():
		doc.message.emit("Select one or more keys first.")
		return
	var keys := chain().get_keys(c)
	for i in selected_keys:
		op.call(keys, i)
	doc.set_curve_keys(chain(), c, keys, action_name)


# --- Context menu -------------------------------------------------------------

func _open_menu(pos: Vector2) -> void:
	_menu_pos = pos
	_menu.clear()
	if chain() == null:
		return
	var hk := hit_key(pos)
	if hk[0] != null:
		if hk[0] != doc.active_curve:
			doc.set_active_curve(hk[0])
		if not selected_keys.has(hk[1]):
			selected_keys = [hk[1]]
		queue_redraw()
	_menu_curve = hk[0] if hk[0] != null else hit_curve(pos, false)
	var has_active := doc.active_curve != null
	var has_sel := has_active and not selected_keys.is_empty()
	_menu.add_item("Insert Key Here", 1)
	_menu.set_item_disabled(-1, not has_active and _menu_curve == null)
	_menu.add_item("Delete Selected Keys", 2)
	_menu.set_item_disabled(-1, not has_sel)
	_menu.add_separator("Handles")
	var current := -1
	if has_sel:
		var keys := chain().get_keys(doc.active_curve)
		current = keys[selected_keys[0]].mode
	for pair: Array in [["Free", 10, AWCurve.HandleMode.FREE], ["Linear", 11, AWCurve.HandleMode.LINEAR],
			["Balanced", 12, AWCurve.HandleMode.BALANCED], ["Mirrored", 13, AWCurve.HandleMode.MIRRORED]]:
		_menu.add_radio_check_item(pair[0], pair[1])
		_menu.set_item_checked(-1, current == pair[2])
		_menu.set_item_disabled(-1, not has_sel)
	_menu.add_item("Smooth", 20)
	_menu.set_item_disabled(-1, not has_sel)
	_menu.add_item("Ease (Flat Handles)", 21)
	_menu.set_item_disabled(-1, not has_sel)
	_menu.add_separator()
	_menu.add_item("Select All Keys", 25)
	_menu.add_item("Frame Curves", 30)
	if _menu_curve:
		_menu.add_separator(chain().curve_label(_menu_curve))
		_menu.add_item("Unsolo" if doc.solo_curve == _menu_curve else "Solo", 40)
		_menu.add_item("Mute", 41)
		_menu.add_item("Edit LFO…" if _menu_curve.lfo else "LFO…", 44)
		if _menu_curve.lfo:
			_menu.add_item("Remove LFO", 45)
		_menu.add_item("Remove Curve", 43)
	_menu.add_item("Show All Curves", 42)
	AWTheme.popup_at(_menu, self, pos)


func _on_menu(id: int) -> void:
	match id:
		1:
			insert_key_at(_menu_pos)
		2:
			delete_selected_keys()
		10, 11, 12, 13:
			var mode: int = [AWCurve.HandleMode.FREE, AWCurve.HandleMode.LINEAR, AWCurve.HandleMode.BALANCED, AWCurve.HandleMode.MIRRORED][id - 10]
			var op := func(keys: Array, i: int) -> void:
				var had_handles: bool = keys[i]["in"] != Vector2.ZERO or keys[i]["out"] != Vector2.ZERO
				keys[i]["mode"] = mode
				if mode != AWCurve.HandleMode.LINEAR and not had_handles:
					AWCurveMath.smooth(keys, i)
					keys[i]["mode"] = mode
				if mode == AWCurve.HandleMode.MIRRORED:
					keys[i]["in"] = -(keys[i]["out"] as Vector2)
			_apply_to_selected(op, "Set Handle Mode")
		20:
			_apply_to_selected(func(keys: Array, i: int) -> void: AWCurveMath.smooth(keys, i), "Smooth Keys")
		21:
			_apply_to_selected(func(keys: Array, i: int) -> void: AWCurveMath.flatten(keys, i), "Ease Keys")
		25:
			select_all_keys()
		30:
			doc.frame_curves()
		40:
			doc.toggle_solo(_menu_curve)
		41:
			doc.toggle_mute(_menu_curve)
		42:
			doc.show_all_curves()
		43:
			doc.remove_curve(chain(), _menu_curve)
		44:
			doc.open_lfo(chain(), _menu_curve)
		45:
			doc.remove_lfo(_menu_curve)


# --- Drawing ------------------------------------------------------------------

func _draw() -> void:
	var c_text := AWTheme.text(self)
	var c_acc := AWTheme.accent(self)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 2
	draw_rect(Rect2(Vector2.ZERO, size), AWTheme.bg(self))
	AWTheme.draw_time_grid(self, view, 0.0, size.y)
	var ch := chain()
	_draw_value_grid(ch, c_text)

	if ch == null:
		_center_hint("Select a clip to see its effect chain and curves.", c_text)
		return
	var x0 := local_to_x(0.0)
	var x1 := local_to_x(doc.curve_domain_len())
	draw_rect(Rect2(0, 0, maxf(x0, 0.0), size.y), Color(0, 0, 0, 0.22))
	draw_rect(Rect2(x1, 0, maxf(size.x - x1, 0.0), size.y), Color(0, 0, 0, 0.22))

	if ch.curves.is_empty():
		_center_hint("No curves yet. Right-click a parameter in the effect chain > Make Curve.", c_text)
	else:
		var order: Array[AWCurve] = []
		for c in ch.curves:
			if doc.is_curve_visible(c) and c != doc.active_curve:
				order.append(c)
		if doc.active_curve and doc.is_curve_visible(doc.active_curve):
			order.append(doc.active_curve)
		for c in order:
			_draw_curve(ch, c, x0, x1, c_text)

	_draw_lfo_overlay(ch, c_text)

	var end_sec := doc.export_end_sec()
	if end_sec > 0.0:
		AWTheme.draw_export_end(self, view.time_to_x(doc.project_to_view(end_sec)), 0.0, size.y, false, doc.project.export_end_is_auto())

	var px := view.time_to_x(doc.project_to_view(doc.playhead_sec))
	draw_line(Vector2(px, 0), Vector2(px, size.y), c_acc, 2.0)

	if _drag == Drag.MARQUEE:
		draw_rect(_marquee, Color(c_acc, 0.12))
		draw_rect(_marquee, Color(c_acc, 0.8), false, 1.0)

	if _hover_curve and _drag == Drag.NONE and ch.curves.has(_hover_curve):
		var t := clampf(x_to_local(_hover_pos.x), 0.0, doc.curve_domain_len())
		var e := ch.effect_of(_hover_curve)
		var label := "%s: %s" % [ch.curve_label(_hover_curve), AWEffectLibrary.format_value(e.effect_type, _hover_curve.param, ch.sample(_hover_curve, t))]
		var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var at := _hover_pos + Vector2(12, -10)
		at.x = minf(at.x, size.x - sz.x - 10.0)
		at.y = clampf(at.y, sz.y + 4.0, size.y - 4.0)
		draw_rect(Rect2(at - Vector2(5, sz.y), sz + Vector2(10, 6)), Color(0, 0, 0, 0.75))
		draw_rect(Rect2(at - Vector2(5, sz.y), Vector2(3, sz.y + 6)), _hover_curve.color)
		draw_string(font, at + Vector2(2, 0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c_text)


## Horizontal lines at the selected curve's axis ticks; plain quarters when none is selected.
func _draw_value_grid(ch: AWChain, c_text: Color) -> void:
	var c := doc.active_curve
	if ch and c and ch.curves.has(c) and doc.is_curve_visible(c):
		for t: Array in AWCurveAxis.ticks(ch, c, _plot_h()):
			var y := roundf(val_to_y(c, t[0])) + 0.5
			draw_line(Vector2(0, y), Vector2(size.x, y), Color(c.color, 0.10))
		for n: float in [0.0, 1.0]:
			var y2 := roundf(val_to_y(c, n)) + 0.5
			draw_line(Vector2(0, y2), Vector2(size.x, y2), Color(c_text, 0.08))
		return
	for i in 5:
		var y := roundf(PAD_Y + _plot_h() * i / 4.0) + 0.5
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(c_text, 0.08 if i % 4 == 0 else 0.04))


## Draws a curve as a polyline, one point every `step` pixels. The heights come from one
## native call (AWSampler), not a GDScript call per pixel.
func _draw_samples(c: AWCurve, unit: int, xs: float, xe: float, col: Color, width: float, step := 2.0) -> void:
	var px := PackedFloat32Array()
	var times := PackedFloat64Array()
	var x := xs
	while x < xe:
		px.append(x)
		times.append(x_to_local(x))
		x += step
	px.append(xe)
	times.append(x_to_local(xe))
	if px.size() < 2:
		return
	var vals := AWSampler.values_at(chain(), c, times, unit)
	var pts := PackedVector2Array()
	pts.resize(px.size())
	for i in px.size():
		pts[i] = Vector2(px[i], val_to_y(c, vals[i]))
	draw_polyline(pts, col, width, true)


## While the LFO panel is open: Max/Min lines across the LFO's span and a "depth" strip
## along the top showing the fade in / fade out.
func _draw_lfo_overlay(ch: AWChain, c_text: Color) -> void:
	var c := doc.lfo_curve
	if c == null or not ch.curves.has(c) or c.lfo == null:
		return
	var l := c.lfo
	var col := c.color.lightened(0.2)
	var xa := local_to_x(l.start_sec)
	var xb := local_to_x(l.end_sec)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 3
	for v: float in [l.max_value, l.min_value]:
		var y := val_to_y(c, ch.to_norm(c, v))
		draw_dashed_line(Vector2(xa, y), Vector2(xb, y), Color(col, 0.85 if l.enabled else 0.35), 1.0, 5.0)
	var hi := maxf(l.max_value, l.min_value)
	var lo := minf(l.max_value, l.min_value)
	draw_string(font, Vector2(xa + 6, val_to_y(c, ch.to_norm(c, hi)) - 4), "Max", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 0.9))
	draw_string(font, Vector2(xa + 6, val_to_y(c, ch.to_norm(c, lo)) + fs + 2), "Min", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 0.9))
	if not l.enabled:
		return
	var f := l.fades()
	var top := 2.0
	var bot := PAD_Y + 8.0
	var poly := PackedVector2Array([Vector2(xa, bot), Vector2(local_to_x(l.start_sec + f.x), top),
		Vector2(local_to_x(l.end_sec - f.y), top), Vector2(xb, bot)])
	draw_colored_polygon(poly, Color(c.color, 0.22))
	var outline := poly.duplicate()
	outline.append(poly[0])
	draw_polyline(outline, Color(col, 0.8), 1.0, true)
	var mid := (xa + xb) * 0.5
	draw_string(font, Vector2(mid - 60, bot - 4), "LFO depth", HORIZONTAL_ALIGNMENT_CENTER, 120, fs, Color(c_text, 0.7))


func _center_hint(t: String, c_text: Color) -> void:
	var font := get_theme_default_font()
	draw_string(font, Vector2(0, size.y * 0.5), t, HORIZONTAL_ALIGNMENT_CENTER, size.x, get_theme_default_font_size(), Color(c_text, 0.45))


func _draw_curve(ch: AWChain, c: AWCurve, x0: float, x1: float, c_text: Color) -> void:
	var editable := doc.is_curve_editable(c)
	var active := c == doc.active_curve
	var col := c.color if editable else Color(c.color, 0.3)
	var width := 2.5 if active else (1.75 if editable else 1.5)
	if c == _hover_curve and not active:
		width += 0.75
	var xs := maxf(x0, 0.0)
	var xe := minf(x1, size.x)
	var has_lfo := ch.has_active_lfo(c)
	if has_lfo:
		# The drawn curve (its keys) stays visible as a faint guide under the LFO result.
		_draw_samples(c, AWSampler.BASE_NORM, xs, xe, Color(col, col.a * 0.4), 1.25)
	var step := 1.0 if has_lfo else 2.0
	_draw_samples(c, AWSampler.NORM, xs, xe, col, width, step)
	if not editable:
		return
	var keys := ch.get_keys(c)
	for i in keys.size():
		var kp := key_pos(c, keys[i])
		var sel := active and selected_keys.has(i)
		if sel and keys[i].mode != AWCurve.HandleMode.LINEAR:
			for which: String in ["in", "out"]:
				if (keys[i][which] as Vector2) != Vector2.ZERO:
					var hp := handle_pos(c, keys[i], which)
					draw_line(kp, hp, Color(c_text, 0.6), 1.0, true)
					draw_circle(hp, HANDLE_R, c_text)
					draw_arc(hp, HANDLE_R, 0, TAU, 12, Color(0, 0, 0, 0.6), 1.0, true)
		var r := KEY_R + (1.0 if sel else 0.0)
		var diamond := PackedVector2Array([kp + Vector2(0, -r), kp + Vector2(r, 0), kp + Vector2(0, r), kp + Vector2(-r, 0)])
		draw_colored_polygon(diamond, c_text if sel else (c.color if active else c.color.darkened(0.2)))
		diamond.append(diamond[0])
		draw_polyline(diamond, Color(0, 0, 0, 0.7), 1.0, true)
