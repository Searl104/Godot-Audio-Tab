@tool
class_name AWTheme
extends RefCounted
## Editor-theme lookups (with fallbacks) and shared drawing helpers.


static func color(ctrl: Control, color_name: StringName, fallback: Color) -> Color:
	if ctrl.has_theme_color(color_name, &"Editor"):
		return ctrl.get_theme_color(color_name, &"Editor")
	return fallback


static func bg(ctrl: Control) -> Color:
	return color(ctrl, &"dark_color_2", Color(0.13, 0.15, 0.18))


static func text(ctrl: Control) -> Color:
	return color(ctrl, &"font_color", Color(0.88, 0.89, 0.91))


static func accent(ctrl: Control) -> Color:
	return color(ctrl, &"accent_color", Color(0.44, 0.69, 1.0))


static func icon(ctrl: Control, icon_name: StringName) -> Texture2D:
	if icon_name != &"" and ctrl.has_theme_icon(icon_name, &"EditorIcons"):
		return ctrl.get_theme_icon(icon_name, &"EditorIcons")
	return null


## Compact button using an editor icon when available, otherwise text.
static func button(ctx: Control, label: String, icon_name: StringName, tip: String, toggle := false) -> Button:
	var b := Button.new()
	b.toggle_mode = toggle
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	var tex := icon(ctx, icon_name)
	if tex:
		b.icon = tex
	else:
		b.text = label
	return b


const EXPORT_END := Color("#e8834a")


## The "sound ends here" marker: a vertical line, optionally with a small flag at the top.
## Dashed and fainter while the marker is automatic (following the clips); solid once placed.
static func draw_export_end(ctrl: Control, x: float, top: float, bottom: float, flag := false, auto := false) -> void:
	if x < -2.0 or x > ctrl.size.x + 2.0:
		return
	var xx := roundf(x) + 0.5
	if auto:
		ctrl.draw_dashed_line(Vector2(xx, top), Vector2(xx, bottom), Color(EXPORT_END, 0.7), 1.5, 5.0)
	else:
		ctrl.draw_line(Vector2(xx, top), Vector2(xx, bottom), Color(EXPORT_END, 0.95), 2.0)
	if flag:
		var col := Color(EXPORT_END, 0.7) if auto else EXPORT_END
		ctrl.draw_colored_polygon(PackedVector2Array([Vector2(xx - 7, top), Vector2(xx + 7, top), Vector2(xx + 7, top + 6), Vector2(xx, top + 12), Vector2(xx - 7, top + 6)]), col)


static func dim_label(label_text: String, alpha := 0.55) -> Label:
	var l := Label.new()
	l.text = label_text
	l.modulate = Color(1, 1, 1, alpha)
	return l


## Minor step to pair with a major label step.
static func minor_step(major: float) -> float:
	var mag := pow(10.0, floorf(log(major) / log(10.0)))
	var m := major / mag
	if is_equal_approx(m, 2.0):
		return major / 4.0
	if absf(m - 1.5) < 0.01:
		return major / 3.0
	return major / 5.0


## Vertical time grid lines across [y0, y1].
static func draw_time_grid(ctrl: Control, view: AWTimeView, y0: float, y1: float, base := 1.0) -> void:
	var c := text(ctrl)
	var major := view.label_step()
	var minor := minor_step(major)
	if minor * view.pixels_per_sec >= 10.0:
		_vlines(ctrl, view, minor, y0, y1, Color(c, 0.035 * base))
	_vlines(ctrl, view, major, y0, y1, Color(c, 0.09 * base))


static func _vlines(ctrl: Control, view: AWTimeView, step: float, y0: float, y1: float, col: Color) -> void:
	var t0 := view.x_to_time(0.0)
	var t1 := view.x_to_time(ctrl.size.x)
	var i := floori(t0 / step)
	while i * step <= t1:
		var x := roundf(view.time_to_x(i * step)) + 0.5
		ctrl.draw_line(Vector2(x, y0), Vector2(x, y1), col)
		i += 1


## The parameter dot used by cards and the curve dot column.
## has_curve=false: grey outline. Display ON: filled. DIM: faint fill. OFF: hollow ring.
static func draw_param_dot(ctrl: Control, center: Vector2, radius: float, col: Color, has_curve: bool,
		display: int, soloed := false, active := false) -> void:
	var outline := Color(0, 0, 0, 0.55)
	if not has_curve:
		ctrl.draw_arc(center, radius - 1.0, 0, TAU, 20, Color(text(ctrl), 0.35), 1.5, true)
		return
	match display:
		AWCurve.Display.ON:
			ctrl.draw_circle(center, radius, col)
			ctrl.draw_arc(center, radius, 0, TAU, 20, outline, 1.0, true)
		AWCurve.Display.DIM:
			ctrl.draw_circle(center, radius, Color(col, 0.3))
			ctrl.draw_arc(center, radius - 0.5, 0, TAU, 20, Color(col, 0.6), 1.0, true)
		AWCurve.Display.OFF:
			ctrl.draw_arc(center, radius - 1.0, 0, TAU, 20, Color(col, 0.7), 1.5, true)
	if soloed:
		ctrl.draw_arc(center, radius + 3.0, 0, TAU, 24, Color.WHITE, 1.5, true)
	elif active:
		ctrl.draw_arc(center, radius + 2.5, 0, TAU, 24, Color(text(ctrl), 0.8), 1.0, true)


## Small wave mark drawn over a dot whose curve has an LFO.
static func draw_lfo_badge(ctrl: Control, center: Vector2, radius: float) -> void:
	var pts := PackedVector2Array()
	var w := radius * 1.3
	for i in 13:
		var x := i / 12.0
		pts.append(center + Vector2((x - 0.5) * w * 2.0, -sin(x * TAU) * radius * 0.45))
	ctrl.draw_polyline(pts, Color(0.08, 0.09, 0.11, 0.95), 1.5, true)


static func popup_at(menu: PopupMenu, ctrl: Control, local_pos: Vector2) -> void:
	menu.reset_size()
	menu.popup(Rect2i(Vector2i(ctrl.get_screen_position() + local_pos), Vector2i.ZERO))


## Middle truncation for paths, as in macOS: the start and the end stay, the middle becomes "…".
## "Clip 2\Low Pass\Cutoff" in a narrow space reads "Clip 2\Lo…\Cutoff".
static func middle_truncate(font: Font, font_size: int, s: String, max_width: float) -> String:
	if font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_width:
		return s
	for keep in range(s.length() - 1, 0, -1):
		var head := ceili(keep / 2.0)
		var cand := s.left(head) + "…" + s.right(keep - head)
		if font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_width:
			return cand
	return "…"
