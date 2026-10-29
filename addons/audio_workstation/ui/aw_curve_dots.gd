@tool
class_name AWCurveDots
extends Control
## The dot column at the graph's left edge. One dot per curve in the active chain, placed at
## the curve's value at the left edge of the view (nudged apart if they overlap).
## Click: cycle On > Dim > Off.  Shift+click: solo.  Right-click: Solo / Mute / Show All / Remove.

const W := 26.0
const R := 6.0
const MIN_GAP := 15.0

var doc: AWDocument
var graph: AWCurveGraph

var _menu: PopupMenu
var _menu_curve: AWCurve = null
var _placed: Array = [] # [curve, Vector2]


func setup(p_doc: AWDocument, p_graph: AWCurveGraph) -> void:
	doc = p_doc
	graph = p_graph


func _ready() -> void:
	custom_minimum_size = Vector2(W, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	for s: Signal in [doc.curve_view_changed, doc.chain_target_changed, doc.curve_view.changed]:
		s.connect(queue_redraw)
	doc.project_changed.connect(func(_s: bool) -> void: queue_redraw())
	resized.connect(queue_redraw)


func _layout() -> void:
	_placed.clear()
	var ch := doc.active_chain()
	if ch == null:
		return
	var t := clampf(graph.x_to_local(0.0), 0.0, doc.curve_domain_len())
	var items := []
	for c in ch.curves:
		items.append([c, graph.val_to_y(c, ch.sample_norm(c, t))])
	items.sort_custom(func(a: Array, b: Array) -> bool: return a[1] < b[1])
	var last := -INF
	for it: Array in items:
		var y := maxf(it[1], last + MIN_GAP)
		last = y
		_placed.append([it[0], Vector2(W * 0.5, y)])
	# If the stack ran off the bottom, push it back up.
	var overflow := last - (size.y - R - 2.0)
	if overflow > 0.0:
		for p: Array in _placed:
			p[1] = (p[1] as Vector2) - Vector2(0.0, overflow)


func curve_at(pos: Vector2) -> AWCurve:
	_layout()
	for p: Array in _placed:
		if (p[1] as Vector2).distance_to(pos) <= R + 3.0:
			return p[0]
	return null


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		var c := curve_at(mb.position)
		if c == null:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.shift_pressed:
				doc.toggle_solo(c)
			else:
				doc.cycle_curve_display(c)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_open_menu(c, mb.position)
			accept_event()
	elif event is InputEventMouseMotion:
		var c := curve_at((event as InputEventMouseMotion).position)
		var ch := doc.active_chain()
		tooltip_text = "" if c == null else "%s (%s)%s\nClick: cycle On / Dim / Off\nShift+click: solo\nRight-click: more" % [
			ch.curve_label(c), ["On", "Dim", "Off"][c.display],
			("\n" + c.lfo.summary(ch.effect_of(c).effect_type, c.param)) if c.lfo else ""]
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if c else Control.CURSOR_ARROW


func _open_menu(c: AWCurve, pos: Vector2) -> void:
	_menu_curve = c
	_menu.clear()
	_menu.add_separator(doc.active_chain().curve_label(c))
	_menu.add_item("Select Curve", 1)
	_menu.add_separator()
	_menu.add_radio_check_item("On", 10)
	_menu.set_item_checked(-1, c.display == AWCurve.Display.ON)
	_menu.add_radio_check_item("Dim", 11)
	_menu.set_item_checked(-1, c.display == AWCurve.Display.DIM)
	_menu.add_radio_check_item("Off", 12)
	_menu.set_item_checked(-1, c.display == AWCurve.Display.OFF)
	_menu.add_separator()
	_menu.add_item("Unsolo" if doc.solo_curve == c else "Solo", 2)
	_menu.add_item("Unmute" if c.display == AWCurve.Display.OFF else "Mute", 3)
	_menu.add_item("Show All", 4)
	_menu.add_separator()
	_menu.add_item("Edit LFO…" if c.lfo else "LFO…", 6)
	if c.lfo:
		_menu.add_item("Remove LFO", 7)
	_menu.add_item("Remove Curve", 5)
	AWTheme.popup_at(_menu, self, pos)


func _on_menu(id: int) -> void:
	var c := _menu_curve
	match id:
		1:
			if c.display == AWCurve.Display.OFF or c.display == AWCurve.Display.DIM:
				doc.set_curve_display(c, AWCurve.Display.ON)
			doc.set_active_curve(c)
		10, 11, 12:
			doc.set_curve_display(c, (id - 10) as AWCurve.Display)
		2: doc.toggle_solo(c)
		3: doc.toggle_mute(c)
		4: doc.show_all_curves()
		5: doc.remove_curve(doc.active_chain(), c)
		6: doc.open_lfo(doc.active_chain(), c)
		7: doc.remove_lfo(c)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), AWTheme.color(self, &"dark_color_1", Color(0.16, 0.18, 0.22)))
	draw_line(Vector2(size.x - 0.5, 0), Vector2(size.x - 0.5, size.y), Color(0, 0, 0, 0.5))
	_layout()
	var soloing := doc.solo_curve != null
	for p: Array in _placed:
		var c: AWCurve = p[0]
		var shown := c.display
		if soloing and c != doc.solo_curve:
			shown = AWCurve.Display.OFF
		AWTheme.draw_param_dot(self, p[1], R, c.color, true, shown, c == doc.solo_curve, c == doc.active_curve)
		if c.lfo and c.lfo.enabled and shown != AWCurve.Display.OFF:
			AWTheme.draw_lfo_badge(self, p[1], R)
