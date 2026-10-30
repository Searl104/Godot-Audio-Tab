@tool
class_name AWTimelinePane
extends VBoxContainer
## The timeline: one shared time axis with two layers.
##   Clip mode: the clip grid is edited; the active chain's curves are drawn faintly over it.
##   Curve mode: the grid fades back and the curves are edited on top, in project time,
##   with a value axis and the curve list (coloured dots) on the right.
## Tab or the Clips / Curves switch changes mode; opening a curve switches to curve mode.
##
## Navigation (both modes, on the active layer):
##   middle-drag pans; Shift+middle-drag zooms (right = time in, down = rows taller / values
##   closer), anchored at the view's top-left; Ctrl+wheel zooms time, Shift+wheel scrolls time;
##   wheel scrolls rows (values in curve mode); Alt+wheel = row height (value zoom).
##   Scrollbars: drag the thumb to scroll, its ends to zoom, double-click to fit.
##   Fit (where the scrollbars meet, or F) fits both axes.

const SHOW_CURVES_PREF := "audio_workstation/curves/show_in_clip_mode"
const ZOOM_DRAG := 0.01 # Shift+middle-drag: zoom factor per pixel (exp)
const VALUE_WHEEL := 0.06

var doc: AWDocument
var grid: AWClipGrid
var headers: AWRowHeaders
var graph: AWCurveGraph
var dots: AWCurveDots
var axis: AWCurveAxis
var scroll: ScrollContainer
var hbar: AWScaleBar
var vbar: AWScaleBar
var fit_button: Button
var clips_button: Button
var curves_button: Button
var show_curves_button: Button
var owner_chain: Button
var owner_clip: Button

