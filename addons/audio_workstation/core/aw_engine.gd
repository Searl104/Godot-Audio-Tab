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
## Milestone 2: dry playback. Sources are decoded here (AWSourceCache), a plan of clip voices
## is built from the project and handed to the core, and an AudioStreamPlayer fed by the core's
## AWPreviewStream plays it. Automation, effects and baking arrive in later milestones.

signal playback_state_changed(playing: bool)
## Emitted by the engine while playing; the UI follows it.
signal position_changed(seconds: float)
signal render_finished(path: String, error: int)

const CORE_CLASS := &"AWCore"

var _peak_cache := {}
var _sources: AWSourceCache
var _project: AWProject
var _player: AudioStreamPlayer
var _plan_dirty := true
var _dirty_age := 0.0
var _audition := false
var _was_playing := false
var _last_reported_frame := -1
## The native core instance, or null when the library isn't loaded.
var core: Object = null
## Set when a library is loaded but too old for this plugin (rebuild it); "" otherwise.
var outdated_version := ""


func _init() -> void:
	if ClassDB.class_exists(CORE_CLASS) and ClassDB.can_instantiate(CORE_CLASS):
		var c: Object = ClassDB.instantiate(CORE_CLASS)
		# A library built for an older plugin version lacks the methods this plugin calls: don't use it.
		if c.has_method("set_plan") and c.has_method("add_source") and c.has_method("get_api_level") and int(c.call("get_api_level")) >= 5:
			core = c
			core.call("set_sample_rate", AudioServer.get_mix_rate())
			_sources = AWSourceCache.new(core)
		else:
			outdated_version = str(c.call("get_version"))


func is_available() -> bool:
	return core != null


## Version and build details of the native core ({} when it isn't available).
func get_info() -> Dictionary:
	return core.call("get_build_info") if core else {}


func status_text() -> String:
	if core:
		return "Engine %s" % core.call("get_version")
	return "Engine %s is out of date" % outdated_version if outdated_version != "" else "Engine not built"


func status_tooltip() -> String:
	if core == null and outdated_version != "":
		return "The loaded engine library (version %s) is older than this plugin needs.\nRebuild it from the extension/ folder (see BUILDING.md) and restart the editor." % outdated_version
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


## Timing contract (what the plan builder implements):
##   - A clip starts at clip.start_sec (project time) and plays its audio from
##     clip.source_offset_sec at rate 2^(pitch/12), pitch = chain.value_at(effects[0], "pitch_semitones", s).
##   - Its curves are evaluated at clip time s = clip.project_to_local(project_t), i.e. they run
##     on the clip's audio clock, slower when pitched down. Master curves use project time.
##   - Fades and length_sec are in clip time too; clip.end_sec() is where it ends on the timeline.
## Milestone 2 plays the dry clips: offset, length, fades, pitch-as-rate, and the static Gain
## and Pan of the Clip card. Automation of those and the effect chains arrive in milestone 3/4.
func set_project(project: AWProject) -> void:
	_project = project
	_plan_dirty = true
	_apply_loop()


## Called after any edit so the engine can refresh what it plays.
func project_edited(_structural: bool) -> void:
	_plan_dirty = true


## Creates the preview player under `host` and starts it (it plays silence until the core plays).
func attach(host: Node) -> void:
	if core == null or _player != null:
		return
	var stream: AudioStream = ClassDB.instantiate(&"AWPreviewStream")
	if stream == null:
		return
	stream.call("set_core", core)
	_player = AudioStreamPlayer.new()
	_player.name = "AWPreview"
	_player.stream = stream
	host.add_child(_player)
	_player.play()


