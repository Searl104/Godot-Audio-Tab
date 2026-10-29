@tool
class_name AWLfoPanel
extends PanelContainer
## The LFO panel, docked beside the curve graph while open (right-click a curve > LFO…).
## Shape, Max, Min, Freq, Fade In, Fade Out. Every change is undoable; slider drags preview
## live and commit as one step.

const WIDTH := 300.0

var doc: AWDocument

var _body: VBoxContainer
var _curve: AWCurve = null
var _chain: AWChain = null
var _refreshers: Array[Callable] = []
var _rebuild_queued := false


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	custom_minimum_size.x = WIDTH
	var style := StyleBoxFlat.new()
	style.bg_color = AWTheme.color(self, &"base_color", Color(0.17, 0.19, 0.23))
	style.border_color = Color(0, 0, 0, 0.45)
	style.border_width_left = 1
	style.set_content_margin_all(12)
	add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	scroll.add_child(_body)
	doc.lfo_panel_changed.connect(_queue_rebuild)
	doc.project_changed.connect(func(structural: bool) -> void:
		if structural or (_curve and _curve.lfo == null):
			_queue_rebuild()
		else:
			for r in _refreshers:
				r.call())
	_rebuild()


func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	_refreshers.clear()
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	_curve = doc.lfo_curve
	_chain = doc.active_chain()
	visible = _curve != null and _chain != null and _chain.curves.has(_curve) and _curve.lfo != null
	if not visible:
		return
	var l := _curve.lfo
	var e := _chain.effect_of(_curve)
	var spec := AWEffectLibrary.param_spec(e.effect_type, _curve.param)
	var col := _curve.color

	# Header: wave mark, "LFO", curve name, On, close.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	var mark := _ShapeIcon.new()
	mark.shape = AWLfo.Shape.SINE
	mark.color = col
	mark.custom_minimum_size = Vector2(22, 18)
	header.add_child(mark)
	var title := Label.new()
	title.text = "LFO"
	title.add_theme_font_size_override("font_size", get_theme_default_font_size() + 2)
	header.add_child(title)
	var name_label := Label.new()
	name_label.text = _chain.curve_label(_curve)
	name_label.add_theme_color_override("font_color", col.lightened(0.3))
	name_label.clip_text = true
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)
	var on := CheckBox.new()
	on.text = "On"
	on.focus_mode = Control.FOCUS_NONE
	on.button_pressed = l.enabled
	on.toggled.connect(func(v: bool) -> void: doc.set_props(l, {"enabled": v}, "Toggle LFO"))
	_refreshers.append(func() -> void: on.set_pressed_no_signal(l.enabled))
	header.add_child(on)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.tooltip_text = "Close the LFO panel (the LFO stays on)"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(doc.close_lfo)
	header.add_child(close)
	_body.add_child(header)

	# Shape
	_body.add_child(_section("SHAPE"))
	var shapes := HBoxContainer.new()
	shapes.add_theme_constant_override("separation", 4)
	var group := ButtonGroup.new()
	var shape_buttons: Array[Button] = []
	for i in AWLfo.SHAPE_NAMES.size():
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = AWLfo.SHAPE_NAMES[i] + (" (sample and hold)" if i == AWLfo.Shape.RANDOM else "")
		b.custom_minimum_size = Vector2(0, 30)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var on_style := StyleBoxFlat.new()
		on_style.bg_color = col.darkened(0.6)
		on_style.border_color = col
		on_style.set_border_width_all(1)
		on_style.set_corner_radius_all(4)
		b.add_theme_stylebox_override("pressed", on_style)
		b.add_theme_stylebox_override("hover_pressed", on_style)
		var icon := _ShapeIcon.new()
		icon.shape = i
		icon.color = col.lightened(0.25)
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(icon)
		b.pressed.connect(func() -> void: doc.set_props(l, {"shape": i}, "LFO Shape"))
		shapes.add_child(b)
		shape_buttons.append(b)
	var sync_shape := func() -> void:
		for i in shape_buttons.size():
			shape_buttons[i].set_pressed_no_signal(i == l.shape)
	sync_shape.call()
	_refreshers.append(sync_shape)
	_body.add_child(shapes)

	# Values
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	var log_param := _curve.scale == AWCurve.Scale.LOG
	var unit: String = spec[4]
	_row(grid, "Max", l, "max_value", spec[0], spec[1], spec[3], unit, log_param)
	_row(grid, "Min", l, "min_value", spec[0], spec[1], spec[3], unit, log_param)
	_row(grid, "Freq", l, "freq_hz", 0.05, 20.0, 0.01, "Hz", true)
	var span := maxf(l.span(), 0.01)
	_row(grid, "Fade In", l, "fade_in_sec", 0.0, span, 0.01, "s", false)
	_row(grid, "Fade Out", l, "fade_out_sec", 0.0, span, 0.01, "s", false)
	_body.add_child(grid)

	var note := AWTheme.dim_label("Freq runs on the clip's clock, so it slows down when Pitch drops. The fades blend from the drawn curve into the LFO and back.", 0.6)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", get_theme_default_font_size() - 2)
	_body.add_child(note)

	var footer := HBoxContainer.new()
	var bake := Button.new()
	bake.text = "Bake to Keys"
	bake.tooltip_text = "Replace the LFO with ordinary keys you can edit"
	bake.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake.pressed.connect(func() -> void: doc.bake_lfo(_chain, _curve))
	var remove := Button.new()
	remove.text = "Remove LFO"
	remove.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	remove.add_theme_color_override("font_color", Color("#f0a0a0"))
	remove.pressed.connect(func() -> void: doc.remove_lfo(_curve))
	footer.add_child(bake)
	footer.add_child(remove)
	_body.add_child(footer)


