@tool
class_name AWScaleBar
extends Control
## A scrollbar whose thumb ends are scale handles, so a mouse without a middle button (or a
## trackpad) can zoom as well as scroll:
##   drag the middle of the thumb: scroll;
##   drag either end of the thumb: zoom that axis (the opposite end stays put);
##   double-click the thumb: fit that axis;
##   click the track: page toward the click.
## Positions are in the owner's units (seconds, pixels, values); the owner applies the
## change and calls set_state() with what it actually shows.

signal scrolled(start: float)
signal range_changed(start: float, end: float)
signal fit_requested

const THICK := 12.0
const GRIP := 8.0
const MIN_THUMB := 26.0

enum Drag { NONE, MOVE, START, END }

var vertical := false

var total_start := 0.0
var total_end := 1.0
var page_start := 0.0
var page_end := 1.0

var _drag := Drag.NONE
var _press_u := 0.0
var _press_page := Vector2.ZERO
var _hover := Drag.NONE


func _init(p_vertical := false) -> void:
	vertical = p_vertical


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	if vertical:
		custom_minimum_size = Vector2(THICK, 0)
		size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		custom_minimum_size = Vector2(0, THICK)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tooltip_text = "Drag the bar to scroll, its ends to zoom; double-click it to fit"
	mouse_exited.connect(func() -> void:
		_hover = Drag.NONE
		queue_redraw())


func set_state(t0: float, t1: float, p0: float, p1: float) -> void:
	total_start = minf(t0, p0)
	total_end = maxf(maxf(t1, p1), total_start + 1e-6)
	page_start = p0
	page_end = maxf(p1, p0)
	queue_redraw()


func _len() -> float:
	return maxf(size.y if vertical else size.x, 1.0)


func _u_to_px(u: float) -> float:
	return (u - total_start) / (total_end - total_start) * _len()


func _px_to_u(px: float) -> float:
	return total_start + px / _len() * (total_end - total_start)


## Thumb [start px, end px], widened to MIN_THUMB around its centre when tiny.
func thumb_px() -> Vector2:
	var a := _u_to_px(page_start)
	var b := _u_to_px(page_end)
	if b - a < MIN_THUMB:
		var m := (a + b) * 0.5
		a = clampf(m - MIN_THUMB * 0.5, 0.0, maxf(_len() - MIN_THUMB, 0.0))
		b = a + MIN_THUMB
	return Vector2(a, b)


func _axis(p: Vector2) -> float:
	return p.y if vertical else p.x


## What the mouse is over: START / END grips, MOVE (the thumb), or NONE (the track).
func part_at(p: Vector2) -> Drag:
	var x := _axis(p)
	var th := thumb_px()
	if x < th.x - 2.0 or x > th.y + 2.0:
		return Drag.NONE
	if x <= th.x + GRIP:
		return Drag.START
	if x >= th.y - GRIP:
		return Drag.END
	return Drag.MOVE


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			var part := part_at(mb.position)
			if mb.double_click and part != Drag.NONE:
				_drag = Drag.NONE
				fit_requested.emit()
			elif part == Drag.NONE:
				# Page toward the click.
				var page := page_end - page_start
				var dir := 1.0 if _px_to_u(_axis(mb.position)) > page_end else -1.0
				scrolled.emit(page_start + dir * page * 0.9)
			else:
				_drag = part
				_press_u = _px_to_u(_axis(mb.position))
				_press_page = Vector2(page_start, page_end)
		else:
			_drag = Drag.NONE
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm == null:
		return
	if _drag == Drag.NONE:
		var h := part_at(mm.position)
		if h != _hover:
			_hover = h
			queue_redraw()
		var resize := Control.CURSOR_VSIZE if vertical else Control.CURSOR_HSIZE
		mouse_default_cursor_shape = resize if h in [Drag.START, Drag.END] else Control.CURSOR_ARROW
		return
	var u := _px_to_u(_axis(mm.position))
	var du := u - _press_u
	var min_span := (total_end - total_start) * MIN_THUMB / _len()
	match _drag:
		Drag.MOVE:
			scrolled.emit(_press_page.x + du)
		Drag.START:
			range_changed.emit(clampf(_press_page.x + du, minf(total_start, _press_page.x), _press_page.y - min_span), _press_page.y)
		Drag.END:
			range_changed.emit(_press_page.x, maxf(_press_page.y + du, _press_page.x + min_span))
	accept_event()


func _draw() -> void:
	var c_text := AWTheme.text(self)
	var c_acc := AWTheme.accent(self)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.18))
	var th := thumb_px()
	var r := Rect2(th.x, 2.0, th.y - th.x, size.y - 4.0) if not vertical else Rect2(2.0, th.x, size.x - 4.0, th.y - th.x)
	var active := _drag != Drag.NONE or _hover != Drag.NONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(c_text, 0.32 if active else 0.2)
	sb.set_corner_radius_all(3)
	draw_style_box(sb, r)
	# Grips at both ends (scale handles).
	for end in 2:
		var hot := (_hover == Drag.START and end == 0) or (_hover == Drag.END and end == 1) \
			or (_drag == Drag.START and end == 0) or (_drag == Drag.END and end == 1)
		var col := c_acc if hot else Color(c_text, 0.55)
		var at := th.x + 3.5 if end == 0 else th.y - 3.5
		for k in 2:
			var o := at + (k * 2.0 - 1.0) * 1.5
			if vertical:
				draw_line(Vector2(3.5, o), Vector2(size.x - 3.5, o), col, 1.0)
			else:
				draw_line(Vector2(o, 3.5), Vector2(o, size.y - 3.5), col, 1.0)
