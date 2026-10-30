@tool
class_name AWReverbPanel
extends AWPlotKnobPanel
## Reverb: how long the tail lasts (and how fast the highs go), plus five knobs.


func make_plot() -> Control:
	var p := AWDecayPlot.new()
	p.accent = accent()
	return p


func update_plot() -> void:
	var p := _plot as AWDecayPlot
	p.room = live("room_size")
	p.damping = live("damping")
	p.queue_redraw()
