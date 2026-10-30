@tool
class_name AWToolbar
extends HBoxContainer
## File / Edit menus, undo/redo, transport, clock, snap, export.

## Actions the main screen handles: "new", "open", "save", "save_as", "export".
signal request(action: String)

var doc: AWDocument

var _undo: Button
var _redo: Button
var _play: Button
var _loop: Button
var _clock: Label
var _snap: MenuButton
var _file: Label
var _cpu: Label
var _cpu_wait := 0.0


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	add_child(_menu("File", [["New", "new"], ["Open...", "open"], ["Save", "save"], ["Save As...", "save_as"], [],
		["Import Sound...", "import"], ["Export Sound", "export"]]))
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

	# Editing shortcuts (the keys still work).
	for sc: Array in [["Marker", &"Marker", "Add a marker at the playhead (M)", doc.add_marker.bind(-1.0, "")],
			["TrimStart", &"PageFirst", "Trim the selected clips' start to the playhead (Q)", doc.trim_selected_to_playhead.bind("start")],
			["TrimEnd", &"PageLast", "Trim the selected clips' end to the playhead (W)", doc.trim_selected_to_playhead.bind("end")],
			["Reverse", &"PlayBackwards", "Reverse the selected clips", _reverse_selection],
			["Crossfade", &"CurveInOut", "Crossfade overlapping selected clips", doc.crossfade_selected],
			["Group", &"Group", "Group the selected clips (Ctrl+G); with a group selected: ungroup (Ctrl+Shift+G)", _group_toggle]]:
		var b := AWTheme.button(self, sc[0], sc[1], sc[2])
		b.name = "Edit" + String(sc[0])
		var cb: Callable = sc[3]
		b.pressed.connect(func() -> void: cb.call())
		add_child(b)
	add_child(VSeparator.new())

	add_child(AWTheme.dim_label("Snap", 0.7))
	_snap = MenuButton.new()
	_snap.name = "SnapMenu"
	_snap.flat = true
	_snap.focus_mode = Control.FOCUS_NONE
	_snap.tooltip_text = "Snap (G toggles). Hold Alt while dragging to ignore snap. The checked targets attract too, within a few pixels."
	var sp := _snap.get_popup()
	sp.hide_on_checkable_item_selection = false
	for i in AWDocument.SNAP_OPTIONS.size():
		sp.add_radio_check_item(AWDocument.SNAP_OPTIONS[i][0], i)
	sp.add_separator("Also snap to")
	for i in AWDocument.SNAP_TARGETS.size():
		sp.add_check_item(AWDocument.SNAP_TARGETS[i][1], 100 + i)
	sp.id_pressed.connect(func(id: int) -> void:
		if id >= 100:
			var key: String = AWDocument.SNAP_TARGETS[id - 100][0]
			doc.set_snap_target(key, not doc.snap_target_on(key))
		else:
			doc.set_snap(AWDocument.SNAP_OPTIONS[id][1])
			sp.hide()
		_sync())
	add_child(_snap)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)
	_file = Label.new()
	_file.name = "FileName"
	_file.tooltip_text = "The open sound. A star means changes that aren't saved."
	_file.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	add_child(_file)
	add_child(VSeparator.new())
	_cpu = Label.new()
	_cpu.name = "CpuLoad"
	_cpu.add_theme_font_size_override("font_size", get_theme_default_font_size() - 2)
	_cpu.mouse_filter = Control.MOUSE_FILTER_PASS
	_cpu.tooltip_text = "How much of the audio thread's time playback uses. Near 100% you will hear dropouts: bypass or simplify some effects."
	_cpu.custom_minimum_size.x = 60
	add_child(_cpu)
	add_child(_engine_chip())
	doc.file_state_changed.connect(_sync)
	set_process(doc.engine.is_available())

	doc.transport_changed.connect(_sync)
	doc.project_changed.connect(func(_s: bool) -> void: _sync())
	doc.playhead_changed.connect(func() -> void: _clock.text = doc.format_clock(doc.playhead_sec))
	_sync()
	_clock.text = doc.format_clock(doc.playhead_sec)


func _process(delta: float) -> void:
	_cpu_wait -= delta
	if _cpu_wait > 0.0:
		return
	_cpu_wait = 0.25
	update_cpu()


func update_cpu() -> void:
	var l := doc.engine.get_load()
	var shown: String = "CPU %d%%" % int(round(float(l[1]) * 100.0)) if doc.playing else ""
	_cpu.text = shown
	var hot := float(l[1]) >= 0.9
	var warm := float(l[1]) >= 0.6
	_cpu.add_theme_color_override("font_color", Color("#e5484d") if hot else (Color("#f0b840") if warm else Color(1, 1, 1, 0.55)))


func _reverse_selection() -> void:
	if doc.selection.is_empty():
		doc.message.emit("Select clips to reverse them.")
		return
	doc.toggle_reverse_clips(doc.selection[0])


func _group_toggle() -> void:
	if doc.selection.size() >= 2 and doc.selection.all(func(c: AWClip) -> bool: return c.group_id != 0 and c.group_id == doc.selection[0].group_id):
		doc.ungroup_selected()
	else:
		doc.group_selected()


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
	if _file:
		_file.text = doc.file_label()
		_file.tooltip_text = (doc.project_path if doc.project_path != "" else "Not saved yet") + ("\nUnsaved changes" if doc.is_dirty() else "")
	_undo.disabled = not doc.can_undo()
	_redo.disabled = not doc.can_redo()
	var tex := AWTheme.icon(self, &"Pause" if doc.playing else &"Play")
	if tex:
		_play.icon = tex
	else:
		_play.text = "Pause" if doc.playing else "Play"
	_loop.set_pressed_no_signal(doc.project.loop_enabled)
	var sp := _snap.get_popup()
	_snap.text = "Off"
	for i in AWDocument.SNAP_OPTIONS.size():
		var on := is_equal_approx(AWDocument.SNAP_OPTIONS[i][1], doc.snap_sec)
		sp.set_item_checked(sp.get_item_index(i), on)
		if on:
			_snap.text = AWDocument.SNAP_OPTIONS[i][0] + "  ▾"
	for i in AWDocument.SNAP_TARGETS.size():
		var idx := sp.get_item_index(100 + i)
		sp.set_item_checked(idx, doc.snap_target_on(AWDocument.SNAP_TARGETS[i][0]))
		sp.set_item_disabled(idx, doc.snap_sec <= 0.0)
