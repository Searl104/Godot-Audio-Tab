@tool
class_name AWDistortionPanel
extends AWPlotKnobPanel
## Distortion: the waveshaper curve (input level to output level) and four knobs.


func make_plot() -> Control:
	var p := AWTransferPlot.new()
	p.accent = accent()
	p.x_min = -1.0
	p.x_max = 1.0
	p.y_min = -1.0
	p.y_max = 1.0
	p.grid_step = 0.5
	return p


func update_plot() -> void:
	var p := _plot as AWTransferPlot
	var drive := live("drive")
	var pre := live("pre_gain")
	var post := live("post_gain")
	p.fn = func(x: float) -> float: return AWFxCurves.distortion(x, drive, pre, post)
	p.queue_redraw()