var _ruler: AWTimeRuler
var _stack: Control
var _right: Control
var _ruler_pad: Control
var _bar_pad: Control
var _unit_label: Label
var _owner_label: Label
var _curve_bar: HBoxContainer
var _mode_hint: Label
var _middle := false
var _middle_zoom := false
var _row_scroll := 0.0 # vertical scroll the grid is meant to be at (survives re-layout)


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	_build_header()

	graph = AWCurveGraph.new()
	graph.setup(doc)
	dots = AWCurveDots.new()
	dots.setup(doc, graph)
	axis = AWCurveAxis.new()
	axis.setup(doc, graph)

	# Ruler row: [rows corner] [ruler] [pad over the vertical bar and the right column]
	var ruler_row := HBoxContainer.new()
	ruler_row.add_theme_constant_override("separation", 0)
	var corner := Button.new()
	corner.flat = true
	corner.focus_mode = Control.FOCUS_NONE
	corner.name = "HeadersToggle"
	corner.tooltip_text = "Narrow or widen the row headers"
	ruler_row.add_child(corner)
	_ruler = AWTimeRuler.new()
	_ruler.setup(doc, doc.timeline_view, true)
	_ruler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ruler_row.add_child(_ruler)
	_ruler_pad = Control.new()
	ruler_row.add_child(_ruler_pad)
	_unit_label = Label.new()
	_unit_label.custom_minimum_size.x = AWCurveDots.W + AWCurveAxis.W
	_unit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_unit_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_unit_label.add_theme_font_size_override("font_size", get_theme_default_font_size() - 3)
	_unit_label.clip_text = true
	ruler_row.add_child(_unit_label)
	add_child(ruler_row)

	# Body: [stack: rows + grid, curve layer on top] [vertical bar] [dots + value axis]
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack = Control.new()
	_stack.name = "Layers"
	_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.clip_contents = true
	body.add_child(_stack)
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stack.add_child(scroll)
	var rows := HBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid = AWClipGrid.new()
	grid.setup(doc)
	grid.nav = nav_input
	headers = AWRowHeaders.new()
	headers.setup(doc, grid)
	headers.tooltip_text = " "
	rows.add_child(headers)
	rows.add_child(grid)
	scroll.add_child(rows)
	graph.nav = nav_input
	graph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stack.add_child(graph)
	vbar = AWScaleBar.new(true)
	vbar.name = "VScale"
	body.add_child(vbar)
	_right = HBoxContainer.new()
	_right.add_theme_constant_override("separation", 0)
	_right.add_child(dots)
	_right.add_child(axis)
	body.add_child(_right)
	add_child(body)

	# Bottom: [pad under the row headers] [horizontal bar] [Fit] [pad under the right column]
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 0)
	var hpad := Control.new()
	bottom.add_child(hpad)
	hbar = AWScaleBar.new(false)
	hbar.name = "HScale"
	bottom.add_child(hbar)
	fit_button = AWTheme.button(self, "⤢", &"DistractionFree", "Fit both axes (F)")
	fit_button.name = "FitView"
	fit_button.custom_minimum_size = Vector2(AWScaleBar.THICK, AWScaleBar.THICK)
	fit_button.flat = false
	fit_button.expand_icon = true
	fit_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for st: Array in [["normal", 0.14], ["hover", 0.3], ["pressed", 0.4], ["focus", 0.0]]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, st[1])
		sb.set_content_margin_all(1.0)
		sb.set_corner_radius_all(2)
		fit_button.add_theme_stylebox_override(st[0], sb)
	fit_button.pressed.connect(fit_view)
	bottom.add_child(fit_button)
	_bar_pad = Control.new()
	_bar_pad.custom_minimum_size.x = AWCurveDots.W + AWCurveAxis.W
	bottom.add_child(_bar_pad)
	add_child(bottom)

	var sync_corner := func() -> void:
		var w := AWRowHeaders.COLLAPSED_WIDTH if headers.collapsed else AWRowHeaders.WIDTH
		corner.custom_minimum_size.x = w
		hpad.custom_minimum_size.x = w
		graph.offset_left = w
		corner.text = "▸ Rows" if headers.collapsed else "◂ Rows"
	corner.pressed.connect(func() -> void: headers.set_collapsed(not headers.collapsed))
	headers.collapsed_changed.connect(sync_corner)
	sync_corner.call()
	_ruler_pad.custom_minimum_size.x = AWScaleBar.THICK

	hbar.scrolled.connect(func(t: float) -> void:
		var v := doc.timeline_view
		v.scroll_to((t - v.min_time) * v.pixels_per_sec))
	hbar.range_changed.connect(func(a: float, b: float) -> void: doc.timeline_view.frame_exact(a, b))
	hbar.fit_requested.connect(fit_all)
	vbar.scrolled.connect(_on_vbar_scrolled)
	vbar.range_changed.connect(_on_vbar_range)
	vbar.fit_requested.connect(fit_vertical)

	doc.timeline_view.changed.connect(_sync_bars)
	doc.value_view.changed.connect(_sync_bars)
	doc.project_changed.connect(func(_s: bool) -> void: _sync_bars())
	scroll.get_v_scroll_bar().value_changed.connect(func(v: float) -> void:
		_row_scroll = v
		_sync_bars())
	scroll.get_v_scroll_bar().changed.connect(_sync_bars)
	grid.row_height_changed.connect(_sync_bars)
	resized.connect(_sync_bars)
	doc.edit_mode_changed.connect(_apply_mode)
	doc.fit_requested.connect(fit_view)
	doc.chain_target_changed.connect(_sync_header)
	doc.curve_view_changed.connect(_sync_header)
	doc.project_changed.connect(func(_s: bool) -> void: _sync_header())
	_apply_mode()


