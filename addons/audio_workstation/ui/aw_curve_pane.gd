@tool
class_name AWCurvePane
extends HBoxContainer
## Right pane: automation for the active chain (selected clip, or Master).
## Header: whose curves these are, Clip/Project time toggle, Frame, Show All.

var doc: AWDocument
var graph: AWCurveGraph
var lfo_panel: AWLfoPanel

var _owner_label: Label
var _clip_time: Button
var _project_time: Button
var _hbar: HScrollBar


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(col)
	lfo_panel = AWLfoPanel.new()
	lfo_panel.setup(doc)
	add_child(lfo_panel)
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "  Timeline"
	header.add_child(title)
	_owner_label = AWTheme.dim_label("")
	header.add_child(_owner_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var group := ButtonGroup.new()
	_clip_time = Button.new()
	_clip_time.text = "Clip Time"
	_clip_time.tooltip_text = "The clip's own audio clock: 0 = clip start, keys stay on moments of the sound.\nThe playhead moves at the clip's playback rate (slower when pitched down)."
	_project_time = Button.new()
	_project_time.text = "Project Time"
	_project_time.tooltip_text = "Same time axis as the clip timeline (pitch changes stretch the curves)"
	for b: Button in [_clip_time, _project_time]:
		b.toggle_mode = true
		b.button_group = group
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		header.add_child(b)
	_clip_time.pressed.connect(func() -> void: doc.set_curve_time(AWDocument.CurveTime.CLIP))
	_project_time.pressed.connect(func() -> void: doc.set_curve_time(AWDocument.CurveTime.PROJECT))
	header.add_child(VSeparator.new())
	var frame := AWTheme.button(self, "Frame", &"", "Frame the curves (F)")
	frame.pressed.connect(doc.frame_curves)
	header.add_child(frame)
	var show_all := AWTheme.button(self, "Show All", &"", "Turn every curve back On and clear solo")
	show_all.pressed.connect(doc.show_all_curves)
	header.add_child(show_all)
	col.add_child(header)

	graph = AWCurveGraph.new()
	graph.setup(doc)
	var dots := AWCurveDots.new()
	dots.setup(doc, graph)
	var axis := AWCurveAxis.new()
	axis.setup(doc, graph)

	var ruler_row := HBoxContainer.new()
	ruler_row.add_theme_constant_override("separation", 0)
	var pad := Control.new()
	pad.custom_minimum_size.x = AWCurveDots.W
	ruler_row.add_child(pad)
	var ruler := AWTimeRuler.new()
	ruler.setup(doc, doc.curve_view, false)
	ruler.to_project = doc.view_to_project
	ruler.from_project = doc.project_to_view
	ruler.domain = func() -> Vector2: return Vector2(doc.local_to_view(0.0), doc.curve_domain_end_view())
	ruler_row.add_child(ruler)
	var unit_label := Label.new()
	unit_label.custom_minimum_size.x = AWCurveAxis.W
	unit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	unit_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	unit_label.add_theme_font_size_override("font_size", get_theme_default_font_size() - 3)
	unit_label.clip_text = true
	ruler_row.add_child(unit_label)
	var sync_unit := func() -> void:
		unit_label.text = axis.unit_text()
		var c := axis.axis_curve()
		unit_label.modulate = c.color.lightened(0.3) if c else Color.WHITE
		unit_label.tooltip_text = (doc.active_chain().curve_label(c) + " — value axis") if c else ""
	doc.curve_view_changed.connect(sync_unit)
	doc.chain_target_changed.connect(sync_unit)
	doc.project_changed.connect(func(_s: bool) -> void: sync_unit.call())
	col.add_child(ruler_row)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(dots)
	body.add_child(graph)
	body.add_child(axis)
	col.add_child(body)

	var bar_row := HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 0)
	var pad2 := Control.new()
	pad2.custom_minimum_size.x = AWCurveDots.W
	bar_row.add_child(pad2)
	_hbar = HScrollBar.new()
	_hbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hbar.value_changed.connect(doc.curve_view.scroll_to)
	bar_row.add_child(_hbar)
	var bpad := Control.new()
	bpad.custom_minimum_size.x = AWCurveAxis.W
	bar_row.add_child(bpad)
	col.add_child(bar_row)

	doc.curve_view.changed.connect(_sync_bar)
	doc.chain_target_changed.connect(_on_target_changed)
	doc.curve_view_changed.connect(_sync_header)
	doc.project_changed.connect(func(_s: bool) -> void: _sync_header())
	graph.resized.connect(_first_frame, CONNECT_ONE_SHOT)
	_sync_header()


func _first_frame() -> void:
	doc.frame_curves.call_deferred()


func _on_target_changed() -> void:
	_sync_header()
	doc.frame_curves()


func _sync_header() -> void:
	var owner_name := doc.active_chain_name()
	_owner_label.text = ("  ·  " + owner_name + " curves") if owner_name != "" else ""
	var is_master := doc.chain_tab == AWDocument.ChainTab.MASTER
	_clip_time.disabled = is_master
	_project_time.disabled = is_master
	_clip_time.set_pressed_no_signal(doc.curve_time == AWDocument.CurveTime.CLIP and not is_master)
	_project_time.set_pressed_no_signal(doc.curve_time == AWDocument.CurveTime.PROJECT or is_master)


func _sync_bar() -> void:
	var v := doc.curve_view
	_hbar.max_value = v.scroll_range()
	_hbar.page = v.view_width
	_hbar.set_value_no_signal(v.scroll_x)
