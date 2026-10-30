@tool
class_name AWDelayPanel
extends AWPlotKnobPanel
## Delay: the dry signal and the echo train (time, level, feedback), and four knobs.


func make_plot() -> Control:
	var p := AWEchoPlot.new()
	p.accent = accent()
	return p


func update_plot() -> void:
	var p := _plot as AWEchoPlot
	p.delay_ms = live("tap1_delay_ms")
	p.level_db = live("tap1_level_db")
	p.feedback_db = live("feedback_level_db")
	p.dry = live("dry")
	p.queue_redraw()