func _build_header() -> void:
	var header := HBoxContainer.new()
	header.name = "CurveBar"
	var mg := ButtonGroup.new()
	clips_button = Button.new()
	clips_button.text = "Clips"
	clips_button.name = "ClipsMode"
	clips_button.tooltip_text = "Edit clips on the grid (Tab switches)"
	curves_button = Button.new()
	curves_button.text = "Curves"
	curves_button.name = "CurvesMode"
	curves_button.tooltip_text = "Edit the automation curves drawn over the grid (Tab switches)"
	for b: Button in [clips_button, curves_button]:
		b.toggle_mode = true
		b.button_group = mg
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		header.add_child(b)
	clips_button.pressed.connect(func() -> void: doc.set_edit_mode(AWDocument.EditMode.CLIPS))
	curves_button.pressed.connect(func() -> void: doc.set_edit_mode(AWDocument.EditMode.CURVES))
	header.add_child(VSeparator.new())

	show_curves_button = AWTheme.button(self, "Show Curves", &"GuiVisibilityVisible", "Show the curves faintly over the clips", true)
	show_curves_button.name = "ShowCurves"
	show_curves_button.button_pressed = show_curves_in_clip_mode()
	show_curves_button.toggled.connect(func(on: bool) -> void:
		AWImporter.set_pref(SHOW_CURVES_PREF, on)
		graph.queue_redraw())
	header.add_child(show_curves_button)
	_mode_hint = AWTheme.dim_label("Tab: edit curves", 0.45)
	header.add_child(_mode_hint)

	_curve_bar = HBoxContainer.new()
	_curve_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# On a chain tab: show the chain's curves, or the selected clip's own (Gain, Pitch, Pan).
	var og := ButtonGroup.new()
	owner_chain = Button.new()
	owner_clip = Button.new()
	owner_chain.name = "OwnerChain"
	owner_clip.name = "OwnerClip"
	for b: Button in [owner_chain, owner_clip]:
		b.toggle_mode = true
		b.button_group = og
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		_curve_bar.add_child(b)
	owner_chain.pressed.connect(func() -> void: doc.set_curve_on_clip(false))
	owner_clip.pressed.connect(func() -> void: doc.set_curve_on_clip(true))
	owner_chain.tooltip_text = "Curves of the chain's effects (shared by its clips; each runs on its clip's clock)"
	owner_clip.tooltip_text = "This clip's own curves: Gain, Pitch, Pan"
	_owner_label = AWTheme.dim_label("")
	_curve_bar.add_child(_owner_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_curve_bar.add_child(spacer)
	var lfos := AWTheme.button(self, "LFOs", &"", "Open the Audio LFO dock: every LFO in the project, click one to edit it")
	lfos.pressed.connect(doc.show_lfo_list)
	_curve_bar.add_child(lfos)
	var show_all := AWTheme.button(self, "Show All", &"", "Turn every curve back On and clear solo")
	show_all.pressed.connect(doc.show_all_curves)
	_curve_bar.add_child(show_all)
	header.add_child(_curve_bar)
	add_child(header)


static func show_curves_in_clip_mode() -> bool:
	return bool(AWImporter.get_pref(SHOW_CURVES_PREF, true))


func is_curve_mode() -> bool:
	return doc.edit_mode == AWDocument.EditMode.CURVES


func _apply_mode() -> void:
	var cm := is_curve_mode()
	clips_button.set_pressed_no_signal(not cm)
	curves_button.set_pressed_no_signal(cm)
	var acc := AWTheme.accent(self)
	for b: Button in [clips_button, curves_button]:
		if b.button_pressed:
			for k: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
				b.add_theme_color_override(k, acc)
		else:
			for k: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
				b.remove_theme_color_override(k)
	show_curves_button.visible = not cm
	_mode_hint.visible = not cm
	_curve_bar.visible = cm
	_right.visible = cm
	_unit_label.visible = cm
	_bar_pad.visible = cm
	scroll.modulate = Color(1, 1, 1, 0.3) if cm else Color.WHITE
	graph.mouse_filter = Control.MOUSE_FILTER_STOP if cm else Control.MOUSE_FILTER_IGNORE
	if not cm and graph.has_focus():
		grid.grab_focus()
	graph.queue_redraw()
	_sync_header()
	_sync_bars()


func _sync_header() -> void:
	if not is_instance_valid(owner_chain):
		return
	var on_chain := doc.chain_tab == AWDocument.ChainTab.CHAIN
	var vc := doc.view_clip()
	owner_chain.visible = on_chain
	owner_clip.visible = on_chain and vc != null
	if on_chain:
		owner_chain.text = (doc.tab_chain.name if doc.tab_chain else "Chain") + " curves"
		owner_clip.text = (vc.name if vc else "Clip") + " curves"
		owner_chain.set_pressed_no_signal(not doc.curve_on_clip or vc == null)
		owner_clip.set_pressed_no_signal(doc.curve_on_clip and vc != null)
		_owner_label.text = ("  on " + vc.name) if vc and not doc.curve_on_clip else ""
	else:
		var owner_name := doc.active_chain_name()
		_owner_label.text = (owner_name + " curves") if owner_name != "" else ""
	_unit_label.text = axis.unit_text()
	var c := axis.axis_curve()
	_unit_label.modulate = c.color.lightened(0.3) if c else Color.WHITE
	_unit_label.tooltip_text = (doc.active_chain().curve_label(c) + ": value axis") if c else ""


# --- Fitting ------------------------------------------------------------------

## Fits the time axis to the whole sound.
func fit_all() -> void:
	doc.timeline_view.frame(0.0, doc.project.content_end_sec())


## Fits the vertical axis of the active layer: the used rows, or the full value range.
func fit_vertical() -> void:
	if is_curve_mode():
		doc.value_view.reset()
		return
	var n := maxi(doc.project.max_row() + 1, 4)
	set_row_height(_view_h() / n, 0.0)


func fit_view() -> void:
	fit_all()
	fit_vertical()


# --- Rows (clip mode vertical axis) -------------------------------------------

func _view_h() -> float:
	return maxf(_stack.size.y, 1.0)


func row_scroll() -> float:
	return float(scroll.scroll_vertical)


func set_row_scroll(px: float) -> void:
	var maxv := maxf(grid.custom_minimum_size.y - _view_h(), 0.0)
	var sb := scroll.get_v_scroll_bar()
	if sb.max_value < grid.custom_minimum_size.y:
		sb.max_value = grid.custom_minimum_size.y # before the container re-sorts
	_row_scroll = clampf(px, 0.0, maxv)
	scroll.scroll_vertical = int(roundf(_row_scroll))
	_sync_bars()


## Row height with the row at the top of the view held in place (`top_row` < 0: keep the current one).
func set_row_height(h: float, top_row := -1.0) -> void:
	if top_row < 0.0:
		top_row = row_scroll() / grid.row_h
	grid.set_row_height(h)
	set_row_scroll(top_row * grid.row_h)


func zoom_rows(factor: float) -> void:
	set_row_height(grid.row_h * factor)


func _on_vbar_scrolled(s: float) -> void:
	if is_curve_mode():
		var vv := doc.value_view
		vv.set_range(1.0 - s - vv.span, 1.0 - s)
	else:
		set_row_scroll(s * grid.row_h)


func _on_vbar_range(a: float, b: float) -> void:
	if is_curve_mode():
		doc.value_view.set_range(1.0 - b, 1.0 - a)
	else:
		set_row_height(_view_h() / maxf(b - a, 0.01), a)


func _sync_bars() -> void:
	if hbar == null:
		return
	var v := doc.timeline_view
	var end := v.content_end.call() as float
	hbar.set_state(v.min_time, end, v.x_to_time(0.0), v.x_to_time(v.view_width))
	if is_curve_mode():
		var vv := doc.value_view
		vbar.set_state(0.0, 1.0, 1.0 - vv.hi(), 1.0 - vv.lo)
	else:
		# In rows, so a drag that changes the row height keeps its units.
		var top := row_scroll() / grid.row_h
		vbar.set_state(0.0, maxf(grid.custom_minimum_size.y, _view_h()) / grid.row_h, top, top + _view_h() / grid.row_h)


# --- Navigation ---------------------------------------------------------------

## Shared by the grid and the curve layer; returns true when the event was used.
func nav_input(event: InputEvent) -> bool:
	var mb := event as InputEventMouseButton
	if mb:
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_middle = mb.pressed
			_middle_zoom = mb.pressed and mb.shift_pressed
			return true
		if is_curve_mode() and mb.pressed and not mb.ctrl_pressed and not mb.meta_pressed and not mb.shift_pressed \
				and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP
			var amount := mb.factor if mb.factor > 0.0 else 1.0
			if mb.alt_pressed:
				doc.value_view.zoom_at(pow(1.15, amount) if up else pow(1.0 / 1.15, amount), graph.y_to_val(null, mb.position.y))
			else:
				doc.value_view.scroll_by((VALUE_WHEEL if up else -VALUE_WHEEL) * doc.value_view.span * amount)
			return true
		return false
	var mm := event as InputEventMouseMotion
	if mm and _middle:
		if not (mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE):
			_middle = false
			return false
		if _middle_zoom:
			zoom_drag(mm.relative)
		else:
			pan_drag(mm.relative)
		return true
	return false


## Middle-drag: the content follows the mouse.
func pan_drag(rel: Vector2) -> void:
	doc.timeline_view.scroll_by(-rel.x)
	if is_curve_mode():
		doc.value_view.scroll_by(rel.y / graph.unit_h())
	else:
		set_row_scroll(row_scroll() - rel.y)


## Shift+middle-drag: right = zoom time in, down = rows taller (values closer), anchored top-left.
func zoom_drag(rel: Vector2) -> void:
	if rel.x != 0.0:
		doc.timeline_view.zoom_by(exp(rel.x * ZOOM_DRAG), 0.0)
	if rel.y != 0.0:
		if is_curve_mode():
			doc.value_view.zoom_top(exp(rel.y * ZOOM_DRAG))
		else:
			zoom_rows(exp(rel.y * ZOOM_DRAG))