## Called every frame by the main screen: refreshes the plan, follows the playhead.
func process(delta: float) -> void:
	if core == null:
		return
	if _plan_dirty and not _audition:
		_dirty_age += delta
		if _dirty_age >= 0.05:
			_rebuild_plan()
	var now_playing: bool = core.call("is_playing")
	var frame: int = core.call("get_position")
	if now_playing and not _audition and frame != _last_reported_frame:
		_last_reported_frame = frame
		position_changed.emit(frame / _rate())
	if _was_playing and not now_playing:
		if _audition:
			_audition = false
			_plan_dirty = true
			_apply_loop()
		else:
			position_changed.emit(frame / _rate())
			playback_state_changed.emit(false)
	_was_playing = now_playing


func play(from_sec: float) -> void:
	if core == null:
		playback_state_changed.emit(true)
		return
	_audition = false
	_apply_loop()
	_rebuild_plan()
	core.call("play", int(round(from_sec * _rate())))
	_was_playing = true
	playback_state_changed.emit(true)


func stop() -> void:
	if core:
		core.call("stop")
		_was_playing = false
		if _audition:
			_audition = false
			_plan_dirty = true
			_apply_loop()
	playback_state_changed.emit(false)


func seek(seconds: float) -> void:
	if core and not _audition:
		core.call("seek", int(round(seconds * _rate())))


func set_loop(_enabled: bool, _start_sec: float, _end_sec: float) -> void:
	_apply_loop()


## Previews a single clip from its start (e.g. on double-click). The project plan is restored
## when it ends.
func audition_clip(clip: AWClip) -> void:
	if core == null or clip == null or clip.source_path == "":
		return
	var voice := _voice_for(clip, 0)
	if voice.is_empty():
		return
	_audition = true
	core.call("set_loop", false, 0, 0)
	core.call("set_plan", [voice])
	core.call("play", 0)
	_was_playing = true


## Real peaks (0..1) of a source file, `per_second` buckets per second. Empty when the engine
## isn't built or the file can't be decoded; callers then use the placeholder.
func get_peaks(path: String, per_second: float) -> PackedFloat32Array:
	if _sources == null:
		return PackedFloat32Array()
	return _sources.get_peaks(path, per_second)


## Normalised placeholder peaks (0..1) used when there are no real ones. A deterministic
## impact-shaped pseudo-waveform keyed by name.
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


## Source length in seconds, or 0 if unknown.
func get_source_length(path: String) -> float:
	return AWSourceCache.stream_length(path)


## Renders [from_sec, from_sec + length_sec) of the current plan, offline. Used by tests and
## (later) baking. Needs the native core.
func render_preview_range(from_sec: float, length_sec: float) -> PackedVector2Array:
	if core == null:
		return PackedVector2Array()
	_rebuild_plan()
	return core.call("render_range", int(round(from_sec * _rate())), int(round(length_sec * _rate())))


func render_wav(_path: String) -> Error:
	return ERR_UNAVAILABLE # TODO(logic): offline render of the whole sound (milestone 5).


func render_audio_stream(_path: String) -> Error:
	return ERR_UNAVAILABLE # TODO(logic): bake to an AudioStreamWAV resource (milestone 5).


# --- Plan building ---------------------------------------------------------------

const RATE_STEP := 64 # frames between playback-rate table entries

var _table_cache := {} # AWCurve -> [signature, PackedFloat32Array]


func _rate() -> float:
	return float(core.call("get_sample_rate"))


func _apply_loop() -> void:
	if core == null or _project == null or _audition:
		return
	var r := _rate()
	core.call("set_loop", _project.loop_enabled, int(round(_project.loop_start_sec * r)),
		int(round(_project.loop_end_sec * r)))


func _rebuild_plan() -> void:
	_plan_dirty = false
	_dirty_age = 0.0
	if core == null or _project == null:
		return
	var voices: Array = []
	for clip in _project.clips:
		if clip.muted:
			continue
		var v := _voice_for(clip, int(round(clip.start_sec * _rate())))
		if not v.is_empty():
			voices.append(v)
	core.call("set_plan", voices, _master_plan())


