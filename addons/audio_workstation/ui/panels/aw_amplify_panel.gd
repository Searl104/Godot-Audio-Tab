@tool
class_name AWAmplifyPanel
extends AWEffectPanel
## Amplify: one volume knob, with the equivalent linear gain beside it.

var knob: AWKnob
var _vol: AWParamBinding
var _linear: Label


func build() -> void:
	_vol = bind("volume_db")
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	add_child(row)
	knob = AWKnob.new()
	knob.setup(_vol, accent(), 48 if compact else 96)
	row.add_child(knob)
	if not compact:
		_linear = Label.new()
		_linear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(_linear)


func refresh() -> void:
	knob.refresh()
	if _linear:
		_linear.text = "x %.3f" % db_to_linear(_vol.live_value())
