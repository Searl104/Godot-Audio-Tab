@tool
class_name AWCompressorPanel
extends AWPlotKnobPanel
## Compressor: the transfer curve (dB in to dB out) with a draggable threshold, and six knobs.

var _thr: AWParamBinding


func make_plot() -> Control:
	_thr = bind("threshold", AWCurve.Scale.LINEAR)
	var p := AWTransferPlot.new()
	p.accent = accent()
	p.x_min = -60.0
	p.x_max = 0.0
	p.y_min = -60.0
	p.y_max = 12.0
	p.grid_step = 12.0
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
	var thr := live("threshold")
	var ratio := live("ratio")
	var makeup := live("gain")
	var mix := live("mix")
	p.fn = func(x: float) -> float: return AWFxCurves.compressor_db(x, thr, ratio, makeup, mix)
	p.handle = {"x": thr, "y": AWFxCurves.compressor_db(thr, thr, ratio, makeup, mix), "driven": _thr.has_curve()}
	p.queue_redraw()
