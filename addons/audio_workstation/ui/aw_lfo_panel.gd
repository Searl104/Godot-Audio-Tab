@tool
class_name AWLfoPanel
extends VBoxContainer
## Content of the "Audio LFO" dock, laid out as one column so it suits a tall, narrow dock: the open
## LFO (waveform preview, shape, Absolute / Relative, knobs for Freq, Accel, Max / Min or Depth, Phase,
## Fade In, Fade Out, Smoothing, Jitter, Jit Depth, Glide and Decay),
## then every LFO in the project as "Clip 2\\Low Pass\\Cutoff"; click one to jump to it. Every change is undoable; knob drags
## preview live and commit as one step.

var doc: AWDocument

var _editor: VBoxContainer
var _list: VBoxContainer
var _curve: AWCurve = null
var _chain: AWChain = null
var _refreshers: Array[Callable] = []
var _rebuild_queued := false
var _list_sig := ""
var knobs := {}
var list_buttons: Array[Button] = []


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	custom_minimum_size = Vector2(250, 200)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	scroll.add_child(col)
	_editor = VBoxContainer.new()
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor.add_theme_constant_override("separation", 8)
	col.add_child(_editor)
	col.add_child(HSeparator.new())
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_list)
	doc.lfo_panel_changed.connect(_queue_rebuild)
	doc.project_changed.connect(func(structural: bool) -> void:
		if structural or (_curve and _curve.lfo == null) or _list_sig != _signature():
			_queue_rebuild()
		else:
			for r in _refreshers:
				r.call())
	_rebuild()


func _signature() -> String:
	var parts := PackedStringArray()
	for e: Dictionary in doc.all_lfos():
		parts.append(e["label"])
	return "|".join(parts)


func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	_refreshers.clear()
	knobs.clear()
	list_buttons.clear()
	for box: Control in [_editor, _list]:
		for c in box.get_children():
			box.remove_child(c)
			c.queue_free()
	_curve = doc.lfo_curve
	_chain = doc.active_chain()
	var editing := _curve != null and _chain != null and _chain.curves.has(_curve) and _curve.lfo != null
	if editing:
		_build_editor()
	else:
		_curve = null
		var hint := AWTheme.dim_label("Pick an LFO from the list, or right-click a curve or parameter > LFO…", 0.6)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.custom_minimum_size.x = 200
		_editor.add_child(hint)
	_build_list()


