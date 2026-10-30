@tool
class_name AWImporter
extends RefCounted
## Brings sound files into a sound. Files already in the project are used where they are. Files
## from elsewhere on disk are copied to res://audio_workstation_imports/<sound name>/ (the default,
## so the sound keeps working on other machines and in version control) or referenced in place.

const ROOT := "res://audio_workstation_imports"
const PREF_COPY := "audio_workstation/import/copy_into_project"
const PREF_LAST_DIR := "audio_workstation/browser/last_dir"
const PREF_FAVORITES := "audio_workstation/browser/favorites"
const PREF_AUTOPLAY := "audio_workstation/browser/autoplay"
const PREFS_FILE := "user://audio_workstation_prefs.cfg"


# --- Remembered choices -------------------------------------------------------------
# Kept in the editor settings, so they follow the user across projects. Outside the editor (tests
# without it) a small config file stands in.

static func get_pref(key: String, default: Variant) -> Variant:
	if Engine.is_editor_hint():
		var es := EditorInterface.get_editor_settings()
		return es.get_setting(key) if es.has_setting(key) else default
	var cfg := ConfigFile.new()
	cfg.load(PREFS_FILE)
	return cfg.get_value("prefs", key, default)


static func set_pref(key: String, value: Variant) -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_setting(key, value)
		return
	var cfg := ConfigFile.new()
	cfg.load(PREFS_FILE)
	cfg.set_value("prefs", key, value)
	cfg.save(PREFS_FILE)


static func copy_by_default() -> bool:
	return bool(get_pref(PREF_COPY, true))


# --- Paths ---------------------------------------------------------------------------

## The res:// path for a file inside the project folder, or "" for one outside it.
static func project_path_of(path: String) -> String:
	if path.begins_with("res://"):
		return path
	if path.begins_with("user://"):
		return ""
	var local := ProjectSettings.localize_path(path.replace("\\", "/"))
	return local if local.begins_with("res://") else ""


## True for a clip source outside the project (it won't travel with the project).
static func is_external(path: String) -> bool:
	return path != "" and project_path_of(path) == ""


## Folder name for a sound: its file name, or its title while unsaved.
static func sound_folder(project_file: String, title: String) -> String:
	var n := project_file.get_file().get_basename() if project_file != "" else title
	n = n.strip_edges().validate_filename()
	return n if n != "" else "Untitled"


## Copies `src` into ROOT/<folder>/. An identical file already there is reused; a different one
## with the same name gets "_2", "_3"... Returns the res:// path, or "" on failure.
static func copy_into_project(src: String, folder: String) -> String:
	if not FileAccess.file_exists(src):
		return ""
	var dir := ROOT.path_join(folder)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir)) != OK:
		return ""
	var base := src.get_file().get_basename().validate_filename()
	var ext := src.get_extension().to_lower()
	var src_md5 := FileAccess.get_md5(src)
	for n in range(1, 1000):
		var dest := dir.path_join("%s%s.%s" % [base, "" if n == 1 else "_%d" % n, ext])
		if FileAccess.file_exists(dest):
			if FileAccess.get_md5(dest) == src_md5:
				return dest
			continue
		var err := DirAccess.copy_absolute(src, ProjectSettings.globalize_path(dest))
		return dest if err == OK else ""
	return ""


# --- Quick facts for the browser ----------------------------------------------------------

## {"length": seconds, "channels": n, "rate": hz, "bits": n} from a WAV header without decoding,
## or {} if it isn't a readable WAV.
static func wav_info(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 12:
		return {}
	if f.get_buffer(4).get_string_from_ascii() != "RIFF":
		return {}
	f.get_32()
	if f.get_buffer(4).get_string_from_ascii() != "WAVE":
		return {}
	var info := {}
	while f.get_position() + 8 <= f.get_length():
		var id := f.get_buffer(4).get_string_from_ascii()
		var size := f.get_32()
		var next := f.get_position() + size + (size & 1)
		if id == "fmt ":
			f.get_16()
			info.channels = f.get_16()
			info.rate = f.get_32()
			f.get_32()
			var align := f.get_16()
			info.bits = f.get_16()
			info.align = maxi(align, 1)
		elif id == "data" and info.has("rate"):
			info.length = float(size) / float(info.align) / float(maxi(info.rate, 1))
			return info
		f.seek(next)
	return {}
