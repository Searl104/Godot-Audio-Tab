@tool
class_name AWLowPassPanel
extends AWEffectPanel
## Low Pass detail panel: live response plot with a draggable cutoff/resonance handle,
## two knobs and Q / peak / slope readouts. Also used for High Pass (same parameters).

var plot: AWResponsePlot
var cutoff_knob: AWKnob
var res_knob: AWKnob
var _cutoff: AWParamBinding
var _res: AWParamBinding
var _readouts := {}
var _group: Array = []


func build() -> void:
	_cutoff = bind("cutoff_hz")
	_res = bind("resonance")
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	plot = AWResponsePlot.new()
	plot.accent = accent()
	plot.db_min = -36.0
	plot.db_max = 24.0
	plot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	cutoff_knob = AWKnob.new()
	cutoff_knob.setup(_cutoff, accent(), 72)
	side.add_child(cutoff_knob)
	res_knob = AWKnob.new()
	res_knob.setup(_res, accent(), 72)
	side.add_child(res_knob)
	for k in ["Q", "Peak", "Slope"]:
		var r := HBoxContainer.new()
		var l := AWTheme.dim_label(k)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(l)
		var v := Label.new()
		r.add_child(v)
		_readouts[k] = v
		side.add_child(r)


func _sr() -> float:
	return AudioServer.get_mix_rate()


func refresh() -> void:
	var fc := _cutoff.live_value()
	var res := _res.live_value()
	var sr := _sr()
	plot.response = AWFilterResponse.sample_log(func(f: float) -> float: return AWFilterResponse.lowpass_db(f, fc, res, sr), 220)
	var peak := AWFilterResponse.lowpass_db(fc, fc, res, sr)
	plot.handles = [{"f": fc, "db": peak, "driven": _cutoff.has_curve() or _res.has_curve()}]
	var c := _cutoff.curve()
	plot.sweep = _curve_range(c)
	plot.queue_redraw()
	cutoff_knob.refresh()
	res_knob.refresh()
	_readouts["Q"].text = "%.2f" % AWFilterResponse.resonance_to_q(res)
	_readouts["Peak"].text = "%+.1f dB" % peak
	_readouts["Slope"].text = "12 dB / oct"


## Frequency range a cutoff curve sweeps (its extremes), or zero when there is none.
func _curve_range(c: AWCurve) -> Vector2:
	if c == null:
		return Vector2.ZERO
	var lo := INF
	var hi := -INF
	var span := doc.curve_domain_len()
	for i in 41:
		var v := chain.sample(c, span * float(i) / 40.0)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return Vector2(lo, hi)


func _on_press(_i: int) -> void:
	_group = []
	for b: AWParamBinding in [_cutoff, _res]:
		if not b.has_curve():
			b.begin()
			_group.append(b)
	if _group.is_empty():
		_cutoff.select_curve()


func _on_move(_i: int, f: float, db: float, fine: bool) -> void:
	if _group.has(_cutoff):
		_cutoff.preview(snappedf(f, _cutoff.step))
	if _group.has(_res):
		var q := pow(10.0, db / 20.0)
		_res.preview(snappedf(AWFilterResponse.q_to_resonance(q), _res.step))
	plot.bubble_text = "%s   %s" % [_cutoff.text(_cutoff.value()), "Q %.2f" % AWFilterResponse.resonance_to_q(_res.value())]
	refresh()


func _on_release(_i: int) -> void:
	AWParamBinding.commit_many(_group, "Edit " + effect.effect_type)
	_group = []
	plot.bubble_text = ""
	refresh()
