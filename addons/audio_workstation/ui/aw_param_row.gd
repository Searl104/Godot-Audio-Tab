@tool
class_name AWParamRow
extends HBoxContainer
## One parameter in an effect card: [dot] Label [slider + field] or [curve value].
## No curve: edit the static value. Right-click > Make Curve sends it to the graph.
## With a curve: the dot cycles On / Dim / Off (Shift+click solos); the row shows the
## curve's value at the playhead.

var doc: AWDocument
var chain: AWChain
var effect: AWEffect
var param: String

var _dot: Control
var _label: Label
var _slider: HSlider
var _spin: SpinBox
var _curve_value: Label
var _menu: PopupMenu
var _drag_orig := 0.0
var _dragging := false


func setup(p_doc: AWDocument, p_chain: AWChain, p_effect: AWEffect, p_param: String) -> void:
	doc = p_doc
	chain = p_chain
	effect = p_effect
	param = p_param


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var spec := AWEffectLibrary.param_spec(effect.effect_type, param)

	_dot = Control.new()
	_dot.custom_minimum_size = Vector2(18, 18)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.mouse_filter = Control.MOUSE_FILTER_STOP
	_dot.draw.connect(_draw_dot)
	_dot.gui_input.connect(_on_dot_input)
	add_child(_dot)

	_label = Label.new()
	_label.text = spec[5]
	_label.custom_minimum_size.x = 78
	_label.clip_text = true
	_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_label.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_label)

	_slider = HSlider.new()
	_slider.min_value = spec[0]
	_slider.max_value = spec[1]
	_slider.step = spec[3]
	_slider.exp_edit = AWEffectLibrary.default_scale(effect.effect_type, param) == AWCurve.Scale.LOG
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.custom_minimum_size.x = 50
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.drag_started.connect(func() -> void:
		_dragging = true
		_drag_orig = effect.get_param(param))
	_slider.value_changed.connect(func(v: float) -> void:
		if _dragging:
			doc.preview_param(effect, param, v)
		else:
			doc.set_param(effect, param, v))
	_slider.drag_ended.connect(func(_changed: bool) -> void:
		_dragging = false
		var now := effect.get_param(param)
		doc.preview_param(effect, param, _drag_orig)
		doc.set_param(effect, param, now))
	add_child(_slider)

	_spin = SpinBox.new()
	_spin.min_value = spec[0]
	_spin.max_value = spec[1]
	_spin.step = spec[3]
	_spin.custom_minimum_size.x = 74
	_spin.select_all_on_focus = true
	_spin.tooltip_text = spec[4]
	_spin.value_changed.connect(func(v: float) -> void: doc.set_param(effect, param, v))
	add_child(_spin)

	_curve_value = Label.new()
	_curve_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_curve_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_curve_value.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_curve_value)

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	refresh()


func curve() -> AWCurve:
	return chain.get_curve(effect.id, param)


func refresh() -> void:
	var c := curve()
	var has_curve := c != null
	_slider.visible = not has_curve
	_spin.visible = not has_curve
	_curve_value.visible = has_curve
	if has_curve:
		var local := doc.chain_local_time(chain, doc.playhead_sec)
		local = clampf(local, 0.0, doc.curve_domain_len())
		var kind := "lfo  " if chain.has_active_lfo(c) else "curve  "
		_curve_value.text = kind + AWEffectLibrary.format_value(effect.effect_type, param, chain.sample(c, local))
		_curve_value.tooltip_text = c.lfo.summary(effect.effect_type, param) if c.lfo else ""
		_curve_value.add_theme_color_override("font_color", c.color.lightened(0.15) if c.display != AWCurve.Display.OFF else Color(c.color, 0.5))
		_dot.tooltip_text = "Click: cycle On / Dim / Off   Shift+click: solo   Right-click: more"
	else:
		var v := effect.get_param(param)
		if not _dragging:
			_slider.set_value_no_signal(v)
		if not _spin.get_line_edit().has_focus():
			_spin.set_value_no_signal(v)
		_dot.tooltip_text = "Right-click > Make Curve to automate this parameter"
	tooltip_text = "Right-click for curve options"
	_dot.queue_redraw()


func _draw_dot() -> void:
	var c := curve()
	var soloing := doc.solo_curve != null and chain.curves.has(doc.solo_curve)
	var shown: int = c.display if c else 0
	if c and soloing and c != doc.solo_curve:
		shown = AWCurve.Display.OFF
	AWTheme.draw_param_dot(_dot, _dot.size * 0.5, 6.0, c.color if c else Color.GRAY, c != null, shown,
		c != null and c == doc.solo_curve, c != null and c == doc.active_curve)
	if c and c.lfo and c.lfo.enabled and shown != AWCurve.Display.OFF:
		AWTheme.draw_lfo_badge(_dot, _dot.size * 0.5, 6.0)


func _on_dot_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	var mb := event as InputEventMouseButton
	var c := curve()
	if mb.button_index == MOUSE_BUTTON_LEFT and c:
		if mb.shift_pressed:
			doc.toggle_solo(c)
		else:
			doc.cycle_curve_display(c)
		_dot.accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		_open_menu(_dot.position + mb.position)
		_dot.accept_event()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_open_menu(mb.position)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and curve():
			doc.set_active_curve(curve())
			accept_event()


func _open_menu(pos: Vector2) -> void:
	var c := curve()
	_menu.clear()
	if c == null:
		_menu.add_item("Make Curve", 1)
		_menu.add_item("Add LFO…", 20)
		_menu.add_item("Reset to Default", 3)
	else:
		_menu.add_item("Select Curve", 4)
		_menu.add_radio_check_item("On", 10)
		_menu.set_item_checked(-1, c.display == AWCurve.Display.ON)
		_menu.add_radio_check_item("Dim", 11)
		_menu.set_item_checked(-1, c.display == AWCurve.Display.DIM)
		_menu.add_radio_check_item("Off", 12)
		_menu.set_item_checked(-1, c.display == AWCurve.Display.OFF)
		_menu.add_separator()
		_menu.add_item("Unsolo" if doc.solo_curve == c else "Solo", 5)
		_menu.add_item("Unmute" if c.display == AWCurve.Display.OFF else "Mute", 6)
		_menu.add_item("Show All Curves", 7)
		_menu.add_separator()
		_menu.add_item("Edit LFO…" if c.lfo else "LFO…", 21)
		if c.lfo:
			_menu.add_item("Remove LFO", 22)
		_menu.add_item("Remove Curve", 2)
	AWTheme.popup_at(_menu, self, pos)


func _on_menu(id: int) -> void:
	var c := curve()
	match id:
		1: doc.make_curve(chain, effect, param)
		2: doc.remove_curve(chain, c)
		3: doc.set_param(effect, param, AWEffectLibrary.param_spec(effect.effect_type, param)[2])
		4:
			if c.display != AWCurve.Display.ON:
				doc.set_curve_display(c, AWCurve.Display.ON)
			doc.set_active_curve(c)
		5: doc.toggle_solo(c)
		6: doc.toggle_mute(c)
		7: doc.show_all_curves()
		10, 11, 12: doc.set_curve_display(c, (id - 10) as AWCurve.Display)
		20: doc.open_lfo(chain, doc.make_curve(chain, effect, param))
		21: doc.open_lfo(chain, c)
		22: doc.remove_lfo(c)