func _build_editor() -> void:
	var l := _curve.lfo
	var e := _chain.effect_of(_curve)
	var spec := AWEffectLibrary.param_spec(e.effect_type, _curve.param)
	var col := _curve.color

	# Header: wave mark, "LFO", curve name, On.
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
	_editor.add_child(header)
	var actions := HBoxContainer.new()
	var bake := Button.new()
	bake.text = "Bake to Keys"
	bake.tooltip_text = "Replace the LFO with ordinary keys you can edit"
	bake.focus_mode = Control.FOCUS_NONE
	bake.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake.pressed.connect(func() -> void: doc.bake_lfo(_chain, _curve))
	actions.add_child(bake)
	var remove := Button.new()
	remove.text = "Remove"
	remove.tooltip_text = "Remove the LFO from this curve"
	remove.focus_mode = Control.FOCUS_NONE
	remove.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	remove.add_theme_color_override("font_color", Color("#f0a0a0"))
	remove.pressed.connect(func() -> void: doc.remove_lfo(_curve))
	actions.add_child(remove)
	_editor.add_child(actions)

	# Waveform preview and shape buttons.
	var left := _editor
	var preview := _Preview.new()
	preview.lfo = l
	preview.color = col
	preview.custom_minimum_size.y = 84
	_refreshers.append(preview.queue_redraw)
	left.add_child(preview)
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
	left.add_child(shapes)

	# Absolute (swing between Min and Max) or Relative (wobble around the drawn curve).
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 2)
	var mgroup := ButtonGroup.new()
	var mode_buttons: Array[Button] = []
	for m: Array in [[AWLfo.Mode.ABSOLUTE, "Absolute", "Swing between Min and Max, replacing the drawn curve while it runs"],
			[AWLfo.Mode.RELATIVE, "Relative", "Wobble ±Depth around the drawn curve, so the curve's own movement stays"]]:
		var mb := Button.new()
		mb.text = m[1]
		mb.tooltip_text = m[2]
		mb.toggle_mode = true
		mb.button_group = mgroup
		mb.focus_mode = Control.FOCUS_NONE
		mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mb.name = "Mode" + m[1]
		var mv: int = m[0]
		mb.pressed.connect(func() -> void: doc.set_props(l, {"mode": mv}, "LFO Mode"))
		modes.add_child(mb)
		mode_buttons.append(mb)
	left.add_child(modes)

	# Knobs wrap to the dock's width.
	var flow := HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	flow.add_theme_constant_override("h_separation", 2)
	flow.add_theme_constant_override("v_separation", 2)
	_editor.add_child(flow)
	var span := maxf(l.span(), 0.01)
	var vmax := AWParamBinding.for_property(doc, l, "max_value", "Max", spec[0], spec[1], spec[3], spec[1], spec[4], _curve.scale)
	var vmin := AWParamBinding.for_property(doc, l, "min_value", "Min", spec[0], spec[1], spec[3], spec[0], spec[4], _curve.scale)
	for b: AWParamBinding in [vmax, vmin]:
		b.like_effect = e.effect_type
		b.like_param = _curve.param
	var freq := AWParamBinding.for_property(doc, l, "freq_hz", "Freq", 0.05, 20.0, 0.01, 4.0, "Hz", AWCurve.Scale.LOG)
	var accel := AWParamBinding.for_property(doc, l, "freq_accel", "Accel", -25.0, 25.0, 0.001, 0.0, "mHz/s")
	accel.unit_factor = 1000.0
	accel.power = 3.0
	var fin := AWParamBinding.for_property(doc, l, "fade_in_sec", "Attack", 0.0, span, 0.01, 0.25, "s")
	fin.tooltip = "Attack: how long the swing takes to rise from nothing to full."
	var fout := AWParamBinding.for_property(doc, l, "fade_out_sec", "Release", 0.0, span, 0.01, 0.25, "s")
	fout.tooltip = "Release: the swing fades out over the last part of the LFO's span, from whatever level it is at."
	var sus := AWParamBinding.for_property(doc, l, "sustain", "Sustain", 0.0, 1.0, 0.01, 1.0, "%")
	sus.unit_factor = 100.0
	sus.tooltip = "Sustain: the level the swing holds after Decay, until Release."
	var smooth := AWParamBinding.for_property(doc, l, "fade_smoothing", "Smoothing", 0.0, 1.0, 0.01, 0.0)
	smooth.tooltip = "0 = straight fade ramps, 1 = fully eased"
	var depth := AWParamBinding.for_property(doc, l, "depth", "Depth", 0.0, 1.0, 0.001, 0.1, "%")
	depth.unit_factor = 100.0
	depth.power = 2.0
	depth.tooltip = "Relative mode: the wobble goes ± this share of the parameter's range around the drawn curve."
	var phase := AWParamBinding.for_property(doc, l, "phase_deg", "Phase", 0.0, 360.0, 1.0, 0.0, "°")
	phase.tooltip = "Where the cycle starts when the LFO begins."
	var jrate := AWParamBinding.for_property(doc, l, "jitter_rate", "Jitter", 0.0, 1.0, 0.01, 0.0, "%")
	jrate.unit_factor = 100.0
	jrate.tooltip = "Randomizes the length of each cycle (100% = about ±50%). Uses the seed."
	var jdepth := AWParamBinding.for_property(doc, l, "jitter_depth", "Jit Depth", 0.0, 1.0, 0.01, 0.0, "%")
	jdepth.unit_factor = 100.0
	jdepth.tooltip = "Randomizes the height of each cycle. Uses the seed."
	var glide := AWParamBinding.for_property(doc, l, "glide", "Glide", 0.0, 1.0, 0.01, 0.0, "%")
	glide.unit_factor = 100.0
	glide.tooltip = "Softens the jumps of Square, Saw and Random. At 100% Square becomes a sine and Random a smooth drift."
	var decay := AWParamBinding.for_property(doc, l, "decay_sec", "Decay", 0.0, 240.0, 0.01, 0.0, "s")
	decay.power = 3.0
	decay.tooltip = "Decay: after the Attack peak, the swing falls to the Sustain level over this time. 0 = straight to Sustain."
	accel.tooltip = "How fast the frequency changes, in milli-Hz per second (1000 = 1 Hz every second). Fine near the middle, wide at the ends. Negative slows down and stops at 0 Hz."
	for b: AWParamBinding in [freq, accel, vmax, vmin, depth, phase, fin, decay, sus, fout, smooth, jrate, jdepth, glide]:
		var k := AWKnob.new()
		k.setup(b, col, 48)
		k.bipolar = b.prop == "freq_accel"
		k.name = b.prop + "_knob"
		knobs[b.prop] = k
		flow.add_child(k)
		_refreshers.append(func() -> void:
			if b.prop.begins_with("fade_") and b.prop != "fade_smoothing":
				b.hi = maxf(l.span(), 0.01)
			k.refresh())
	var sync_mode := func() -> void:
		var rel := l.mode == AWLfo.Mode.RELATIVE
		mode_buttons[0].set_pressed_no_signal(not rel)
		mode_buttons[1].set_pressed_no_signal(rel)
		knobs["max_value"].visible = not rel
		knobs["min_value"].visible = not rel
		knobs["depth"].visible = rel
	sync_mode.call()
	_refreshers.append(sync_mode)

	var note := AWTheme.dim_label("Freq runs on the clip's clock, so it slows down when Pitch drops. Accel drifts the frequency over time. Attack, Decay, Sustain and Release shape how much of the LFO is heard (Release takes the last part of its span); Smoothing eases them. Jitter and Jit Depth make each cycle a little different. Double-click a knob to type a value.", 0.6)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 200
	note.add_theme_font_size_override("font_size", get_theme_default_font_size() - 2)
	_editor.add_child(note)


