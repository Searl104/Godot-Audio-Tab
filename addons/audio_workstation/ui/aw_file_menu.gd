@tool
class_name AWFileMenu
extends EditorContextMenuPlugin
## FileSystem dock right-click: "Edit in Audio Tab" on a sound file starts a new sound around it.

var screen: Control # AWMainScreen


func _popup_menu(paths: PackedStringArray) -> void:
	if first_audio(paths) == "":
		return
	var icon := EditorInterface.get_editor_theme().get_icon(&"AudioStreamPlayer", &"EditorIcons") if Engine.is_editor_hint() else null
	add_context_menu_item("Edit in Audio Tab", _on_edit, icon)


func _on_edit(paths: Array) -> void:
	var p := first_audio(PackedStringArray(paths))
	if p != "" and screen:
		screen.call("edit_sound_file", p)


static func first_audio(paths: PackedStringArray) -> String:
	for p in paths:
		if AWDocument.AUDIO_EXTENSIONS.has(p.get_extension().to_lower()):
			return p
	return ""
