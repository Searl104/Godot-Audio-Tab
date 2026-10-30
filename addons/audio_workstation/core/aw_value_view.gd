@tool
class_name AWValueView
extends RefCounted
## Vertical zoom/scroll of the curve layer. Curve heights are 0..1 on each curve's own scale;
## the view shows [lo, lo + span] of that range (span 1 = everything).

signal changed

const MIN_SPAN := 0.02

var lo := 0.0
var span := 1.0


func hi() -> float:
	return lo + span


func reset() -> void:
	set_range(0.0, 1.0)


## Shows [a, b] (clamped into 0..1, at least MIN_SPAN tall).
func set_range(a: float, b: float) -> void:
	var s := clampf(b - a, MIN_SPAN, 1.0)
	var l := clampf(a, 0.0, 1.0 - s)
	if is_equal_approx(l, lo) and is_equal_approx(s, span):
		return
	lo = l
	span = s
	changed.emit()


## Zooms keeping the value at the top edge fixed (factor > 1 = closer).
func zoom_top(factor: float) -> void:
	var top := hi()
	var s := clampf(span / maxf(factor, 1e-6), MIN_SPAN, 1.0)
	set_range(top - s, top)


## Zooms keeping value `anchor` at the same place on screen.
func zoom_at(factor: float, anchor: float) -> void:
	var s := clampf(span / maxf(factor, 1e-6), MIN_SPAN, 1.0)
	var k := (anchor - lo) / span
	set_range(anchor - k * s, anchor - k * s + s)


## Scrolls by `d` in 0..1 units (positive = up, toward higher values).
func scroll_by(d: float) -> void:
	set_range(lo + d, lo + d + span)
