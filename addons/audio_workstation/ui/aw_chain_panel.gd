@tool
class_name AWChainPanel
extends VBoxContainer
## Bottom panel: chain tabs, then the shown chain's cards.
##
##   |Master|Impact FX|Debris FX| + |
##
## Master: the master chain. A shared chain: a Clips card (one row per clip on the chain, with its
## own Gain / Pitch / Pan) then the chain's effects and +. A clip without a chain gets a temporary
## tab with its Clip card and a card to attach a chain. "+" makes a new chain for the selected
## clips (or group). Right-click a chain tab: Rename, Duplicate, Delete.

var doc: AWDocument

var tabs: TabBar
var _cards_box: HBoxContainer
var _cards: Array[AWEffectCard] = []
var _clips_card: Control
var _rebuild_queued := false
var _tab_targets: Array = [] # per tab: "master", "clip", an AWChain, or "+"
var _menu: PopupMenu
var _menu_chain: AWChain
var _menu_group: AWGroup
var _rename: LineEdit
var _rename_chain: AWChain
var _syncing := false


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	tabs = TabBar.new()
	tabs.name = "ChainTabs"
	tabs.clip_tabs = true
	tabs.focus_mode = Control.FOCUS_NONE
	tabs.tab_changed.connect(_on_tab)
	tabs.tab_clicked.connect(_on_tab_clicked)
	tabs.tab_rmb_clicked.connect(_on_tab_rmb)
	tabs.select_with_rmb = false
	add_child(tabs)
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	_rename = LineEdit.new()
	_rename.visible = false
	_rename.top_level = true
	_rename.text_submitted.connect(func(_t: String) -> void: _finish_rename(true))
	_rename.focus_exited.connect(func() -> void: _finish_rename(true))
	_rename.gui_input.connect(func(e: InputEvent) -> void:
		var k := e as InputEventKey
		if k and k.pressed and k.keycode == KEY_ESCAPE:
			_finish_rename(false)
			_rename.accept_event())
	add_child(_rename)

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
			_sync_tabs()
			_refresh())
	doc.curve_view_changed.connect(_refresh)
	doc.playhead_changed.connect(_refresh)
	doc.selection_changed.connect(_queue_rebuild)
	_rebuild()


func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _refresh() -> void:
	for c in _cards:
		if is_instance_valid(c):
			c.refresh()
	if is_instance_valid(_clips_card) and _clips_card.has_method("refresh"):
		_clips_card.refresh()


# --- Tabs -------------------------------------------------------------------------------

func _sync_tabs() -> void:
	_syncing = true
	_tab_targets.clear()
	tabs.clear_tabs()
	tabs.add_tab("Master")
	_tab_targets.append("master")
	var dry := doc.chain_tab == AWDocument.ChainTab.CLIP and doc.focus_clip != null
	if dry:
		tabs.add_tab("%s · no chain" % doc.focus_clip.name)
		_tab_targets.append("clip")
	for ch in doc.project.chains:
		tabs.add_tab(ch.name)
		tabs.set_tab_tooltip(tabs.tab_count - 1, "%s: used by %d clip%s. Right-click: rename, duplicate, delete." % [ch.name, doc.chain_clips(ch).size(), "" if doc.chain_clips(ch).size() == 1 else "s"])
		_tab_targets.append(ch)
	for g in doc.project.groups:
		if g.chain:
			tabs.add_tab("▣ " + g.name)
			tabs.set_tab_tooltip(tabs.tab_count - 1, "Group \"%s\": its clips are mixed, then run through this chain once (a bus). Right-click: remove." % g.name)
			_tab_targets.append(g)
	tabs.add_tab(" + ")
	tabs.set_tab_tooltip(tabs.tab_count - 1, "New chain for the selected clips (or group)")
	_tab_targets.append("+")
	var want := 0
	match doc.chain_tab:
		AWDocument.ChainTab.MASTER: want = 0
		AWDocument.ChainTab.CLIP: want = 1 if dry else 0
		AWDocument.ChainTab.CHAIN: want = maxi(0, _tab_targets.find(doc.tab_chain))
		AWDocument.ChainTab.GROUP: want = maxi(0, _tab_targets.find(doc.tab_group))
	tabs.current_tab = want
	_syncing = false


func _on_tab(i: int) -> void:
	if _syncing or i < 0 or i >= _tab_targets.size():
		return
	var t: Variant = _tab_targets[i]
	if t is AWChain:
		doc.open_chain_tab(t)
	elif t is AWGroup:
		doc.open_group_tab(t)
	elif t == "master":
		doc.set_chain_tab(AWDocument.ChainTab.MASTER)
	elif t == "clip":
		doc.set_chain_tab(AWDocument.ChainTab.CLIP)
	elif t == "+":
		_sync_tabs.call_deferred() # keep the current tab selected
		doc.new_chain_for(doc.focus_clip if doc.selection.is_empty() else null)


