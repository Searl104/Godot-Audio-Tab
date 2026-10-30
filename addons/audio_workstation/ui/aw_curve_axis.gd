@tool
class_name AWCurveAxis
extends Control
## Value axis on the right edge of the curve graph, for the selected (active) curve.
## Ticks are "nice" values in real units placed on the curve's own scale, so a log
## (Hz) axis reads 100 / 1k / 10k and a fader (dB) axis crowds toward 0 dB.
## Shows a tag with the selected key's exact value; the unit is shown above the axis
## (next to the ruler) via unit_text().

const W := 54.0
const MIN_GAP := 20.0
## Pitch: octaves first, then fifths and fourths.
const ST_PRIORITY := [0.0, 12.0, -12.0, 24.0, -24.0, 7.0, -7.0, 19.0, -19.0, 5.0, -5.0, 17.0, -17.0, 3.0, -3.0, 9.0, -9.0, 15.0, -15.0, 21.0, -21.0]
const DB_PRIORITY := [0.0, -6.0, -12.0, -24.0, -48.0, 12.0, 24.0, 6.0, -3.0, -18.0, -36.0, -60.0, -9.0, -30.0, -42.0, -54.0, -80.0, 18.0, 3.0]

var doc: AWDocument
var graph: AWCurveGraph


func setup(p_doc: AWDocument, p_graph: AWCurveGraph) -> void:
	doc = p_doc
	graph = p_graph