## One voice for the native core. start_frame is where the clip lands on the timeline.
## Gain, Pan and Pitch come as tables over clip time (a single entry when there is no curve).
func _voice_for(clip: AWClip, start_frame: int) -> Dictionary:
	var r := _rate()
	var ch := clip.chain
	var src: AWEffect = ch.effects[0] if (ch and not ch.effects.is_empty()) else null
	var step_sec := RATE_STEP / r
	var voice := {
		"source": _sources.get_id(clip.source_path) if clip.source_path != "" else -1,
		"start_frame": start_frame,
		"offset": clip.source_offset_sec * r,
		"length": clip.length_sec * r,
		"fade_in": clip.fade_in_sec * r,
		"fade_out": clip.fade_out_sec * r,
		"rate_step": RATE_STEP,
		"rates": _rates(clip, src, step_sec),
	}
	if src:
		voice["gains"] = _table(ch, src, "gain_db", clip.length_sec, step_sec, AWSampler.GAIN)
		voice["pans"] = _table(ch, src, "pan", clip.length_sec, step_sec, AWSampler.VALUE)
	# Past its own end a ringing chain keeps going until the export marker.
	var tail_sec := maxf(0.0, _end_sec() - (clip.start_sec + clip.play_length())) if chain_rings(ch) else 0.0
	var fx := _clip_effects(clip, step_sec, tail_sec)
	if not fx.is_empty():
		voice["effects"] = fx
		voice["tail_frames"] = int(tail_sec * r)
	return voice


## Where the sound ends (the export marker), in seconds.
func _end_sec() -> float:
	return _project.export_end_resolved() if _project != null else 0.0


## True when a chain has a card that keeps sounding after the clip ends (so it gets a tail).
static func chain_rings(chain: AWChain) -> bool:
	if chain == null:
		return false
	for i in range(1, chain.effects.size()):
		var e: AWEffect = chain.effects[i]
		if not e.bypass and AWEffectLibrary.engine_rings(e.effect_type):
			return true
	return false


## A clip's effect chain after its Clip card. Parameter tables are over elapsed timeline time
## since the clip started (they stretch with Pitch, and run on through the tail).
func _clip_effects(clip: AWClip, step_sec: float, tail_sec: float) -> Array:
	var ch := clip.chain
	var out: Array = []
	if ch == null or ch.effects.size() < 2:
		return out
	var n := int(ceilf((clip.play_length() + tail_sec) / step_sec)) + 2
	var warp := clip.warp()
	var wsig := AWClipWarp.signature(clip)
	for i in range(1, ch.effects.size()):
		var e: AWEffect = ch.effects[i]
		if e.bypass or AWEffectLibrary.engine_id(e.effect_type) == 0:
			continue
		var tables: Array = []
		for key: String in AWEffectLibrary.engine_keys(e.effect_type):
			tables.append(_fx_table(ch, e, key, warp, wsig, n, step_sec))
		out.append({"type": AWEffectLibrary.engine_id(e.effect_type), "params": tables, "step": RATE_STEP})
	return out


## A card parameter over elapsed timeline time: curve values at the matching clip times.
func _fx_table(chain: AWChain, effect: AWEffect, param: String, warp: AWClipWarp, wsig: Array, count: int, step_sec: float) -> PackedFloat32Array:
	var curve := chain.get_curve(effect.id, param)
	var out := PackedFloat32Array()
	if curve == null or chain.get_keys(curve).is_empty():
		out.append(effect.get_param(param))
		return out
	var sig := [_curve_signature(chain, curve, 0.0, step_sec, AWSampler.VALUE), wsig, count]
	var hit: Array = _table_cache.get(curve, [])
	if hit.size() == 2 and hit[0] == sig:
		return hit[1]
	var times := PackedFloat64Array()
	times.resize(count)
	for i in count:
		times[i] = warp.unwarp(i * step_sec)
	out = AWSampler.values_at(chain, curve, times, AWSampler.VALUE)
	_table_cache[curve] = [sig, out]
	return out


