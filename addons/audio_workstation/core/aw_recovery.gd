@tool
class_name AWRecovery
extends RefCounted
## A copy of the sound being edited, written a few seconds after changes, so a crash or a forced
## quit doesn't lose work. Removed when the sound is saved or deliberately discarded.

const PATH := "user://audio_workstation_recovery.tres"
const INFO := "user://audio_workstation_recovery.cfg"


static func exists() -> bool:
	return FileAccess.file_exists(PATH)


## Writes the recovery copy. `original` is the file the sound was opened from ("" if never saved).
static func write(project: AWProject, original: String) -> Error:
	var err := AWProjectIO.save(project, PATH, false)
	if err != OK:
		return err
	var cfg := ConfigFile.new()
	cfg.set_value("recovery", "original", original)
	cfg.set_value("recovery", "time", Time.get_unix_time_from_system())
	return cfg.save(INFO)


## {"original": String, "time": float} of the pending recovery copy.
static func info() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(INFO) != OK:
		return {"original": "", "time": 0.0}
	return {"original": str(cfg.get_value("recovery", "original", "")), "time": float(cfg.get_value("recovery", "time", 0.0))}


static func discard() -> void:
	for f in [PATH, INFO]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