func _section(t: String) -> Label:
	var l := AWTheme.dim_label(t, 0.6)
	l.add_theme_font_size_override("font_size", get_theme_default_font_size() - 3)
	return l


## Label | slider | field, bound to an LFO property with live preview + one undo per drag.
func _row(grid: GridContainer, label_text: String, l: AWLfo, prop: String, lo: float, hi: float,
		step: float, unit: String, exp: bool) -> void:
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 62
	grid.add_child(label)

	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.exp_edit = exp and lo > 0.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.focus_mode = Control.FOCUS_NONE
	slider.name = prop + "_slider"
	var state := {"dragging": false, "orig": 0.0}
	slider.drag_started.connect(func() -> void:
		state.dragging = true
		state.orig = l.get(prop))
	slider.value_changed.connect(func(v: float) -> void:
		if state.dragging:
			doc.preview_set(l, {prop: v})
		else:
			doc.set_props(l, {prop: v}, "Edit LFO " + label_text))
	slider.drag_ended.connect(func(_changed: bool) -> void:
		state.dragging = false
		doc.commit_drags([[l, {prop: state.orig}]], "Edit LFO " + label_text))
	grid.add_child(slider)

	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = step
	spin.suffix = unit
	spin.custom_minimum_size.x = 84
	spin.select_all_on_focus = true
	spin.name = prop + "_field"
	spin.value_changed.connect(func(v: float) -> void: doc.set_props(l, {prop: v}, "Edit LFO " + label_text))
	grid.add_child(spin)

	var sync := func() -> void:
		var v: float = l.get(prop)
		if not state.dragging:
			slider.set_value_no_signal(v)
		if not spin.get_line_edit().has_focus():
			spin.set_value_no_signal(v)
	sync.call()
	_refreshers.append(sync)


## Small wave drawing used for the shape buttons and the header mark.
class _ShapeIcon extends Control:
	var shape := 0
	var color := Color.WHITE

	func _draw() -> void:
		var w := minf(size.x - 8.0, 30.0)
		var h := minf(size.y - 10.0, 12.0)
		var o := (size - Vector2(w, h)) * 0.5
		var pts := PackedVector2Array()
		match shape:
			AWLfo.Shape.SINE:
				for i in 25:
					var x := i / 24.0
					pts.append(o + Vector2(x * w, (0.5 - 0.5 * sin(x * TAU)) * h))
			AWLfo.Shape.TRIANGLE:
				for p: Vector2 in [Vector2(0, 1), Vector2(0.25, 0), Vector2(0.5, 1), Vector2(0.75, 0), Vector2(1, 1)]:
					pts.append(o + p * Vector2(w, h))
			AWLfo.Shape.SQUARE:
				for p: Vector2 in [Vector2(0, 1), Vector2(0, 0), Vector2(0.5, 0), Vector2(0.5, 1), Vector2(1, 1), Vector2(1, 0)]:
					pts.append(o + p * Vector2(w, h))
			AWLfo.Shape.SAW:
				for p: Vector2 in [Vector2(0, 1), Vector2(0.5, 0), Vector2(0.5, 1), Vector2(1, 0), Vector2(1, 1)]:
					pts.append(o + p * Vector2(w, h))
			AWLfo.Shape.RANDOM:
				for p: Vector2 in [Vector2(0, 0.7), Vector2(0.22, 0.7), Vector2(0.22, 0.1), Vector2(0.45, 0.1), Vector2(0.45, 0.9), Vector2(0.68, 0.9), Vector2(0.68, 0.35), Vector2(1, 0.35)]:
					pts.append(o + p * Vector2(w, h))
		draw_polyline(pts, color, 1.6, true)