## Pitch as a playback-rate table. Same rule as AWClipWarp: a curve with two or more keys
## drives the rate, otherwise it is the static value (a single entry).
func _rates(clip: AWClip, src: AWEffect, step_sec: float) -> PackedFloat32Array:
	var ch := clip.chain
	if src != null:
		var c := ch.get_curve(src.id, "pitch_semitones")
		if c != null and ch.get_keys(c).size() >= 2:
			return _table(ch, src, "pitch_semitones", clip.length_sec, step_sec, AWSampler.RATE)
	return AWClipWarp.rate_table(clip, clip.length_sec, step_sec)


## The Output card's volume over project time, for the core's master gain.
func _master_plan() -> Dictionary:
	if _project == null:
		return {}
	if _project.master_chain == null or _project.master_chain.effects.is_empty():
		return {"end_frame": int(round(_end_sec() * _rate()))}
	var mc := _project.master_chain
	var out: AWEffect = mc.effects[0]
	var r := _rate()
	var step_sec := RATE_STEP / r
	var plan := {
		"gains": _table(mc, out, "volume_db", _project.content_end_sec(), step_sec, AWSampler.GAIN),
		"step": RATE_STEP,
	}
	var fx: Array = []
	var length_sec := maxf(_project.content_end_sec(), _end_sec())
	for i in range(1, mc.effects.size()):
		var e: AWEffect = mc.effects[i]
		if e.bypass or AWEffectLibrary.engine_id(e.effect_type) == 0:
			continue
		var tables: Array = []
		for key: String in AWEffectLibrary.engine_keys(e.effect_type):
			tables.append(_table(mc, e, key, length_sec, step_sec, AWSampler.VALUE))
		fx.append({"type": AWEffectLibrary.engine_id(e.effect_type), "params": tables, "step": RATE_STEP})
	if not fx.is_empty():
		plan["effects"] = fx
	# The sound ends at the export marker, whatever the clips and tails add up to.
	plan["end_frame"] = int(round(_end_sec() * r))
	return plan


## Samples a parameter every `step_sec` over 0..length_sec (curve value, LFO included) and
## converts each value for the engine (an AWSampler unit). Without a curve: one entry, the
## static value. Tables are cached per curve and rebuilt only when that curve's keys, LFO,
## scale or the length change.
func _table(chain: AWChain, effect: AWEffect, param: String, length_sec: float, step_sec: float, unit: int) -> PackedFloat32Array:
	var curve := chain.get_curve(effect.id, param)
	var out := PackedFloat32Array()
	if curve == null or chain.get_keys(curve).is_empty():
		out.append(_static_value(effect.get_param(param), unit))
		return out
	var sig := _curve_signature(chain, curve, length_sec, step_sec, unit)
	var hit: Array = _table_cache.get(curve, [])
	if hit.size() == 2 and hit[0] == sig:
		return hit[1]
	out = AWSampler.values(chain, curve, 0.0, step_sec, int(ceilf(length_sec / step_sec)) + 2, unit)
	_table_cache[curve] = [sig, out]
	return out


static func _static_value(v: float, unit: int) -> float:
	match unit:
		AWSampler.GAIN:
			return 0.0 if v <= -59.9 else db_to_linear(v)
		AWSampler.RATE:
			return AWClipWarp.rate_for(v)
	return v


## Identifies what a curve's table depends on, so unchanged curves are not re-sampled.
static func _curve_signature(chain: AWChain, curve: AWCurve, length_sec: float, step_sec: float, unit: int) -> Array:
	var l := curve.lfo
	var lfo: Array = []
	if l != null and l.enabled:
		lfo = [l.shape, l.max_value, l.min_value, l.freq_hz, l.fade_in_sec, l.fade_out_sec, l.start_sec, l.end_sec, l.random_seed, l.freq_accel, l.fade_smoothing]
	return [hash(chain.get_keys(curve)), curve.scale, chain.curve_range(curve), snappedf(length_sec, 0.0001), step_sec, unit, lfo]
