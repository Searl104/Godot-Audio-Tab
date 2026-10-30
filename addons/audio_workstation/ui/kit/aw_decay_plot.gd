@tool
class_name AWDecayPlot
extends Control
## Reverb preview: how fast the tail fades, in dB over time. One line for the body of the sound and
## a dimmer one for the highs (damping makes them die sooner); each reaches the bottom at its RT60.

const LOOP_SEC := 0.0307 # average comb length of the engine's reverb

var accent := Color("#4fc9c0")
var room := 0.8
var damping := 0.5
var mini := false


## Seconds for the body of the tail to fall by 60 dB.
static func rt60(p_room: float, p_damping: float, highs := false) -> float:
	var fb := clampf(p_room, 0.0, 1.0) * 0.28 + 0.7
	if highs:
		var d := clampf(p_damping, 0.0, 1.0) * 0.4
		fb *= (1.0 - d) / (1.0 + d)
	return 60.0 / (-20.0 * log(fb) / log(10.0)) * LOOP_SEC


func _draw() -> void:
	var a := Rect2(Vector2.ZERO, size) if mini else Rect2(30, 8, size.x - 38, size.y - 24)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.125, 0.145, 0.17), true)
	var txt := AWTheme.text(self)
	var body := rt60(room, damping)
	var hf := rt60(room, damping, true)
	var span := clampf(body * 1.05, 0.3, 12.0)
	for k in 4:
		var y := a.position.y + a.size.y * float(k) / 3.0
		draw_line(Vector2(a.position.x, y), Vector2(a.end.x, y), Color(txt, 0.12), 1.0)
	var lines: Array = [[hf, Color(accent, 0.45)], [body, accent]]
	for l: Array in lines:
		var x1 := a.position.x + minf(float(l[0]) / span, 1.0) * a.size.x
		var y1 := a.position.y + (1.0 if float(l[0]) <= span else span / float(l[0])) * a.size.y
		draw_line(Vector2(a.position.x, a.position.y), Vector2(x1, y1), l[1], 2.0, true)
	if not mini:
		var font := get_theme_default_font()
		var fs := get_theme_default_font_size() - 3
		draw_string(font, Vector2(2, a.position.y + 10), "0 dB", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(txt, 0.5))
		draw_string(font, Vector2(2, a.end.y), "-60", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(txt, 0.5))
		draw_string(font, Vector2(a.end.x - 90, a.end.y + 14), "%.1f s" % span, HORIZONTAL_ALIGNMENT_RIGHT, 90, fs, Color(txt, 0.5))
		draw_string(font, Vector2(a.position.x + 6, a.end.y + 14), "RT60 %.1f s  (highs %.1f s)" % [body, hf], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(txt, 0.7))
