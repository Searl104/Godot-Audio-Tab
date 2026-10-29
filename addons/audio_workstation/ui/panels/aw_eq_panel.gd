@tool
class_name AWEQPanel
extends AWEffectPanel
## EQ detail panel: the six-band response with a draggable handle per band, and a
## fader column under each band with its own value and curve dot.

const VIEW_DB := 24.0

var plot: AWResponsePlot
var faders: Array[AWFader] = []
var selected := 3
var _bindings: Array[AWParamBinding] = []
var _values: Array[Label] = []
var _freq_labels: Array[Label] = []
var _keys: Array[String] = []


func build() -> void:
	_keys.assign(AWEffectLibrary.param_schema(effect.effect_type).keys())
	add_theme_constant_override("separation", 8)
	plot = AWResponsePlot.new()
	plot.accent = accent()
	plot.db_min = -VIEW_DB
	plot.db_max = VIEW_DB
	plot.db_step = 12.0
	plot.vertical_only = true
	plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plot.custom_minimum_size = Vector2(320, 150)
	plot.handle_pressed.connect(_on_press)
	plot.handle_moved.connect(_on_move)
	plot.handle_released.connect(_on_release)
	add_child(plot)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 6)
	add_child(cols)
	for i in _keys.size():
		var b := bind(_keys[i], AWCurve.Scale.LINEAR)
		_bindings.append(b)
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		var fl := Label.new()
		fl.text = b.label
		fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(fl)
		_freq_labels.append(fl)
		var fd := AWFader.new()
		fd.setup(b, accent(), -VIEW_DB, VIEW_DB)
		fd.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		fd.touched.connect(_select.bind(i))
		faders.append(fd)
		col.add_child(fd)
		var vl := Label.new()
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(vl)
		_values.append(vl)
		cols.add_child(col)


func _select(i: int) -> void:
	selected = i
	refresh()


func _gains() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	for b in _bindings:
		g.append(b.live_value())
	return g


func refresh() -> void:
	var g := _gains()
	var sr := AudioServer.get_mix_rate()
	plot.response = AWFilterResponse.sample_log(func(f: float) -> float: return AWFilterResponse.eq_db(f, g, sr), 240)
	var hs := []
	for i in 6:
		hs.append({"f": AWFilterResponse.EQ_FREQS[i], "db": clampf(g[i], -VIEW_DB, VIEW_DB), "driven": _bindings[i].has_curve(), "selected": i == selected})
	plot.handles = hs
	plot.queue_redraw()
	for i in 6:
		faders[i].selected = i == selected
		faders[i].refresh()
		var driven := _bindings[i].has_curve()
		_values[i].text = "%+.1f dB" % g[i]
		_values[i].add_theme_color_override("font_color", AWFader.DRIVEN if driven else AWTheme.text(self))
		_freq_labels[i].add_theme_color_override("font_color", Color.WHITE if i == selected else Color(AWTheme.text(self), 0.7))


func _on_press(i: int) -> void:
	selected = i
	if _bindings[i].has_curve():
		_bindings[i].select_curve()
	else:
		_bindings[i].begin()
	refresh()


func _on_move(i: int, _f: float, db: float, fine: bool) -> void:
	if not _bindings[i].dragging:
		return
	_bindings[i].preview(snappedf(db, _bindings[i].step))
	plot.bubble_text = "%s   %s" % [_bindings[i].label, _bindings[i].text(_bindings[i].value())]
	refresh()


func _on_release(i: int) -> void:
	_bindings[i].commit()
	plot.bubble_text = ""
	refresh()
