@tool
class_name AWEngine
extends RefCounted
## The boundary between the UI and the audio engine.
##
## The per-sample work happens in the native core (C++ GDExtension class `AWCore`, built
## from extension/). It is looked up by name through ClassDB, never referenced as a type,
## so the plugin still loads when the library hasn't been built: the UI then shows
## "Engine not built" and the stubs below keep everything else working.
##
## Milestone 1: the core is detected and reachable (version, build info, test render).
## Playback, automation and baking arrive in later milestones (see TODO(logic)).

signal playback_state_changed(playing: bool)
## Emitted by the engine while playing; the UI follows it.
signal position_changed(seconds: float)
signal render_finished(path: String, error: int)

const CORE_CLASS := &"AWCore"

var _peak_cache := {}
## The native core instance, or null when the library isn't loaded.
var core: Object = null


func _init() -> void:
	if ClassDB.class_exists(CORE_CLASS) and ClassDB.can_instantiate(CORE_CLASS):
		core = ClassDB.instantiate(CORE_CLASS)
		core.call("set_sample_rate", AudioServer.get_mix_rate())


func is_available() -> bool:
	return core != null


## Version and build details of the native core ({} when it isn't available).
func get_info() -> Dictionary:
	return core.call("get_build_info") if core else {}


func status_text() -> String:
	return "Engine %s" % core.call("get_version") if core else "Engine not built"


func status_tooltip() -> String:
	if core == null:
		return "The native audio engine (GDExtension) isn't loaded.\nBuild it from the extension/ folder (see BUILDING.md), then restart the editor.\nEditing works without it; playback and export need it."
	var i := get_info()
	return "Native audio engine loaded\nversion %s · godot-cpp %s · API %s · %s\n%s\nbuilt %s\nrender rate %d Hz" % [
		i.get("version"), i.get("godot_cpp"), i.get("api"), i.get("target"), i.get("compiler"), i.get("built"), int(core.call("get_sample_rate"))]


## Renders `frames` stereo frames from the core (a test tone if `tone_hz` > 0).
## Used by the self-test to prove the path end to end. Returns [] without the core.
func render_test(frames: int, tone_hz := 0.0, gain_db := -12.0) -> PackedVector2Array:
	if core == null:
		return PackedVector2Array()
	core.call("reset")
	core.call("set_test_tone", tone_hz, gain_db)
	return core.call("render", frames)


## Timing contract for the logic phase:
##   - A clip starts at clip.start_sec (project time) and plays its audio from
##     clip.source_offset_sec at rate 2^(pitch/12), pitch = chain.value_at(effects[0], "pitch_semitones", s).
##   - Its curves are evaluated at clip time s = clip.project_to_local(project_t), i.e. they run
##     on the clip's audio clock, slower when pitched down. Master curves use project time.
##   - Fades and length_sec are in clip time too; clip.end_sec() is where it ends on the timeline.
func set_project(_project: AWProject) -> void:
	pass # TODO(logic): build the playback graph (one player per clip, chains, master).


## Called after any edit so the engine can refresh what it plays.
func project_edited(_structural: bool) -> void:
	pass # TODO(logic)


func play(_from_sec: float) -> void:
	playback_state_changed.emit(true) # TODO(logic)


func stop() -> void:
	playback_state_changed.emit(false) # TODO(logic)


func seek(_seconds: float) -> void:
	pass # TODO(logic)


func set_loop(_enabled: bool, _start_sec: float, _end_sec: float) -> void:
	pass # TODO(logic)


## Previews a single clip from its start (e.g. on double-click). TODO(logic)
func audition_clip(_clip: AWClip) -> void:
	pass


## Normalised peaks (0..1), `bucket_count` buckets across the whole source file.
## PLACEHOLDER: a deterministic impact-shaped pseudo-waveform. TODO(logic): real peaks.
func get_waveform_peaks(key: String, bucket_count: int = 256) -> PackedFloat32Array:
	var cache_key := "%s|%d" % [key, bucket_count]
	if _peak_cache.has(cache_key):
		return _peak_cache[cache_key]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var peaks := PackedFloat32Array()
	peaks.resize(bucket_count)
	var decay := rng.randf_range(2.0, 5.0)
	for i in bucket_count:
		var x := float(i) / bucket_count
		var env := exp(-x * decay) * 0.85 + 0.15
		peaks[i] = clampf(env * rng.randf_range(0.55, 1.0), 0.0, 1.0)
	_peak_cache[cache_key] = peaks
	return peaks


## Source length in seconds, or 0 if unknown. Only reads the imported stream's length.
func get_source_length(path: String) -> float:
	if path == "" or not ResourceLoader.exists(path):
		return 0.0
	var stream := ResourceLoader.load(path) as AudioStream
	return stream.get_length() if stream else 0.0


func render_wav(_path: String) -> Error:
	return ERR_UNAVAILABLE # TODO(logic): offline render of the whole sound.


func render_audio_stream(_path: String) -> Error:
	return ERR_UNAVAILABLE # TODO(logic): bake to an AudioStreamWAV resource.
