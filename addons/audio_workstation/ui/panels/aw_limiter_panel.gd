@tool
class_name AWLimiterPanel
extends AWPlotKnobPanel
## Limiter: input to output level, flat at the ceiling (drag the handle up or down to move it).

var _ceil: AWParamBinding


func make_plot() -> Control:
	_ceil = bind("ceiling_db", AWCurve.Scale.LINEAR)
	var p := AWTransferPlot.new()
	p.accent = accent()
	p.x_min = -36.0
	p.x_max = 6.0
	p.y_min = -36.0
	p.y_max = 6.0
	p.grid_step = 6.0
	if not compact:
		p.handle_pressed.connect(func() -> void:
			if _ceil.has_curve():
				_ceil.select_curve()
			else:
				_ceil.begin())
		p.handle_moved.connect(func(_x: float, y: float) -> void:
			if _ceil.dragging:
				_ceil.preview(snappedf(y, _ceil.step))
				(_plot as AWTransferPlot).bubble_text = "Ceiling %s" % _ceil.text(_ceil.value())
				refresh())
		p.handle_released.connect(func() -> void:
			_ceil.commit()
			(_plot as AWTransferPlot).bubble_text = ""
			refresh())
	return p


func update_plot() -> void:
	var p := _plot as AWTransferPlot
	var pre := live("pre_gain_db")
	var ceil := live("ceiling_db")
	p.fn = func(x: float) -> float: return AWFxCurves.limiter_db(x, pre, ceil)
	p.handle = {"x": ceil - pre, "y": ceil, "driven": _ceil.has_curve()}
	p.queue_redraw()
