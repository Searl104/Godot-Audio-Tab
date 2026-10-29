@tool
class_name AWEffectCard
extends PanelContainer
## One effect in the chain: header (bypass, name, menu) and its parameter rows.
## Drag a card by its header onto another card to reorder. The first card (Clip / Output)
## is the fixed source stage and can't be moved or removed.

const WIDTH := 262.0

var doc: AWDocument
var chain: AWChain
var effect: AWEffect

var rows: Array[AWParamRow] = []
var _bypass: CheckButton
var _style := StyleBoxFlat.new()
var _body: VBoxContainer
var _thumb: AWResponsePlot


func setup(p_doc: AWDocument, p_chain: AWChain, p_effect: AWEffect) -> void:
	doc = p_doc
	chain = p_chain
	effect = p_effect


func _ready() -> void:
	custom_minimum_size.x = WIDTH
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style.bg_color = AWTheme.color(self, &"base_color", Color(0.2, 0.23, 0.27))
	_style.border_color = AWEffectLibrary.effect_color(effect.effect_type)
	_style.border_width_top = 3
	_style.set_corner_radius_all(4)
	_style.set_content_margin_all(6)
	add_theme_stylebox_override("panel", _style)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	add_child(col)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_PASS
	if not effect.is_fixed():
		_bypass = CheckButton.new()
		_bypass.tooltip_text = "Enabled (off = bypassed)"
		_bypass.focus_mode = Control.FOCUS_NONE
		_bypass.toggled.connect(func(on: bool) -> void: doc.set_props(effect, {"bypass": not on}, "Toggle Effect"))
		header.add_child(_bypass)
	var title := Label.new()
	title.text = effect.effect_type
	title.add_theme_font_size_override("font_size", get_theme_default_font_size() + 1)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.tooltip_text = ("Fixed source stage" if effect.is_fixed() else AWEffectLibrary.godot_class(effect.effect_type) + "\nDrag the header to reorder")
	header.add_child(title)
	var menu := MenuButton.new()
	menu.text = "⋮"
	menu.flat = true
	menu.focus_mode = Control.FOCUS_NONE
	var popup := menu.get_popup()
	if not effect.is_fixed():
		popup.add_item("Move Left", 1)
		popup.add_item("Move Right", 2)
		popup.add_separator()
	if AWPanelRegistry.has_panel(effect.effect_type):
		popup.add_item("Open Panel", 5)
	popup.add_item("Reset Parameters", 3)
	if not effect.is_fixed():
		popup.add_separator()
		popup.add_item("Remove Effect", 4)
	popup.id_pressed.connect(_on_menu)
	header.add_child(menu)
	col.add_child(header)
	col.add_child(HSeparator.new())

	if AWPanelRegistry.has_panel(effect.effect_type):
		_thumb = AWResponsePlot.new()
		_thumb.mini = true
		_thumb.accent = AWEffectLibrary.effect_color(effect.effect_type)
		_thumb.db_min = -36.0 if effect.effect_type == "Low Pass" else -18.0
		_thumb.db_max = 18.0
		_thumb.custom_minimum_size.y = 44
		_thumb.mouse_filter = Control.MOUSE_FILTER_PASS
		_thumb.tooltip_text = "Double-click to open the panel"
		col.add_child(_thumb)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 2)
	for key: String in AWEffectLibrary.param_schema(effect.effect_type):
		var row := AWParamRow.new()
		row.setup(doc, chain, effect, key)
		rows.append(row)
		_body.add_child(row)
	col.add_child(_body)
	refresh()


func refresh() -> void:
	if _bypass:
		_bypass.set_pressed_no_signal(not effect.bypass)
	_body.modulate = Color(1, 1, 1, 0.45 if effect.bypass else 1.0)
	for r in rows:
		r.refresh()
	if _thumb:
		_thumb.response = AWPanelRegistry.response(doc, chain, effect, 96)
		_thumb.queue_redraw()


func _on_menu(id: int) -> void:
	var idx := chain.effects.find(effect)
	match id:
		1: doc.move_effect(chain, effect, idx - 1)
		2: doc.move_effect(chain, effect, idx + 1)
		3: doc.reset_effect(chain, effect)
		4: doc.remove_effect(chain, effect)
		5: doc.open_detail(chain, effect)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.double_click \
			and event.button_index == MOUSE_BUTTON_LEFT and AWPanelRegistry.has_panel(effect.effect_type):
		if event.position.y < 34.0 or (_thumb and Rect2(_thumb.global_position - global_position, _thumb.size).has_point(event.position)):
			doc.open_detail(chain, effect)
			accept_event()


func _get_drag_data(_at: Vector2) -> Variant:
	if effect.is_fixed():
		return null
	var preview := Label.new()
	preview.text = "  " + effect.effect_type
	set_drag_preview(preview)
	return {"type": "aw_effect", "effect": effect, "chain": chain}


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.get("type", "") == "aw_effect" and data["chain"] == chain and data["effect"] != effect


func _drop_data(at: Vector2, data: Variant) -> void:
	var idx := chain.effects.find(effect)
	var from := chain.effects.find(data["effect"])
	var to := idx + (1 if at.x > size.x * 0.5 else 0)
	if from < to:
		to -= 1
	doc.move_effect(chain, data["effect"], to)
