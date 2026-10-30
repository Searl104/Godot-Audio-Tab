@tool
class_name AWEchoPlot
extends Control
## Delay preview: the dry signal at time 0 and each echo as a bar (height = level) at its time.

var accent := Color("#b38bfa")
var delay_ms := 250.0
var level_db := -6.0
var feedback_db := -6.0
var dry := 1.0
var mini := false


func _draw() -> void:
	var a := Rect2(Vector2.ZERO, size) if mini else Rect2(8, 6, size.x - 16, size.y - 12)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.125, 0.145, 0.17), true)
	var txt := AWTheme.text(self)
	draw_line(Vector2(a.position.x, a.end.y), Vector2(a.end.x, a.end.y), Color(txt, 0.3), 1.0)
	var d := maxf(delay_ms, 1.0)
	var count := 12
	var span := d * (count + 0.5)
	var bar := maxf(2.0, a.size.x / (count + 1.0) * 0.18)
	var bars: Array = [[0.0, dry, true]]
	var amp := db_to_linear(level_db)
	var fb := minf(db_to_linear(feedback_db), 0.995)
	for k in count:
		bars.append([d * (k + 1), amp, false])
		amp *= fb
	for b: Array in bars:
		var x: float = a.position.x + float(b[0]) / span * a.size.x
		var h: float = clampf(float(b[1]), 0.0, 1.0) * a.size.y
		if h < 1.0:
			continue
		draw_rect(Rect2(x - bar * 0.5, a.end.y - h, bar, h), Color(txt, 0.7) if b[2] else accent, true)
	if not mini:
		var font := get_theme_default_font()
		draw_string(font, Vector2(a.position.x, a.position.y + 12), "dry", HORIZONTAL_ALIGNMENT_LEFT, -1, get_theme_default_font_size() - 3, Color(txt, 0.5))
		draw_string(font, Vector2(a.end.x - 60, a.position.y + 12), "%d ms" % int(span), HORIZONTAL_ALIGNMENT_RIGHT, 60, get_theme_default_font_size() - 3, Color(txt, 0.5))
