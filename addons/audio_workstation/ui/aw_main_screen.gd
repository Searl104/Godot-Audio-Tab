@tool
class_name AWMainScreen
extends VBoxContainer
## The "Audio" main-screen tab, laid out like the sketch:
##
##   toolbar
##   [reserved] [ Timeline: clip grid  |  Timeline: automation curves ]
##   [ Master | Clip ]  Effect Chain:  card  card  card  card  [+]
##   status line

var doc: AWDocument
var engine: AWEngine

var timeline: AWTimelinePane
var curves: AWCurvePane
var chain_panel: AWChainPanel
var export_panel: AWExportPanel
var detail_panel: AWEffectDetail
var lfo_panel: AWLfoPanel

var _status: Label
var _dialog: FileDialog
var _dialog_action := ""
var _confirm: ConfirmationDialog
var _pending_after_ask := Callable()
var _after_save := Callable()
var _relink_clip: AWClip
var _toolbar: AWToolbar
var browser: AWSoundBrowser
var _import_at := Vector2(0, 0) # (row, time) for the next import
var _recovery: ConfirmationDialog
var recovery_prompt_in_tests := false


func setup(plugin: EditorPlugin) -> void:
	engine = AWEngine.new()
	doc = AWDocument.new(plugin.get_undo_redo(), engine)
	doc.set_project(AWProject.create_default())


func _ready() -> void:
	name = "AudioWorkstation"
	add_theme_constant_override("separation", 2)

	var toolbar := AWToolbar.new()
	_toolbar = toolbar
	toolbar.setup(doc)
	toolbar.request.connect(_on_request)
	add_child(toolbar)

	var vsplit := VSplitContainer.new()
	vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(vsplit)

	var top := HBoxContainer.new()
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", 2)
	top.add_child(_make_reserved_column())
	var hsplit := HSplitContainer.new()
	hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline = AWTimelinePane.new()
	timeline.setup(doc)
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.size_flags_stretch_ratio = 1.0
	curves = AWCurvePane.new()
	curves.setup(doc)
	curves.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	curves.size_flags_stretch_ratio = 1.0
	hsplit.add_child(timeline)
	hsplit.add_child(curves)
	top.add_child(hsplit)
	export_panel = AWExportPanel.new()
	export_panel.setup(doc)
	export_panel.browse_requested.connect(func() -> void: _on_request("export_browse"))
	detail_panel = AWEffectDetail.new()
	detail_panel.setup(doc)
	lfo_panel = AWLfoPanel.new()
	lfo_panel.setup(doc)
	vsplit.add_child(top)

	chain_panel = AWChainPanel.new()
	chain_panel.setup(doc)
	chain_panel.custom_minimum_size.y = 322
	vsplit.add_child(chain_panel)

	engine.attach(self)
	_status = AWTheme.dim_label(("Audio Workstation: engine %s, dry playback" % engine.core.call("get_version"))
		if engine.is_available() else "Audio Workstation: engine not built, so there is no sound (see BUILDING.md)", 0.6)
	add_child(_status)
	doc.message.connect(func(t: String) -> void: _status.text = t)

	_dialog = FileDialog.new()
	_dialog.file_selected.connect(_on_dialog_path)
	_dialog.dir_selected.connect(_on_dialog_path)
	doc.relink_requested.connect(func(clip: AWClip, mode: String) -> void:
		_relink_clip = clip
		_show_dialog("relink_" + mode))
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().filesystem_changed.connect(doc.refresh_sources)
	browser = AWSoundBrowser.new()
	add_child(browser)
	browser.import_chosen.connect(func(paths: PackedStringArray, copy: bool) -> void:
		doc.import_files(paths, int(_import_at.x), _import_at.y, copy))
	doc.import_requested.connect(open_import)
	# Files dragged in from the system file manager (Explorer) onto the clip grid.
	get_window().files_dropped.connect(_on_os_files_dropped)
	add_child(_dialog)
	_build_confirm()
	_build_recovery_prompt()
	set_process(true)


## Narrow column left of the timeline: reserved for future tools (per the sketch).
func _make_reserved_column() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 34
	panel.tooltip_text = "Reserved for future tools"
	var col := VBoxContainer.new()
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(26, 26)
	slot.modulate = Color(1, 1, 1, 0.35)
	col.add_child(slot)
	panel.add_child(col)
	return panel


func _process(delta: float) -> void:
	engine.process(delta)
	doc.tick_recovery(delta)
	if is_visible_in_tree():
		doc.tick_preview(delta)


# --- Shortcuts ----------------------------------------------------------------
# Keys the curve graph handles itself (when it has focus) never reach this point.

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var ctrl := k.ctrl_pressed or k.meta_pressed
	var handled := true
	match k.keycode:
		KEY_SPACE: doc.play_pause()
		KEY_ENTER, KEY_KP_ENTER: doc.stop()
		KEY_HOME: doc.seek(0.0)
		KEY_L: doc.toggle_loop()
		KEY_G: doc.toggle_snap()
		KEY_S:
			if ctrl:
				_on_request("save")
			else:
				doc.split_selected_at_playhead()
		KEY_D:
			if ctrl:
				doc.duplicate_selected()
			else:
				handled = false
		KEY_A:
			if ctrl:
				doc.select_all_clips()
			else:
				handled = false
		KEY_DELETE, KEY_BACKSPACE: doc.delete_selected_clips()
		KEY_ESCAPE: doc.clear_selection()
		KEY_F: timeline.fit_all()
		_: handled = false
	if handled:
		get_viewport().set_input_as_handled()


# --- File actions -------------------------------------------------------------

