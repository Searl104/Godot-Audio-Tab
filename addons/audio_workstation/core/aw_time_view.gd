@tool
class_name AWTimeView
extends RefCounted
## Horizontal zoom/scroll state for one time axis (seconds). The clip timeline and
## the curve graph each have one.

signal changed

const MIN_PPS := 20.0
const MAX_PPS := 40000.0
const TICK_STEPS := [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]

var pixels_per_sec := 200.0
var scroll_x := 0.0
var view_width := 600.0
## Lowest time the view may scroll to (negative lets clip-time graphs show lead-in).
var min_time := 0.0
## Callable() -> float: furthest time worth scrolling to.
var content_end: Callable = func() -> float: return 10.0


func time_to_x(t: float) -> float:
	return (t - min_time) * pixels_per_sec - scroll_x


func x_to_time(x: float) -> float:
	return (x + scroll_x) / pixels_per_sec + min_time


func scroll_range() -> float:
	return (content_end.call() - min_time) * pixels_per_sec + view_width * 0.5


func zoom_by(factor: float, anchor_x := -1.0) -> void:
	if anchor_x < 0.0:
		anchor_x = view_width * 0.5
	var t := x_to_time(anchor_x)
	pixels_per_sec = clampf(pixels_per_sec * factor, MIN_PPS, MAX_PPS)
	scroll_x = (t - min_time) * pixels_per_sec - anchor_x
	_clamp()
	changed.emit()


## Sets the zoom so that time `t` sits at x = anchor_x.
func set_scale_at(pps: float, anchor_x: float, t: float) -> void:
	pixels_per_sec = clampf(pps, MIN_PPS, MAX_PPS)
	scroll_x = (t - min_time) * pixels_per_sec - anchor_x
	_clamp()
	changed.emit()


func scroll_to(px: float) -> void:
	scroll_x = px
	_clamp()
	changed.emit()


func scroll_by(px: float) -> void:
	scroll_to(scroll_x + px)


## Shows exactly [t0, t1] across the view (no margin).
func frame_exact(t0: float, t1: float) -> void:
	var span := maxf(t1 - t0, 0.001)
	pixels_per_sec = clampf(view_width / span, MIN_PPS, MAX_PPS)
	scroll_x = (t0 - min_time) * pixels_per_sec
	_clamp()
	changed.emit()


## Fits [t0, t1] in the view with a small margin.
func frame(t0: float, t1: float) -> void:
	var span := maxf(t1 - t0, 0.01)
	pixels_per_sec = clampf(view_width * 0.92 / span, MIN_PPS, MAX_PPS)
	scroll_x = (t0 - min_time) * pixels_per_sec - view_width * 0.04
	_clamp()
	changed.emit()


func set_view_width(w: float) -> void:
	if is_equal_approx(w, view_width):
		return
	view_width = maxf(w, 1.0)
	_clamp()
	changed.emit()


func _clamp() -> void:
	scroll_x = clampf(scroll_x, 0.0, maxf(0.0, scroll_range() - view_width))


## Ctrl+wheel zooms, Shift+wheel or horizontal wheel scrolls. Plain wheel zooms only if
## `plain_zooms` is set. Returns true if the event was used.
func handle_wheel(event: InputEventMouseButton, local_x: float, plain_zooms := false) -> bool:
	var idx := event.button_index
	var is_h := idx == MOUSE_BUTTON_WHEEL_LEFT or idx == MOUSE_BUTTON_WHEEL_RIGHT
	var is_v := idx == MOUSE_BUTTON_WHEEL_UP or idx == MOUSE_BUTTON_WHEEL_DOWN
	if not (is_h or is_v):
		return false
	var zoom := (event.ctrl_pressed or event.meta_pressed or plain_zooms) and is_v and not event.shift_pressed
	if not (zoom or event.shift_pressed or is_h):
		return false
	if event.pressed:
		var up := idx == MOUSE_BUTTON_WHEEL_UP or idx == MOUSE_BUTTON_WHEEL_LEFT
		var amount := event.factor if event.factor > 0.0 else 1.0
		if zoom:
			zoom_by(pow(1.15, amount) if up else pow(1.0 / 1.15, amount), local_x)
		else:
			scroll_by((-60.0 if up else 60.0) * amount)
	return true


## Largest label step that keeps labels at least `min_px` apart.
func label_step(min_px := 70.0) -> float:
	for s: float in TICK_STEPS:
		if s * pixels_per_sec >= min_px:
			return s
	return TICK_STEPS.back()


static func format_time(t: float, step: float) -> String:
	var sign := "-" if t < -0.0000001 else ""
	t = absf(t)
	if t >= 60.0:
		return "%s%d:%04.1f" % [sign, int(t / 60.0), fmod(t, 60.0)]
	var decimals := 3 if step < 0.01 else (2 if step < 0.1 else (1 if step < 1.0 else 0))
	return sign + String.num(t, decimals) + "s"