func _ready() -> void:
	custom_minimum_size = Vector2(W, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for s: Signal in [doc.curve_view_changed, doc.chain_target_changed]:
		s.connect(queue_redraw)
	doc.project_changed.connect(func(_s: bool) -> void: queue_redraw())
	doc.lfo_panel_changed.connect(queue_redraw)
	graph.resized.connect(queue_redraw)
	graph.draw.connect(queue_redraw) # follows key selection / drags


## The curve the axis describes: the active curve, if it's shown.
func axis_curve() -> AWCurve:
	var c := doc.active_curve
	var ch := doc.active_chain()
	if c == null or ch == null or not ch.curves.has(c) or not doc.is_curve_visible(c):
		return null
	return c


## Unit plus scale for the header slot above the axis, e.g. "Hz · log", "dB", "st".
func unit_text() -> String:
	var c := axis_curve()
	if c == null:
		return ""
	var e := doc.active_chain().effect_of(c)
	var unit: String = AWEffectLibrary.param_spec(e.effect_type, c.param)[4]
	var scale_name: String = ["", " · log", ""][c.scale]
	return (unit if unit != "" else "value") + scale_name


# --- Ticks --------------------------------------------------------------------

## [[norm (0..1), label], ...] for a curve, spaced at least `min_gap` px on a plot `plot_h` tall.
static func ticks(ch: AWChain, c: AWCurve, plot_h: float, min_gap := MIN_GAP) -> Array:
	var e := ch.effect_of(c)
	var spec := AWEffectLibrary.param_spec(e.effect_type if e else "", c.param)
	var lo: float = spec[0]
	var hi: float = spec[1]
	var unit: String = spec[4]
	var candidates: Array = [] # values in priority order
	match c.scale:
		AWCurve.Scale.LOG:
			for m: float in [1.0, 5.0, 2.0]:
				var k := floori(log(lo) / log(10.0))
				while pow(10.0, k) <= hi * 1.0001:
					candidates.append(m * pow(10.0, k))
					k += 1
		AWCurve.Scale.FADER:
			candidates = DB_PRIORITY.duplicate()
		_:
			if unit == "st":
				candidates = ST_PRIORITY.duplicate()
			else:
				var step := _nice_step((hi - lo) / maxf(plot_h / (min_gap * 1.6), 1.0))
				var i0 := ceili(lo / step - 0.0001)
				var i := i0
				while i * step <= hi + step * 0.0001:
					candidates.append(i * step)
					i += 1
	var picked: Array = []
	var used_px: Array[float] = []
	for v: float in candidates:
		if v < lo - 1e-6 or v > hi + 1e-6:
			continue
		var n := AWCurveMath.to_norm(c.scale, v, lo, hi)
		var px := n * plot_h
		var clash := false
		for u in used_px:
			if absf(u - px) < min_gap:
				clash = true
				break
		if clash:
			continue
		used_px.append(px)
		picked.append([n, format_tick(v, unit)])
	picked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return picked


static func _nice_step(raw: float) -> float:
	if raw <= 0.0:
		return 1.0
	var mag := pow(10.0, floorf(log(raw) / log(10.0)))
	for m: float in [1.0, 2.0, 2.5, 5.0, 10.0]:
		if m * mag >= raw:
			return m * mag
	return 10.0 * mag


static func format_tick(v: float, unit: String) -> String:
	if absf(v) < 1e-9:
		v = 0.0 # no "-0"
	if unit == "Hz":
		if v >= 1000.0:
			var k := v / 1000.0
			return (String.num(k, 0) if is_equal_approx(k, roundf(k)) else String.num(k, 1)) + "k"
		return String.num(v, 0)
	var text := String.num(v, 0) if is_equal_approx(v, roundf(v)) else String.num(v, 2 if absf(v) < 1.0 else 1)
	if (unit == "dB" or unit == "st") and v > 0.0:
		text = "+" + text
	return text


# --- Drawing ------------------------------------------------------------------

func _draw() -> void:
	var c_text := AWTheme.text(self)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 3
	draw_rect(Rect2(Vector2.ZERO, size), AWTheme.color(self, &"dark_color_1", Color(0.16, 0.18, 0.22)))
	draw_line(Vector2(0.5, 0), Vector2(0.5, size.y), Color(0, 0, 0, 0.5))
	var c := axis_curve()
	if c == null:
		draw_multiline_string(font, Vector2(0, size.y * 0.5 - fs), "select\na curve", HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, -1, Color(c_text, 0.35))
		return
	var ch := doc.active_chain()
	var e := ch.effect_of(c)
	var unit: String = AWEffectLibrary.param_spec(e.effect_type, c.param)[4]
	var col := c.color.lightened(0.25)

	for t: Array in ticks(ch, c, graph._plot_h()):
		var y := graph.val_to_y(c, t[0])
		draw_line(Vector2(0, y), Vector2(5, y), Color(col, 0.8))
		var ty := clampf(y + fs * 0.35, fs, size.y - 2.0)
		draw_string(font, Vector2(8, ty), t[1], HORIZONTAL_ALIGNMENT_LEFT, size.x - 10, fs, Color(c_text, 0.85))

	# LFO Max / Min tags while its panel is open.
	if doc.lfo_curve == c and c.lfo and c.lfo.mode == AWLfo.Mode.ABSOLUTE:
		for v: float in [c.lfo.max_value, c.lfo.min_value]:
			var ly := graph.val_to_y(c, ch.to_norm(c, v))
			var lt := AWEffectLibrary.format_value(e.effect_type, c.param, v).replace(" " + unit, "") if unit != "" else AWEffectLibrary.format_value(e.effect_type, c.param, v)
			var lh := fs + 6.0
			var lr := Rect2(2, clampf(ly - lh * 0.5, 0.0, size.y - lh), size.x - 4, lh)
			draw_rect(lr, Color(0.1, 0.1, 0.12))
			draw_rect(lr, Color(c.color, 0.9), false, 1.0)
			draw_string(font, Vector2(lr.position.x + 4, lr.position.y + fs + 1), lt, HORIZONTAL_ALIGNMENT_LEFT, lr.size.x - 6, fs, c.color.lightened(0.35))

	# Tag with the exact value of the first selected key (follows drags).
	if not graph.selected_keys.is_empty():
		var keys := ch.get_keys(c)
		var i: int = graph.selected_keys[0]
		if i < keys.size():
			var v := ch.from_norm(c, keys[i].v)
			var y := graph.val_to_y(c, keys[i].v)
			var label := AWEffectLibrary.format_value(e.effect_type, c.param, v).replace(" " + unit, "") if unit != "" else AWEffectLibrary.format_value(e.effect_type, c.param, v)
			var h := fs + 6.0
			var r := Rect2(2, clampf(y - h * 0.5, 0.0, size.y - h), size.x - 4, h)
			draw_rect(r, c.color.darkened(0.35))
			draw_rect(r, c.color, false, 1.0)
			draw_string(font, Vector2(r.position.x + 4, r.position.y + fs + 1), label, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 6, fs, c_text)
