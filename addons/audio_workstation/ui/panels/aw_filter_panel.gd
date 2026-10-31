@tool
class_name AWFilterPanel
extends AWEffectPanel
## Filter card panel (and the legacy Low Pass / High Pass / Band Pass cards): live response plot
## with a draggable handle, knobs and Q / peak / slope readouts.
## The Filter card adds a Type drop-down (Low Pass, High Pass, Band Pass, Notch, Low Shelf, High
## Shelf, Peak), a continuous Slope (6 to 48 dB/oct, pass and notch types) and Gain (shelves and peak).
## Band pass and notch have 0 dB at their centre, so the handle's vertical drag changes resonance
## relatively; shelves and peak drag their gain.

var cutoff_knob: AWKnob
var res_knob: AWKnob
var _cutoff: AWParamBinding
var _res: AWParamBinding
var _readouts := {}
var _group: Array = []
var _drag_res := 0.0
var _drag_db := 0.0
var _drag_gain := 0.0
var _gain: AWParamBinding
var _slope: AWParamBinding
var gain_knob: AWKnob
var slope_knob: AWKnob
var type_menu: OptionButton


func is_card() -> bool:
	return effect.effect_type == "Filter"


## The Filter card's type (0..6), or the legacy card's fixed one.
func mode() -> int:
	if is_card():
		return clampi(roundi(effect.get_param("mode")), 0, 6)
	return int(AWEffectLibrary.LEGACY_FILTERS.get(effect.effect_type, 0))


func _make_type_menu() -> OptionButton:
	var ob := OptionButton.new()
	ob.name = "FilterType"
	ob.focus_mode = Control.FOCUS_NONE
	ob.fit_to_longest_item = false
	for i in AWEffectLibrary.FILTER_MODES.size():
		ob.add_item(AWEffectLibrary.FILTER_MODES[i], i)
	ob.tooltip_text = "Filter type"
	ob.item_selected.connect(func(i: int) -> void:
		if i != mode():
			doc.set_param(effect, "mode", float(i)))
	return ob


func build() -> void:
	_cutoff = bind("cutoff_hz")
	_res = bind("resonance")
	if is_card():
		_gain = bind("gain_db")
		_slope = bind("slope_db")
		type_menu = _make_type_menu()
	plot = AWResponsePlot.new()
	plot.accent = accent()
	plot.db_min = -36.0
	plot.db_max = 24.0 if not compact else 18.0
	plot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if compact:
		plot.mini = true
		plot.custom_minimum_size.y = 44
		plot.mouse_filter = Control.MOUSE_FILTER_PASS
		if type_menu:
			add_child(type_menu)
		add_child(plot)
		var krow := HBoxContainer.new()
		krow.alignment = BoxContainer.ALIGNMENT_CENTER
		add_child(krow)
		cutoff_knob = _knob(_cutoff, 44)
		res_knob = _knob(_res, 44)
		krow.add_child(cutoff_knob)
		krow.add_child(res_knob)
		if is_card():
			gain_knob = _knob(_gain, 44)
			slope_knob = _knob(_slope, 44)
			krow.add_child(gain_knob)
			krow.add_child(slope_knob)
		return
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 14)
	add_child(row)
	plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plot.custom_minimum_size = Vector2(320, 200)
	plot.handle_pressed.connect(_on_press)
	plot.handle_moved.connect(_on_move)
	plot.handle_released.connect(_on_release)
	row.add_child(plot)

	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 150
	side.add_theme_constant_override("separation", 6)
	row.add_child(side)
	if type_menu:
		side.add_child(type_menu)
	cutoff_knob = _knob(_cutoff, 72)
	res_knob = _knob(_res, 72)
	side.add_child(cutoff_knob)
	side.add_child(res_knob)
	if is_card():
		var row2 := HBoxContainer.new()
		gain_knob = _knob(_gain, 56)
		slope_knob = _knob(_slope, 56)
		row2.add_child(gain_knob)
		row2.add_child(slope_knob)
		side.add_child(row2)
	for k in ["Q", "Peak", "Slope"]:
		var title: String = k
		if k == "Slope":
			title = "Width" if effect.effect_type == "Band Pass" else ("Shape" if is_card() else "Slope")
		var r := HBoxContainer.new()
		var l := AWTheme.dim_label(title)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(l)
		var v := Label.new()
		r.add_child(v)
		_readouts[k] = v
		side.add_child(r)