## Runs `then` now, or after the user has decided what to do with unsaved changes.
func ask_discard(then: Callable) -> void:
	if not doc.is_dirty():
		then.call()
		return
	_pending_after_ask = then
	_confirm.dialog_text = "Save changes to %s before continuing?" % (doc.project_path.get_file() if doc.project_path != "" else "the untitled sound")
	_confirm.popup_centered()


func _build_confirm() -> void:
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Unsaved Changes"
	_confirm.ok_button_text = "Save"
	_confirm.add_button("Don't Save", true, "discard")
	_confirm.confirmed.connect(func() -> void:
		var then := _pending_after_ask
		_pending_after_ask = Callable()
		if doc.project_path != "":
			if doc.save_project(doc.project_path) and then.is_valid():
				then.call()
		else:
			_after_save = then
			_on_request("save_as"))
	_confirm.custom_action.connect(func(act: StringName) -> void:
		if act == &"discard":
			_confirm.hide()
			var then := _pending_after_ask
			_pending_after_ask = Callable()
			if then.is_valid():
				then.call())
	_confirm.canceled.connect(func() -> void: _pending_after_ask = Callable())
	add_child(_confirm)


## Offers the sound that was being edited when the editor last closed without saving.
func _build_recovery_prompt() -> void:
	if not AWRecovery.exists() or (OS.get_environment("AW_TEST") != "" and not recovery_prompt_in_tests):
		return
	var info := AWRecovery.info()
	var when := Time.get_datetime_string_from_unix_time(int(info.time), true) if info.time > 0.0 else "earlier"
	var what: String = info.original.get_file() if info.original != "" else "an untitled sound"
	_recovery = ConfirmationDialog.new()
	_recovery.title = "Restore Unsaved Work?"
	_recovery.dialog_text = "The editor closed before %s was saved (last change %s). Restore it?" % [what, when]
	_recovery.ok_button_text = "Restore"
	_recovery.cancel_button_text = "Discard"
	_recovery.confirmed.connect(func() -> void: doc.restore_recovery())
	_recovery.canceled.connect(AWRecovery.discard)
	add_child(_recovery)
	_recovery.popup_centered.call_deferred()


## Opens the Import Sound browser; chosen sounds land on `row` (one row each) at `t`.
func open_import(row := -1, t := -1.0) -> void:
	_import_at = Vector2(row if row >= 0 else (doc.project.max_row() + 1 if not doc.project.clips.is_empty() else 0), t if t >= 0.0 else doc.playhead_sec)
	browser.dest_hint = AWImporter.ROOT.path_join(AWImporter.sound_folder(doc.project_path, doc.project.title)) + "/"
	browser.open()


func _on_os_files_dropped(files: PackedStringArray) -> void:
	if not is_visible_in_tree():
		return
	var grid := timeline.grid
	var at := grid.get_local_mouse_position()
	if not Rect2(Vector2.ZERO, grid.size).has_point(at):
		return
	drop_os_files(files, at)


## Imports files dropped from the system file manager at a position on the grid.
func drop_os_files(files: PackedStringArray, at: Vector2) -> void:
	var grid := timeline.grid
	var t := maxf(0.0, doc.snap(grid.view.x_to_time(at.x)))
	doc.import_files(files, grid.row_at(at.y), t, AWImporter.copy_by_default())


## Opens a saved sound from the FileSystem dock (after asking about unsaved changes).
func open_from_editor(path: String) -> void:
	ask_discard(func() -> void: doc.load_project(path))


## Saves for Ctrl+S in the editor: the open sound if it has a file, otherwise asks where.
func save_from_editor() -> void:
	if doc.is_dirty():
		_on_request("save")


func toolbar_update_cpu() -> void:
	if _toolbar:
		_toolbar.update_cpu()


func _on_request(action: String) -> void:
	match action:
		"new":
			ask_discard(doc.new_project)
			return
		"open":
			ask_discard(func() -> void: _show_dialog("open"))
			return
		"save":
			if doc.project_path != "":
				doc.save_project(doc.project_path)
				return
			action = "save_as"
		"export":
			doc.export_now()
			return
		"import":
			open_import()
			return
	_show_dialog(action)


func _show_dialog(action: String) -> void:
	_dialog_action = action
	_dialog.clear_filters()
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	match action:
		"open":
			_dialog.title = "Open Sound"
			_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_dialog.add_filter("*.tres, *.res", "Audio Workstation Sound")
		"save_as":
			_dialog.title = "Save Sound As"
			_dialog.add_filter("*.tres, *.res", "Audio Workstation Sound")
		"relink_file":
			_dialog.title = "Find the Sound File"
			_dialog.access = FileDialog.ACCESS_FILESYSTEM
			_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_dialog.add_filter("*.wav, *.ogg, *.mp3", "Audio file")
		"relink_folder":
			_dialog.title = "Search This Folder for the Missing Files"
			_dialog.access = FileDialog.ACCESS_FILESYSTEM
			_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		"export_browse":
			_dialog.title = "Export To"
			_dialog.add_filter("*.wav, *.ogg", "Audio file")
	_dialog.popup_centered_ratio(0.6)


func _on_dialog_path(path: String) -> void:
	match _dialog_action:
		"open":
			doc.load_project(path)
		"save_as":
			if path.get_extension().to_lower() not in ["tres", "res"]:
				path += ".tres"
			var ok := doc.save_project(path)
			var then := _after_save
			_after_save = Callable()
			if ok and then.is_valid():
				then.call()
		"relink_file":
			doc.relink_clip(_relink_clip, ProjectSettings.localize_path(path))
		"relink_folder":
			doc.relink_in_folder(ProjectSettings.localize_path(path))
		"export_browse": doc.set_export_path(path.trim_prefix("res://"))


