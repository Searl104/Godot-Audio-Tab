@tool
class_name AWToolbar
extends HBoxContainer
## File / Edit menus, undo/redo, transport, clock, snap, export.

## Actions the main screen handles (dialogs): "new", "open", "save", "save_as", "export_wav", "export_stream".
signal request(action: String)

var doc: AWDocument

var _undo: Button
var _redo: Button
var _play: Button
var _loop: Button
var _clock: Label
var _snap: OptionButton


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	add_child(_menu("File", [["New", "new"], ["Open...", "open"], ["Save", "save"], ["Save As...", "save_as"], [],
		["Export WAV...", "export_wav"], ["Export as AudioStream...", "export_stream"]]))
	var edit := MenuButton.new()
	edit.text = "Edit"
	edit.flat = true
	var ep := edit.get_popup()
	for item: Array in [["Undo", doc.undo], ["Redo", doc.redo], [], ["Split at Playhead  (S)", doc.split_selected_at_playhead],
			["Duplicate  (Ctrl+D)", doc.duplicate_selected], ["Delete  (Del)", doc.delete_selected_clips], [],
			["Select All Clips  (Ctrl+A)", doc.select_all_clips]]:
		if item.is_empty():
			ep.add_separator()
		else:
			ep.add_item(item[0])
			ep.set_item_metadata(ep.item_count - 1, item[1])
	ep.index_pressed.connect(func(i: int) -> void: (ep.get_item_metadata(i) as Callable).call())
	add_child(edit)
	add_child(VSeparator.new())

	_undo = AWTheme.button(self, "Undo", &"UndoRedo", "Undo")
	_undo.text = "Undo"
	_undo.icon = null
	_undo.pressed.connect(doc.undo)
	_redo = AWTheme.button(self, "Redo", &"", "Redo")
	_redo.pressed.connect(doc.redo)
	add_child(_undo)
	add_child(_redo)
	add_child(VSeparator.new())

	var home := AWTheme.button(self, "|<", &"PlayStartBackwards", "Go to start (Home)")
	home.pressed.connect(func() -> void: doc.seek(0.0))
	_play = AWTheme.button(self, "Play", &"Play", "Play / Pause (Space)")
	_play.pressed.connect(doc.play_pause)
	var stop := AWTheme.button(self, "Stop", &"Stop", "Stop (Enter)")
	stop.pressed.connect(doc.stop)
	_loop = AWTheme.button(self, "Loop", &"Loop", "Loop (L)", true)
	_loop.pressed.connect(doc.toggle_loop)
	for b in [home, _play, stop, _loop]:
		add_child(b)
	_clock = Label.new()
	_clock.custom_minimum_size.x = 84
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock.tooltip_text = "Playhead (minutes:seconds)"
	add_child(_clock)
	add_child(VSeparator.new())

	add_child(AWTheme.dim_label("Snap", 0.7))
	_snap = OptionButton.new()
	_snap.flat = true
	_snap.focus_mode = Control.FOCUS_NONE
	_snap.tooltip_text = "Snap (G toggles). Hold Alt while dragging to ignore snap."
	for opt: Array in AWDocument.SNAP_OPTIONS:
		_snap.add_item(opt[0])
	_snap.item_selected.connect(func(i: int) -> void: doc.set_snap(AWDocument.SNAP_OPTIONS[i][1]))
	add_child(_snap)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)
	add_child(_engine_chip())

	doc.transport_changed.connect(_sync)
	doc.project_changed.connect(func(_s: bool) -> void: _sync())
	doc.playhead_changed.connect(func() -> void: _clock.text = doc.format_clock(doc.playhead_sec))
	_sync()
	_clock.text = doc.format_clock(doc.playhead_sec)


## Small status chip: is the native audio engine loaded?
func _engine_chip() -> Control:
	var chip := Label.new()
	chip.name = "EngineStatus"
	var ok := doc.engine.is_available()
	chip.text = ("● " if ok else "○ ") + doc.engine.status_text()
	chip.tooltip_text = doc.engine.status_tooltip()
	chip.mouse_filter = Control.MOUSE_FILTER_PASS
	chip.add_theme_font_size_override("font_size", get_theme_default_font_size() - 2)
	chip.add_theme_color_override("font_color", Color("#7fd18b") if ok else Color(1, 1, 1, 0.5))
	return chip


func _menu(title: String, items: Array) -> MenuButton:
	var mb := MenuButton.new()
	mb.text = title
	mb.flat = true
	var p := mb.get_popup()
	for item: Array in items:
		if item.is_empty():
			p.add_separator()
		else:
			p.add_item(item[0])
			p.set_item_metadata(p.item_count - 1, item[1])
	p.index_pressed.connect(func(i: int) -> void: request.emit(p.get_item_metadata(i)))
	return mb


func _sync() -> void:
	_undo.disabled = not doc.can_undo()
	_redo.disabled = not doc.can_redo()
	var tex := AWTheme.icon(self, &"Pause" if doc.playing else &"Play")
	if tex:
		_play.icon = tex
	else:
		_play.text = "Pause" if doc.playing else "Play"
	_loop.set_pressed_no_signal(doc.project.loop_enabled)
	for i in AWDocument.SNAP_OPTIONS.size():
		if is_equal_approx(AWDocument.SNAP_OPTIONS[i][1], doc.snap_sec):
			_snap.select(i)
