@tool
class_name AWEffectDetail
extends VBoxContainer
## Content of the "Audio Effect" dock: header (name, owner, bypass, reset) and the
## effect's custom panel from the registry. Follows doc.detail_effect.

var doc: AWDocument
var panel: AWEffectPanel

var _bar: PanelContainer
var _style := StyleBoxFlat.new()
var _title: Label
var _owner: Label
var _bypass: CheckButton
var _body: Control
var _hint: Label


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	custom_minimum_size = Vector2(420, 260)
	add_theme_constant_override("separation", 6)
	_bar = PanelContainer.new()
	_style.bg_color = AWTheme.color(self, &"base_color", Color(0.2, 0.23, 0.27))
	_style.border_width_top = 3
	_style.set_content_margin_all(6)
	_bar.add_theme_stylebox_override("panel", _style)
	var h := HBoxContainer.new()
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", get_theme_default_font_size() + 2)
	h.add_child(_title)
	_owner = AWTheme.dim_label("")
	_owner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_owner)
	_bypass = CheckButton.new()
	_bypass.tooltip_text = "Enabled (off = bypassed)"
	_bypass.focus_mode = Control.FOCUS_NONE
	_bypass.toggled.connect(func(on: bool) -> void:
		if doc.detail_effect:
			doc.set_props(doc.detail_effect, {"bypass": not on}, "Toggle Effect"))
	h.add_child(_bypass)
	var reset := Button.new()
	reset.text = "Reset"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(func() -> void:
		if doc.detail_effect:
			doc.reset_effect(doc.detail_chain, doc.detail_effect))
	h.add_child(reset)
	_bar.add_child(h)
	add_child(_bar)
	_body = MarginContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("margin_left", 8)
	_body.add_theme_constant_override("margin_right", 8)
	_body.add_theme_constant_override("margin_top", 6)
	_body.add_theme_constant_override("margin_bottom", 8)
	add_child(_body)
	_hint = AWTheme.dim_label("Open an effect's panel from its card: double-click the header, or ⋮ > Open Panel.")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = 200
	_body.add_child(_hint)
	doc.detail_changed.connect(_rebuild)
	doc.project_changed.connect(_on_project_changed)
	doc.curve_view_changed.connect(refresh)
	doc.playhead_changed.connect(refresh)
	_rebuild()


func _on_project_changed(structural: bool) -> void:
	if structural and doc.detail_effect and not doc.detail_chain.effects.has(doc.detail_effect):
		doc.open_detail(null, null)
		return
	refresh()


func refresh() -> void:
	if panel and is_instance_valid(panel):
		panel.refresh()
	if doc.detail_effect:
		_bypass.set_pressed_no_signal(not doc.detail_effect.bypass)
		_body.modulate = Color(1, 1, 1, 0.45 if doc.detail_effect.bypass else 1.0)


func _rebuild() -> void:
	if panel:
		_body.remove_child(panel)
		panel.queue_free()
		panel = null
	var e := doc.detail_effect
	_bar.visible = e != null
	_hint.visible = e == null
	if e == null:
		return
	_style.border_color = AWEffectLibrary.effect_color(e.effect_type)
	_title.text = e.effect_type
	var idx := doc.detail_chain.effects.find(e) + 1
	_owner.text = "   %s, effect %d of %d" % [("Master" if doc.detail_chain == doc.project.master_chain else "Clip"), idx, doc.detail_chain.effects.size()]
	panel = AWPanelRegistry.create(e.effect_type)
	if panel == null:
		doc.open_detail(null, null)
		return
	panel.setup(doc, doc.detail_chain, e)
	_body.add_child(panel)
	refresh()