func _on_tab_clicked(i: int) -> void:
	# Clicking the already-selected "+" (e.g. right after another +) still makes a chain.
	if i == tabs.current_tab and i < _tab_targets.size() and str(_tab_targets[i]) == "+":
		_on_tab(i)


func _on_tab_rmb(i: int) -> void:
	if i >= 0 and i < _tab_targets.size() and _tab_targets[i] is AWGroup:
		_menu_group = _tab_targets[i]
		_menu.clear()
		_menu.add_item("Remove Group Chain", 10)
		var gr := tabs.get_tab_rect(i)
		AWTheme.popup_at(_menu, tabs, gr.position + Vector2(0, gr.size.y))
		return
	if i < 0 or i >= _tab_targets.size() or not (_tab_targets[i] is AWChain):
		return
	_menu_chain = _tab_targets[i]
	_menu.clear()
	_menu.add_item("Rename Chain", 1)
	_menu.add_item("Duplicate Chain", 2)
	if not doc.selection.is_empty():
		_menu.add_item("Use for Selected Clips", 4)
	_menu.add_separator()
	_menu.add_item("Delete Chain", 3)
	var r := tabs.get_tab_rect(i)
	AWTheme.popup_at(_menu, tabs, r.position + Vector2(0, r.size.y))


func _on_menu(id: int) -> void:
	match id:
		1: start_rename(_menu_chain)
		2: doc.duplicate_chain(_menu_chain)
		3: doc.delete_chain(_menu_chain)
		4: doc.set_clip_chain(null, _menu_chain)
		10: doc.remove_group_chain(_menu_group)


func start_rename(ch: AWChain) -> void:
	var i := _tab_targets.find(ch)
	if i < 0:
		return
	_rename_chain = ch
	var r := tabs.get_tab_rect(i)
	_rename.text = ch.name
	_rename.global_position = tabs.global_position + r.position
	_rename.size = Vector2(maxf(r.size.x, 140.0), r.size.y)
	_rename.visible = true
	_rename.grab_focus()
	_rename.select_all()


func _finish_rename(apply: bool) -> void:
	if _rename_chain == null:
		return
	var ch := _rename_chain
	_rename_chain = null
	_rename.visible = false
	if apply:
		doc.rename_chain(ch, _rename.text)


# --- Cards ------------------------------------------------------------------------------

func _rebuild() -> void:
	_rebuild_queued = false
	_sync_tabs()
	_cards.clear()
	_clips_card = null
	for child in _cards_box.get_children():
		_cards_box.remove_child(child)
		child.queue_free()
	match doc.chain_tab:
		AWDocument.ChainTab.MASTER:
			_add_chain_cards(doc.project.master_chain, 0)
		AWDocument.ChainTab.GROUP:
			if doc.tab_group and doc.tab_group.chain:
				_add_chain_cards(doc.tab_group.chain, 0)
		AWDocument.ChainTab.CHAIN:
			var ch := doc.tab_chain
			if ch == null:
				return
			_clips_card = AWClipsCard.new()
			_clips_card.setup(doc, ch)
			_cards_box.add_child(_clips_card)
			_add_chain_cards(ch, 0)
		_:
			var clip := doc.focus_clip
			if clip == null:
				var hint := AWTheme.dim_label("Select a clip on the timeline, or a chain tab above.")
				_cards_box.add_child(hint)
				return
			# A clip without a chain: its Clip card (and effects it owned before chains), then
			# a card to attach one.
			_add_chain_cards(clip.chain, -1)
			_cards_box.add_child(_make_attach_card(clip))


## Cards of `ch`; `add_card` 0 = an add-effect card at the end, -1 = none.
func _add_chain_cards(ch: AWChain, add_card: int) -> void:
	for e in ch.effects:
		var card := AWEffectCard.new()
		card.setup(doc, ch, e)
		_cards.append(card)
		_cards_box.add_child(card)
	if add_card == 0:
		_cards_box.add_child(_make_add_card(ch))


func _make_add_card(ch: AWChain) -> Control:
	var add := MenuButton.new()
	add.name = "AddEffect"
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


## For a clip without a chain: make a new one, or use an existing one.
func _make_attach_card(clip: AWClip) -> Control:
	var panel := PanelContainer.new()
	panel.name = "AttachChain"
	panel.custom_minimum_size = Vector2(220, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(col)
	var info := AWTheme.dim_label("No effect chain: this clip plays dry.", 0.7)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(info)
	var make := Button.new()
	make.text = "New Chain"
	make.tooltip_text = "A new effect chain for this clip (or the selected clips / group)"
	make.pressed.connect(func() -> void: doc.new_chain_for(clip))
	col.add_child(make)
	if not doc.project.chains.is_empty():
		var use := MenuButton.new()
		use.text = "Use Chain ▾"
		use.flat = false
		var p := use.get_popup()
		for i in doc.project.chains.size():
			p.add_item(doc.project.chains[i].name, i)
		p.id_pressed.connect(func(i: int) -> void: doc.set_clip_chain(clip, doc.project.chains[i]))
		col.add_child(use)
	return panel
