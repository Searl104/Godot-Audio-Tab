@tool
extends EditorPlugin
## Registers the "Audio" main-screen tab (next to 2D / 3D / Script).

const MainScreen := preload("res://addons/audio_workstation/ui/aw_main_screen.gd")

var _main_screen: MainScreen
var _export_dock: EditorDock
var _detail_dock: EditorDock
var _lfo_dock: EditorDock
var _file_menu: AWFileMenu


func _enter_tree() -> void:
	_main_screen = MainScreen.new()
	_main_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_screen.setup(self)
	EditorInterface.get_editor_main_screen().add_child(_main_screen)
	# The Export group lives in a real editor dock the user can move, float or close.
	_export_dock = EditorDock.new()
	_export_dock.title = "Audio Export"
	_export_dock.layout_key = "audio_workstation_export"
	_export_dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	_export_dock.custom_minimum_size = Vector2(260, 0)
	_export_dock.add_child(_main_screen.export_panel)
	add_dock(_export_dock)
	# A custom effect panel (Low Pass, EQ ...) opens in its own dock, by default at the bottom.
	_detail_dock = EditorDock.new()
	_detail_dock.title = "Audio Effect"
	_detail_dock.layout_key = "audio_workstation_effect"
	_detail_dock.default_slot = EditorDock.DOCK_SLOT_BOTTOM
	_detail_dock.add_child(_main_screen.detail_panel)
	add_dock(_detail_dock)
	# The LFO editor and the list of all LFOs get a dock too (a tall column, so lower right by default).
	_lfo_dock = EditorDock.new()
	_lfo_dock.title = "Audio LFO"
	_lfo_dock.layout_key = "audio_workstation_lfo"
	_lfo_dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_BL
	_lfo_dock.add_child(_main_screen.lfo_panel)
	add_dock(_lfo_dock)
	_main_screen.doc.lfo_panel_changed.connect(func() -> void:
		var d := _main_screen.doc
		if (d.lfo_curve or d.lfo_list_open) and _lfo_dock:
			_lfo_dock.make_visible())
	_main_screen.doc.detail_changed.connect(func() -> void:
		if _main_screen.doc.detail_effect and _detail_dock:
			_detail_dock.make_visible())
	# FileSystem dock: right-click a sound > Edit in Audio Tab.
	_file_menu = AWFileMenu.new()
	_file_menu.screen = _main_screen
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _file_menu)
	_make_visible(false)


func _exit_tree() -> void:
	if _file_menu:
		remove_context_menu_plugin(_file_menu)
		_file_menu = null
	if _lfo_dock:
		remove_dock(_lfo_dock)
		_lfo_dock.queue_free()
		_lfo_dock = null
	if _detail_dock:
		remove_dock(_detail_dock)
		_detail_dock.queue_free()
		_detail_dock = null
	if _export_dock:
		remove_dock(_export_dock)
		_export_dock.queue_free()
		_export_dock = null
	if _main_screen:
		_main_screen.queue_free()
		_main_screen = null


## Ctrl+S in the editor saves the open sound too (when the Audio tab has unsaved changes).
func _save_external_data() -> void:
	if _main_screen and _main_screen.doc.is_dirty() and _main_screen.doc.project_path != "":
		_main_screen.doc.save_project(_main_screen.doc.project_path)


## Names the sound in the editor's "unsaved changes" list when closing.
func _get_unsaved_status(for_scene: String) -> String:
	if for_scene != "" or _main_screen == null or not _main_screen.doc.is_dirty():
		return ""
	return "Audio sound %s has unsaved changes.\nSave before closing?" % (
		_main_screen.doc.project_path.get_file() if _main_screen.doc.project_path != "" else "(untitled)")


## Double-clicking a saved sound in the FileSystem dock opens it in the Audio tab.
func _handles(object: Object) -> bool:
	return object is AWProject


func _edit(object: Object) -> void:
	var p := object as AWProject
	if p == null or _main_screen == null or p.resource_path == "":
		return
	EditorInterface.set_main_screen_editor("Audio")
	if p.resource_path != _main_screen.doc.project_path:
		_main_screen.open_from_editor(p.resource_path)


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _main_screen:
		_main_screen.visible = visible


func _get_plugin_name() -> String:
	return "Audio"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("AudioStreamPlayer", "EditorIcons")
