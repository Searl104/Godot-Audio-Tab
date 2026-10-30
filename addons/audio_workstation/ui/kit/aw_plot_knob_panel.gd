@tool
class_name AWPlotKnobPanel
extends AWEffectPanel
## Shared layout for panels that are "a plot plus knobs": the full version is a tall plot over a
## row of knobs, the compact (card) version a small plot over a 3-wide knob grid. Subclasses give
## knob_keys(), make_plot() and update_plot().

var knobs: Array[AWKnob] = []
var _plot: Control


func knob_keys() -> Array:
	return AWEffectLibrary.param_schema(effect.effect_type).keys()


## dB params are linear knobs; Hz / us / ms params with a positive minimum are logarithmic.
func knob_scale(key: String) -> int:
	var spec := AWEffectLibrary.param_spec(effect.effect_type, key)
	if spec[4] == "dB":
		return AWCurve.Scale.LINEAR
	if (spec[4] == "Hz" or spec[4] == "µs" or spec[4] == "ms") and float(spec[0]) > 0.0:
		return AWCurve.Scale.LOG
	return AWCurve.Scale.LINEAR


func make_plot() -> Control:
	return null


func update_plot() -> void:
	pass


func plot_control() -> Control:
	return _plot


func build() -> void:
	add_theme_constant_override("separation", 6 if compact else 10)
	_plot = make_plot()
	if _plot:
		_plot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if compact else Control.SIZE_EXPAND_FILL
		_plot.custom_minimum_size = Vector2(0, 44) if compact else Vector2(300, 170)
		if compact:
			_plot.set("mini", true)
			_plot.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(_plot)
	var holder: Container
	if compact:
		var grid := GridContainer.new()
		grid.columns = 3
		holder = grid
	else:
		var flow := HFlowContainer.new()
		flow.alignment = FlowContainer.ALIGNMENT_CENTER
		holder = flow
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(holder)
	for key: String in knob_keys():
		var k := AWKnob.new()
		k.setup(bind(key, knob_scale(key)), accent(), 36 if compact else 64)
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL if compact else Control.SIZE_SHRINK_CENTER
		knobs.append(k)
		holder.add_child(k)


func refresh() -> void:
	for k in knobs:
		k.refresh()
	update_plot()


func live(key: String) -> float:
	return bind(key).live_value()
