@tool
class_name AWChainPanel
extends VBoxContainer
## Bottom panel: [Master] [Clip] tabs and the active chain's effect cards, then a + card.

var doc: AWDocument

var _master_btn: Button
var _clip_btn: Button
var _owner: Label
var _cards_box: HBoxContainer
var _cards: Array[AWEffectCard] = []
var _rebuild_queued := false


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	var header := HBoxContainer.new()
	var group := ButtonGroup.new()
	_master_btn = Button.new()
	_master_btn.text = "  Master  "
	_clip_btn = Button.new()
	_clip_btn.text = "  Clip  "
	for b: Button in [_master_btn, _clip_btn]:
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		header.add_child(b)
	_master_btn.pressed.connect(func() -> void: doc.set_chain_tab(AWDocument.ChainTab.MASTER))
	_clip_btn.pressed.connect(func() -> void: doc.set_chain_tab(AWDocument.ChainTab.CLIP))
	var title := Label.new()
	title.text = "    Effect Chain"
	title.add_theme_font_size_override("font_size", get_theme_default_font_size() + 2)
	header.add_child(title)
	_owner = AWTheme.dim_label("")
	header.add_child(_owner)
	add_child(header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_cards_box = HBoxContainer.new()
	_cards_box.add_theme_constant_override("separation", 6)
	_cards_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_cards_box)
	add_child(scroll)

	doc.chain_target_changed.connect(_queue_rebuild)
	doc.project_changed.connect(func(structural: bool) -> void:
		if structural:
			_queue_rebuild()
		else:
			_refresh())
	doc.curve_view_changed.connect(_refresh)
	doc.playhead_changed.connect(_refresh)
	_rebuild()


func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _refresh() -> void:
	for c in _cards:
		if is_instance_valid(c):
			c.refresh()


func _rebuild() -> void:
	_rebuild_queued = false
	_cards.clear()
	for child in _cards_box.get_children():
		_cards_box.remove_child(child)
		child.queue_free()
	var is_master := doc.chain_tab == AWDocument.ChainTab.MASTER
	_master_btn.set_pressed_no_signal(is_master)
	_clip_btn.set_pressed_no_signal(not is_master)
	_clip_btn.text = "  Clip: %s  " % doc.focus_clip.name if doc.focus_clip else "  Clip  "
	var ch := doc.active_chain()
	_owner.text = "  (processed left to right)" if ch else ""
	if ch == null:
		var hint := AWTheme.dim_label("Select a clip on the timeline to edit its effect chain.")
		_cards_box.add_child(hint)
		return
	for e in ch.effects:
		var card := AWEffectCard.new()
		card.setup(doc, ch, e)
		_cards.append(card)
		_cards_box.add_child(card)
	_cards_box.add_child(_make_add_card(ch))


func _make_add_card(ch: AWChain) -> Control:
	var add := MenuButton.new()
	add.text = "+"
	add.flat = false
	add.tooltip_text = "Add an effect to the end of the chain"
	add.custom_minimum_size = Vector2(110, 0)
	add.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add.add_theme_font_size_override("font_size", 34)
	var popup := add.get_popup()
	var names := AWEffectLibrary.addable_names()
	for n in names:
		popup.add_item(n)
	popup.index_pressed.connect(func(i: int) -> void: doc.add_effect(ch, names[i]))
	return add
