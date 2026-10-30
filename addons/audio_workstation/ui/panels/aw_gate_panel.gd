@tool
class_name AWGatePanel
extends AWPlotKnobPanel
## Noise Gate: level in vs level out with a draggable threshold, and six knobs.

var _thr: AWParamBinding


func make_plot() -> Control:
	_thr = bind("threshold_db", AWCurve.Scale.LINEAR)
	var p := AWTransferPlot.new()
	p.accent = accent()
	p.x_min = -80.0
	p.x_max = 0.0
	p.y_min = -80.0
	p.y_max = 0.0
	p.grid_step = 20.0
	if not compact:
		p.handle_pressed.connect(func() -> void:
			if _thr.has_curve():
				_thr.select_curve()
			else:
				_thr.begin())
		p.handle_moved.connect(func(x: float, _y: float) -> void:
			if _thr.dragging:
				_thr.preview(snappedf(x, _thr.step))
				(_plot as AWTransferPlot).bubble_text = "Threshold %s" % _thr.text(_thr.value())
				refresh())
		p.handle_released.connect(func() -> void:
			_thr.commit()
			(_plot as AWTransferPlot).bubble_text = ""
			refresh())
	return p


func update_plot() -> void:
	var p := _plot as AWTransferPlot
	var thr := live("threshold_db")
	var rng := live("range_db")
	p.fn = func(x: float) -> float: return AWFxCurves.gate_db(x, thr, rng)
	p.handle = {"x": thr, "y": thr, "driven": _thr.has_curve()}
	p.queue_redraw()
