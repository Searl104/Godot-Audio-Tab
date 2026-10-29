@tool
extends EditorPlugin
## Registers the "Audio" main-screen tab (next to 2D / 3D / Script).

const MainScreen := preload("res://addons/audio_workstation/ui/aw_main_screen.gd")

var _main_screen: MainScreen


func _enter_tree() -> void:
	_main_screen = MainScreen.new()
	_main_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_screen.setup(self)
	EditorInterface.get_editor_main_screen().add_child(_main_screen)
	_make_visible(false)


func _exit_tree() -> void:
	if _main_screen:
		_main_screen.queue_free()
		_main_screen = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _main_screen:
		_main_screen.visible = visible


func _get_plugin_name() -> String:
	return "Audio"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("AudioStreamPlayer", "EditorIcons")