## "ALL LFOS": one line per LFO in the project, "Clip 2\\Low Pass\\Cutoff". Click to jump to it.
func _build_list() -> void:
	var all := doc.all_lfos()
	_list_sig = _signature()
	_list.add_child(_section("ALL LFOS (%d)" % all.size()))
	if all.is_empty():
		var none := AWTheme.dim_label("None yet. Right-click a parameter or curve > Add LFO…", 0.6)
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		none.custom_minimum_size.x = 200
		_list.add_child(none)
		return
	for entry: Dictionary in all:
		var b := AWPathButton.new()
		b.set_path(entry["label"])
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		var c: AWCurve = entry["curve"]
		b.add_theme_color_override("font_color", c.color.lightened(0.2))
		b.toggle_mode = true
		b.button_pressed = c == _curve
		b.pressed.connect(func() -> void: doc.goto_lfo(entry))
		list_buttons.append(b)
		_list.add_child(b)


func _section(t: String) -> Label:
	var l := AWTheme.dim_label(t, 0.6)
	l.add_theme_font_size_override("font_size", get_theme_default_font_size() - 3)
	return l


## Waveform over the first few cycles, shaped by the fades (how much LFO is heard).
class _Preview extends Control:
	var lfo: AWLfo
	var color := Color.WHITE

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.25), true)
		if lfo == null or lfo.span() <= 0.0:
			return
		var t4 := lfo.time_of_phase(4.0) - lfo.start_sec # time to four cycles (INF if it never gets there)
		var window := minf(lfo.span(), (t4 if is_finite(t4) else lfo.span()) + lfo.fade_in_sec + lfo.fade_out_sec)
		if lfo.decay_sec > 0.0:
			window = minf(lfo.span(), maxf(window, lfo.decay_sec * 3.0))
		window = maxf(window, 0.05)
		var pad := 6.0
		var h := size.y - pad * 2.0
		draw_line(Vector2(0, size.y * 0.5), Vector2(size.x, size.y * 0.5), Color(1, 1, 1, 0.12), 1.0)
		var pts := PackedVector2Array()
		var n := 180
		for i in n + 1:
			var t := window * float(i) / n
			var ts := lfo.start_sec + t
			var amp := lfo.envelope(ts)
			var y := 0.5 + 0.5 * lfo.swing(ts) * amp
			pts.append(Vector2(size.x * float(i) / n, pad + (1.0 - y) * h))
		draw_polyline(pts, color, 1.6, true)
		for fx: float in [lfo.fades().x, window - lfo.fades().y]:
			if fx > 0.0 and fx < window:
				draw_dashed_line(Vector2(size.x * fx / window, 0), Vector2(size.x * fx / window, size.y), Color(1, 1, 1, 0.25), 1.0, 3.0)


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
