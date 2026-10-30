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


func setup(plugin: EditorPlugin) -> void:
	engine = AWEngine.new()
	doc = AWDocument.new(plugin.get_undo_redo(), engine)
	doc.set_project(AWProject.create_default())


func _ready() -> void:
	name = "AudioWorkstation"
	add_theme_constant_override("separation", 2)

	var toolbar := AWToolbar.new()
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
	add_child(_dialog)
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


# --- File actions (dialogs only; the handlers are stubs) ----------------------

func _on_request(action: String) -> void:
	match action:
		"new":
			doc.new_project()
			return
		"save":
			if doc.project_path != "":
				doc.save_project(doc.project_path)
				return
			action = "save_as"
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
		"export_wav":
			_dialog.title = "Export WAV"
			_dialog.access = FileDialog.ACCESS_FILESYSTEM
			_dialog.add_filter("*.wav", "WAV")
		"export_browse":
			_dialog.title = "Export To"
			_dialog.access = FileDialog.ACCESS_RESOURCES
			_dialog.add_filter("*.wav", "WAV")
		"export_stream":
			_dialog.title = "Export as AudioStream"
			_dialog.add_filter("*.tres, *.res", "AudioStreamWAV resource")
	_dialog.popup_centered_ratio(0.6)


func _on_dialog_path(path: String) -> void:
	match _dialog_action:
		"open": doc.load_project(path)
		"save_as":
			doc.project_path = path
			doc.save_project(path)
		"export_wav": doc.export_wav(path)
		"export_browse": doc.set_export_path(path.trim_prefix("res://"))
		"export_stream": doc.export_audio_stream(path)
