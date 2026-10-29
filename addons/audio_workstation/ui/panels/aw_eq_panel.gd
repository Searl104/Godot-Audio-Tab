@tool
class_name AWEQPanel
extends AWEffectPanel
## EQ panel: the six-band response, and a knob per band. In the dock the plot has a
## draggable handle per band; on the card (compact) it is a small preview over 2x3 knobs.

const VIEW_DB := 18.0

var knobs: Array[AWKnob] = []
var selected := 3
var _bindings: Array[AWParamBinding] = []
var _keys: Array[String] = []


func build() -> void:
	_keys.assign(AWEffectLibrary.param_schema(effect.effect_type).keys())
	add_theme_constant_override("separation", 6 if compact else 8)
	plot = AWResponsePlot.new()
	plot.accent = accent()
	plot.db_min = -VIEW_DB
	plot.db_max = VIEW_DB
	plot.db_step = 6.0 if not compact else 12.0
	plot.vertical_only = true
	if compact:
		plot.mini = true
		plot.custom_minimum_size.y = 44
		plot.mouse_filter = Control.MOUSE_FILTER_PASS
	else:
		plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		plot.custom_minimum_size = Vector2(320, 150)
		plot.handle_pressed.connect(_on_press)
		plot.handle_moved.connect(_on_move)
		plot.handle_released.connect(_on_release)
	add_child(plot)

	var per_row := 3 if compact else 6
	var grid := GridContainer.new()
	grid.columns = per_row
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(grid)
	for i in _keys.size():
		var b := bind(_keys[i], AWCurve.Scale.LINEAR)
		_bindings.append(b)
		var k := AWKnob.new()
		k.setup(b, accent(), 36 if compact else 56)
		k.view_min = -VIEW_DB
		k.view_max = VIEW_DB
		k.bipolar = true
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		k.touched.connect(_select.bind(i))
		knobs.append(k)
		grid.add_child(k)


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
	plot.response = AWFilterResponse.sample_log(func(f: float) -> float: return AWFilterResponse.eq_db(f, g, sr), 120 if compact else 240)
	if not compact:
		var hs := []
		for i in 6:
			hs.append({"f": AWFilterResponse.EQ_FREQS[i], "db": clampf(g[i], -VIEW_DB, VIEW_DB), "driven": _bindings[i].has_curve(), "selected": i == selected})
		plot.handles = hs
	plot.queue_redraw()
	for k in knobs:
		k.refresh()


func _on_press(i: int) -> void:
	selected = i
	if _bindings[i].has_curve():
		_bindings[i].select_curve()
	else:
		_bindings[i].begin()
	refresh()


func _on_move(i: int, _f: float, db: float, _fine: bool) -> void:
	if not _bindings[i].dragging:
		return
	_bindings[i].preview(snappedf(db, _bindings[i].step))
	plot.bubble_text = "%s   %s" % [_bindings[i].label, _bindings[i].text(_bindings[i].value())]
	refresh()


func _on_release(i: int) -> void:
	_bindings[i].commit()
	plot.bubble_text = ""
	refresh()
