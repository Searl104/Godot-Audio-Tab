@tool
class_name AWOverview
extends Control
## A thin map of the whole sound above the clip grid: every clip as a small bar on its row, the
## markers, the playhead, and the visible part of the timeline as a box. Click or drag to move the
## view there; drag the box's edges to zoom.

const H := 26.0
const EDGE := 5.0

var doc: AWDocument
var view: AWTimeView
var _mode := ""
var _grab := 0.0


func setup(p_doc: AWDocument) -> void:
	doc = p_doc
	view = doc.timeline_view


func _ready() -> void:
	custom_minimum_size.y = H
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "Overview: click or drag to move the view; drag the box's edges to zoom."
	view.changed.connect(queue_redraw)
	doc.project_changed.connect(func(_s: bool) -> void: queue_redraw())
	doc.playhead_changed.connect(queue_redraw)
	doc.selection_changed.connect(queue_redraw)


## Seconds shown across the whole strip.
func total() -> float:
	return maxf(doc.project.content_end_sec() + 0.5, view.x_to_time(view.view_width) + 0.1)


func t_to_x(t: float) -> float:
	return t / total() * size.x


func x_to_t(x: float) -> float:
	return x / maxf(size.x, 1.0) * total()


func window() -> Vector2:
	return Vector2(t_to_x(view.x_to_time(0.0)), t_to_x(view.x_to_time(view.view_width)))


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			var w := window()
			if absf(mb.position.x - w.x) <= EDGE:
				_mode = "left"
			elif absf(mb.position.x - w.y) <= EDGE:
				_mode = "right"
			elif mb.position.x > w.x and mb.position.x < w.y:
				_mode = "move"
				_grab = mb.position.x - w.x
			else:
				_mode = "move"
				_grab = (w.y - w.x) * 0.5
				_move_to(mb.position.x)
		else:
			_mode = ""
		accept_event()
	var mm := event as InputEventMouseMotion
	if mm and _mode != "":
		match _mode:
			"move":
				_move_to(mm.position.x)
			"left", "right":
				var w := window()
				var a := x_to_t(mm.position.x if _mode == "left" else w.x)
				var b := x_to_t(mm.position.x if _mode == "right" else w.y)
				if b - a > 0.01:
					view.frame_exact(a, b)
		accept_event()


func _move_to(x: float) -> void:
	var left_t := x_to_t(x - _grab)
	view.scroll_to(maxf(0.0, (left_t - view.min_time) * view.pixels_per_sec))


func _draw() -> void:
	var c_text := AWTheme.text(self)
	var acc := AWTheme.accent(self)
	draw_rect(Rect2(Vector2.ZERO, size), AWTheme.bg(self).darkened(0.25))
	var rows := maxi(doc.project.max_row() + 1, 1)
	var lane := (size.y - 4.0) / rows
	for c in doc.project.clips:
		var x0 := t_to_x(c.start_sec)
		var x1 := t_to_x(c.end_sec())
		var col := c.color if doc.project.is_clip_audible(c) else Color(0.5, 0.5, 0.5, 0.5)
		if doc.is_selected(c):
			col = col.lightened(0.35)
		draw_rect(Rect2(x0, 2.0 + c.row * lane, maxf(x1 - x0, 1.0), maxf(lane - 1.0, 1.0)), col)
	for m in doc.project.markers:
		var mx := t_to_x(m.time_sec)
		draw_line(Vector2(mx, 0), Vector2(mx, size.y), Color(AWTimeRuler.MARKER_COLOR, 0.8))
	var ex := t_to_x(doc.export_end_sec())
	draw_line(Vector2(ex, 0), Vector2(ex, size.y), Color(AWTheme.EXPORT_END, 0.8))
	var px := t_to_x(doc.playhead_sec)
	draw_line(Vector2(px, 0), Vector2(px, size.y), acc, 1.5)
	var w := window()
	var box := Rect2(w.x, 0.5, maxf(w.y - w.x, 3.0), size.y - 1.0)
	draw_rect(box, Color(c_text, 0.08))
	draw_rect(box, Color(c_text, 0.7), false, 1.0)
	draw_line(Vector2(0, size.y - 0.5), Vector2(size.x, size.y - 0.5), Color(0, 0, 0, 0.5))