func _knob(b: AWParamBinding, d: float) -> AWKnob:
	var k := AWKnob.new()
	k.setup(b, accent(), d)
	return k


func _sr() -> float:
	return AudioServer.get_mix_rate()


## Response at frequency f with the current (live) values.
func response_db(f: float) -> float:
	var sr := _sr()
	if is_card():
		return AWFilterResponse.filter_card_db(f, mode(), _cutoff.live_value(), _res.live_value(), _gain.live_value(), _slope.live_value(), sr)
	return AWFilterResponse.filter_db(effect.effect_type, f, _cutoff.live_value(), _res.live_value(), sr)


func refresh() -> void:
	var fc := _cutoff.live_value()
	var res := _res.live_value()
	var m := mode()
	plot.response = AWFilterResponse.sample_log(response_db, 220)
	var peak := response_db(fc)
	cutoff_knob.refresh()
	res_knob.refresh()
	if is_card():
		type_menu.select(m)
		gain_knob.refresh()
		slope_knob.refresh()
		gain_knob.visible = m >= 4
		slope_knob.visible = m <= 3
		res_knob.tooltip_text = "Q of the shelf / peak" if m >= 4 else ""
	if compact:
		plot.queue_redraw()
		return
	plot.handles = [{"f": fc, "db": peak, "driven": _cutoff.has_curve() or _res.has_curve()}]
	plot.sweep = _curve_range(_cutoff.curve())
	plot.queue_redraw()
	_readouts["Q"].text = "%.2f" % AWFilterResponse.resonance_to_q(res)
	_readouts["Peak"].text = "%+.1f dB" % peak
	if m == 2 or m == 3:
		var q := AWFilterResponse.resonance_to_q(res)
		_readouts["Slope"].text = "%.2f oct wide" % (2.0 * asinh(1.0 / (2.0 * q)) / log(2.0))
	elif m >= 4:
		_readouts["Slope"].text = "%+.1f dB" % _gain.live_value()
	elif is_card():
		_readouts["Slope"].text = "%.0f dB / oct" % _slope.live_value()
	else:
		_readouts["Slope"].text = "12 dB / oct"


## Frequency range a cutoff curve sweeps (its extremes), or zero when there is none.
func _curve_range(c: AWCurve) -> Vector2:
	if c == null:
		return Vector2.ZERO
	var lo := INF
	var hi := -INF
	var span := doc.curve_span_len()
	for i in 41:
		var v := chain.sample(c, span * float(i) / 40.0)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return Vector2(lo, hi)


func _on_press(_i: int) -> void:
	_drag_res = _res.value()
	_drag_db = plot.db_at(plot.press_pos.y)
	_drag_gain = _gain.value() if _gain else 0.0
	_group = []
	var vert := _gain if (is_card() and mode() >= 4) else _res
	for b: AWParamBinding in [_cutoff, vert]:
		if not b.has_curve():
			b.begin()
			_group.append(b)
	if _group.is_empty():
		_cutoff.select_curve()


func _on_move(_i: int, f: float, db: float, fine: bool) -> void:
	if _group.has(_cutoff):
		_cutoff.preview(snappedf(f, _cutoff.step))
	if _gain and _group.has(_gain):
		_gain.preview(snappedf(clampf(_drag_gain + (db - _drag_db), -24.0, 24.0), _gain.step))
	if _group.has(_res):
		if mode() == 2 or mode() == 3:
			_res.preview(snappedf(clampf(_drag_res + (db - _drag_db) / 36.0, 0.0, 1.0), _res.step))
		else:
			_res.preview(snappedf(AWFilterResponse.q_to_resonance(pow(10.0, db / 20.0)), _res.step))
	plot.bubble_text = "%s   %s" % [_cutoff.text(_cutoff.value()), "Q %.2f" % AWFilterResponse.resonance_to_q(_res.value())]
	refresh()


func _on_release(_i: int) -> void:
	AWParamBinding.commit_many(_group, "Edit " + effect.effect_type)
	_group = []
	plot.bubble_text = ""
	refresh()
