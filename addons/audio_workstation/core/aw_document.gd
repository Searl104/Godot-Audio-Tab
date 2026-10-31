@tool
class_name AWDocument
extends RefCounted
## Shared state for the whole tab: project, selection, which chain is shown, curve view
## settings, transport, and every edit operation. All model edits go through
## EditorUndoRedoManager. View-only toggles (curve On/Dim/Off, solo) are not undoable.
##
## Interface phase: file I/O, playback and export are stubs (see TODO(logic)).

## Model changed. structural = items added/removed/reordered (UI rebuilds), else values only.
signal project_changed(structural: bool)
signal selection_changed
## Chain tab switched, or a different clip's chain is now shown.
signal chain_target_changed
## Curve visibility, solo, active curve or key selection changed (view state).
signal curve_view_changed
## Clip mode / curve mode switched (the curve layer over the grid).
signal edit_mode_changed
## Fit both axes of the timeline (F, Fit button, Frame Curves).
signal fit_requested
signal playhead_changed
signal transport_changed
signal message(text: String)
## The LFO panel opened, closed, or switched curve.
signal lfo_panel_changed
## Export bit depth, tail or file name changed (not a sound edit, so no plan rebuild).
signal file_state_changed
## A missing clip asked to be relinked: mode "file" (pick the file) or "folder" (search a folder).
signal relink_requested(clip: AWClip, mode: String)
## The grid asked to import sounds at a row and time (the main screen opens the sound browser).
signal import_requested(row: int, t: float)
signal export_settings_changed
signal export_progress(fraction: float)
signal export_finished(result: Dictionary)
## The effect shown in the detail panel dock changed (or was closed).
signal detail_changed

## MASTER: the master chain. CLIP: the focused clip on its own (no shared chain). CHAIN: a shared chain.
enum ChainTab { MASTER, CLIP, CHAIN, GROUP }
enum CurveTime { CLIP, PROJECT }
## Which layer of the timeline is edited: clips on the grid, or the curves drawn over it.
enum EditMode { CLIPS, CURVES }

const AUDIO_EXTENSIONS := ["wav", "ogg", "mp3"]
const MIN_LEN := 0.01
## [label, seconds]; 0 = off.
const SNAP_OPTIONS := [
	["Off", 0.0], ["1 ms", 0.001], ["10 ms", 0.01], ["50 ms", 0.05],
	["100 ms", 0.1], ["250 ms", 0.25], ["500 ms", 0.5], ["1 s", 1.0],
	["24 fps", 1.0 / 24.0], ["30 fps", 1.0 / 30.0], ["60 fps", 1.0 / 60.0],
]
## Object snapping (while snap is on): which targets attract, and their remembered defaults.
const SNAP_TARGETS := [["edges", "Clip Edges", true], ["playhead", "Playhead", true], ["markers", "Markers", true], ["transients", "Transients", false]]
## How close (pixels) a target must be to win over the time grid.
const SNAP_PX := 8.0

var project: AWProject
var engine: AWEngine
## True while an export is rendering.
var exporting := false
var _exporter: AWExporter
var undo_redo: EditorUndoRedoManager
var project_path := ""
## What the last Open had to repair (for the tests and the status line).
var last_repairs: Array = []
var _saved_version := 0
var _touched := false

# Transport
var playing := false
var playhead_sec := 0.0

# Selection
var selection: Array[AWClip] = []
## The clip whose chain the Clip tab shows. Stays set when the grid selection is cleared.
var focus_clip: AWClip = null
var chain_tab := ChainTab.CLIP
## The shared chain shown when chain_tab is CHAIN.
var tab_chain: AWChain = null
## On a chain tab: the curve view shows the focused clip's own curves (Gain, Pitch, Pan) instead
## of the chain's.
var curve_on_clip := false

# Curves (view state)
## Curves are always drawn in project time on the shared timeline (since 0.18).
var curve_time := CurveTime.PROJECT
## On the GROUP tab: the group whose chain is shown.
var tab_group: AWGroup = null
var edit_mode := EditMode.CLIPS
## Vertical view of the curve layer (0..1 curve heights).
var value_view := AWValueView.new()
var active_curve: AWCurve = null
var solo_curve: AWCurve = null
## Curve whose LFO panel is open (null = closed).
var lfo_curve: AWCurve = null
## True only while show_lfo_list() is announcing itself; the plugin reacts by showing the Audio LFO dock.
var lfo_list_open := false

# Views
var timeline_view := AWTimeView.new()
## The curve layer shares the grid's time axis (one timeline).
var curve_view := timeline_view
var snap_sec := 0.05
var _last_snap := 0.05


func _init(p_undo_redo: EditorUndoRedoManager, p_engine: AWEngine) -> void:
	undo_redo = p_undo_redo
	engine = p_engine
	engine.position_changed.connect(func(s: float) -> void:
		playhead_sec = s
		playhead_changed.emit())
	# The engine can stop on its own (end of the sound), so follow its state.
	engine.playback_state_changed.connect(func(p: bool) -> void:
		if p != playing:
			playing = p
			transport_changed.emit())
	timeline_view.content_end = func() -> float: return project.content_end_sec() + 1.0
	project_changed.connect(func(structural: bool) -> void:
		for c in project.clips:
			c.invalidate_warp() # a static Pitch change alters timing too
		engine.project_edited(structural))


# --- Project / file stubs -----------------------------------------------------

func set_project(p: AWProject) -> void:
	project = p
	_recompute_missing()
	selection.clear()
	focus_clip = p.clips[p.clips.size() - 1] if not p.clips.is_empty() else null
	# The chain panel shows the new sound: its last clip's chain, or nothing.
	tab_chain = focus_clip.fx_chain if focus_clip else null
	chain_tab = ChainTab.CHAIN if tab_chain else ChainTab.CLIP
	curve_on_clip = false
	active_curve = null
	solo_curve = null
	lfo_curve = null
	clear_time_selection()
	edit_mode = EditMode.CLIPS
	value_view.reset()
	playhead_sec = 0.0
	engine.set_project(p)
	project_changed.emit(true)
	selection_changed.emit()
	chain_target_changed.emit()
	curve_view_changed.emit()
	edit_mode_changed.emit()
	playhead_changed.emit()
	transport_changed.emit()


func new_project() -> void:
	_cancel_export_for_switch()
	AWRecovery.discard()
	project_path = ""
	set_project(AWProject.create_default())
	_reset_history()
	message.emit("New sound.")


## Writes the project to `path` (a .tres or .res). Returns true on success.
func save_project(path: String) -> bool:
	var err := AWProjectIO.save(project, path)
	if err != OK:
		message.emit("Couldn't save %s: %s." % [path, error_string(err)])
		return false
	project_path = path
	_mark_clean()
	message.emit("Saved %s." % path.get_file())
	if Engine.is_editor_hint():
		AWExporter.tell_editor(path, false) # a saved sound is a plain resource: no import step
	return true


## Opens a saved sound, replacing the current one (the caller asks about unsaved changes first).
## Damaged files are repaired as far as possible; the status line says what was changed.
func load_project(path: String) -> bool:
	var r := AWProjectIO.open(path)
	if not r.ok:
		message.emit(str(r.error))
		return false
	_cancel_export_for_switch()
	AWRecovery.discard()
	set_project(r.project)
	project_path = path
	_reset_history()
	var repairs: Array = r.repairs
	if repairs.is_empty():
		message.emit("Opened %s." % path.get_file())
	else:
		message.emit("Opened %s. Repaired %d thing%s: %s" % [path.get_file(), repairs.size(), "" if repairs.size() == 1 else "s", str(repairs[0])])
	last_repairs = repairs
	var missing := missing_paths()
	if not missing.is_empty():
		message.emit("%s %d sound file%s can't be found. Those clips are marked in red and stay silent; right-click one to relink." % [_status_head(path, repairs), missing.size(), "" if missing.size() == 1 else "s"])
	return true


func _status_head(path: String, repairs: Array) -> String:
	return "Opened %s." % path.get_file() + (" Repaired %d thing%s." % [repairs.size(), "" if repairs.size() == 1 else "s"] if not repairs.is_empty() else "")


# --- Missing sound files ---------------------------------------------------------

## Clips whose sound file can't be found (marked in red, silent).
var _missing := {}


func _recompute_missing() -> void:
	_missing.clear()
	if project == null:
		return
	for c in project.clips:
		if c != null and c.source_path != "" and not AWProjectIO.source_exists(c.source_path):
			_missing[c.source_path] = true


func is_clip_missing(c: AWClip) -> bool:
	return c != null and c.source_path != "" and _missing.has(c.source_path)


func missing_paths() -> PackedStringArray:
	return PackedStringArray(_missing.keys())


## Follows files that were moved or renamed in the editor (by UID) and re-checks which are missing.
func refresh_sources() -> void:
	if project == null:
		return
	var before := _missing.size()
	var moved := AWProjectIO.refresh_sources(project)
	_recompute_missing()
	if not moved.is_empty():
		touch()
		project_changed.emit(true)
		message.emit("Followed %d moved sound file%s." % [moved.size(), "" if moved.size() == 1 else "s"])
	elif before != _missing.size():
		project_changed.emit(false)


## Points every clip that uses the missing file at `new_path` (one undo step).
func relink_clip(clip: AWClip, new_path: String) -> void:
	if clip == null or new_path == "" or not AWProjectIO.source_exists(new_path):
		message.emit("That file can't be found.")
		return
	var old_path := clip.source_path
	var now: Dictionary = {}
	var was: Dictionary = {}
	for c in project.clips:
		if c.source_path == old_path:
			was[c] = [c.source_path, c.source_uid]
			now[c] = [new_path, AWProjectIO.uid_for_path(new_path)]
	_do_undo("Relink Source", _apply_sources.bind(now), _apply_sources.bind(was))
	message.emit("Relinked %d clip%s to %s." % [now.size(), "" if now.size() == 1 else "s", new_path.get_file()])


## Looks for every missing file by name under `dir` and relinks what it finds. Returns the number of
## clips relinked.
func relink_in_folder(dir: String) -> int:
	var index := AWProjectIO.index_audio_files(dir)
	var now: Dictionary = {}
	var was: Dictionary = {}
	for c in project.clips:
		if is_clip_missing(c):
			var hit: String = index.get(c.source_path.get_file(), "")
			if hit != "":
				was[c] = [c.source_path, c.source_uid]
				now[c] = [hit, AWProjectIO.uid_for_path(hit)]
	if now.is_empty():
		message.emit("None of the missing files are in %s." % dir)
		return 0
	_do_undo("Relink Sources", _apply_sources.bind(now), _apply_sources.bind(was))
	var left := missing_paths().size()
	message.emit("Relinked %d clip%s from %s. %d file%s still missing." % [now.size(), "" if now.size() == 1 else "s", dir, left, "" if left == 1 else "s"])
	return now.size()


func _apply_sources(map: Dictionary) -> void:
	for c: AWClip in map:
		c.source_path = map[c][0]
		c.source_uid = map[c][1]
	_recompute_missing()
	project_changed.emit(true)


## The file name for the title: "Untitled" when never saved, with a star while there are changes.
func file_label() -> String:
	var n := project_path.get_file() if project_path != "" else "Untitled"
	return n + ("*" if is_dirty() else "")


## True when the sound has changes that aren't in the file on disk (or it was never saved).
func is_dirty() -> bool:
	return _touched or _history().get_version() != _saved_version


## Marks changes that don't go through undo (export settings, curve display).
func touch() -> void:
	if not _touched:
		_touched = true
	file_state_changed.emit()


func _mark_clean() -> void:
	AWRecovery.discard()
	_recovery_wait = -1.0
	_touched = false
	_saved_version = _history().get_version()
	file_state_changed.emit()


# --- Recovery copy ---------------------------------------------------------------

## Seconds after the last change before the recovery copy is written.
const RECOVERY_DELAY := 5.0
var _recovery_wait := -1.0
var _recovery_version := -1
var recovery_enabled := true


## Called every frame by the main screen. Writes the recovery copy once edits have been quiet for a moment.
func tick_recovery(delta: float) -> void:
	if not recovery_enabled or project == null:
		return
	if not is_dirty():
		_recovery_wait = -1.0
		return
	var v := _history().get_version()
	if v != _recovery_version:
		_recovery_version = v
		_recovery_wait = RECOVERY_DELAY
		return
	if _recovery_wait < 0.0:
		return
	_recovery_wait -= delta
	if _recovery_wait <= 0.0:
		_recovery_wait = -1.0
		write_recovery()


func write_recovery() -> bool:
	return AWRecovery.write(project, project_path) == OK


## Brings back the sound from the recovery copy. It counts as unsaved.
func restore_recovery() -> bool:
	var info := AWRecovery.info()
	var r := AWProjectIO.open(AWRecovery.PATH)
	if not r.ok:
		message.emit("The recovery copy couldn't be opened: %s" % str(r.error))
		AWRecovery.discard()
		return false
	_cancel_export_for_switch()
	set_project(r.project)
	project_path = str(info.original)
	_reset_history()
	_touched = true
	_recovery_version = -1
	last_repairs = r.repairs
	file_state_changed.emit()
	message.emit("Restored your unsaved work. Save it to keep it.")
	return true


func _reset_history() -> void:
	_history().clear_history()
	_mark_clean()
	transport_changed.emit()


func _cancel_export_for_switch() -> void:
	if exporting:
		cancel_export()


func set_export_bit_depth(bits: int) -> void:
	project.export_bit_depth = bits
	touch()
	export_settings_changed.emit()


## Places the export end marker (undoable). Negative = back to automatic.
func set_export_end(sec: float) -> void:
	var v := -1.0 if sec < 0.0 else clampf(sec, 0.0, AWProject.MAX_END_SEC)
	set_props(project, {"export_end_sec": v}, "Set Export End")


## Picks the file format and swaps the extension of the file name to match.
func set_export_format(format: String) -> void:
	if not AWProject.FORMATS.has(format):
		return
	project.export_format = format
	var p := project.export_path
	var old := p.get_extension().to_lower()
	if p.strip_edges() == "":
		pass # automatic: the name follows the format by itself
	elif AWProject.FORMATS.has(old) or old == "":
		project.export_path = (p.get_basename() if old != "" else p.trim_suffix(".")) + "." + format
	touch()
	export_settings_changed.emit()


func set_export_ogg_quality(q: float) -> void:
	project.export_ogg_quality = clampf(q, 0.0, 10.0)
	touch()
	export_settings_changed.emit()


func set_export_path(path: String) -> void:
	project.export_path = path.strip_edges()
	touch()
	export_settings_changed.emit()


## The automatic export file: in the saved sound's folder, named after the sound, e.g.
## res://sfx/door_slam.tres -> res://sfx/door_slam.wav. Unsaved: res://<title>.wav.
func export_auto_path() -> String:
	var dir := project_path.get_base_dir() if project_path != "" else "res://"
	var base := project_path.get_file().get_basename() if project_path != "" else project.title
	base = base.strip_edges().validate_filename().replace(" ", "_")
	if base == "":
		base = "sound"
	return dir.path_join(base + "." + project.export_format)


## The export file as a loadable path: relative names live under res://; empty = automatic.
func export_target() -> String:
	var p := project.export_path.strip_edges().replace("\\", "/")
	if p == "":
		return export_auto_path()
	if p.begins_with("res://") or p.begins_with("user://") or p.is_absolute_path():
		return p
	return "res://" + p.lstrip("/")


func export_will_overwrite() -> bool:
	var t := export_target()
	return t != "" and FileAccess.file_exists(t)


## Where the exported sound ends (the marker). Matches the engine's plan end.
func export_end_sec() -> float:
	return project.export_end_resolved()


func export_length_sec() -> float:
	return export_end_sec()


func export_size_bytes() -> int:
	var frames := int(ceil(export_length_sec() * AudioServer.get_mix_rate()))
	match project.export_format:
		"ogg":
			return int(export_length_sec() * AWProject.ogg_kbps(project.export_ogg_quality) * 125.0)
		_:
			return frames * 2 * (project.export_bit_depth / 8) + (56 if project.export_bit_depth == 32 else 44)


func export_now() -> void:
	var t := export_target()
	if t == "":
		message.emit("Enter a file name to export to.")
		return
	export_wav(t)


## Renders the whole sound to a WAV (see AWExporter). Only one export at a time.
func export_wav(path: String) -> void:
	if exporting:
		return
	exporting = true
	_exporter = AWExporter.new()
	_exporter.progress.connect(func(f: float) -> void: export_progress.emit(f))
	export_settings_changed.emit()
	var r: Dictionary = await _exporter.run(project, path, project.export_bit_depth, project.export_format, project.export_ogg_quality)
	_exporter = null
	exporting = false
	export_settings_changed.emit()
	export_finished.emit(r)
	message.emit(AWExporter.summary(r))


func cancel_export() -> void:
	if _exporter != null:
		_exporter.cancel()


# --- Undo / redo --------------------------------------------------------------

func _history() -> UndoRedo:
	return undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)


func undo() -> void:
	_history().undo()
	transport_changed.emit()


func redo() -> void:
	_history().redo()
	transport_changed.emit()


func can_undo() -> bool:
	return _history().has_undo()


func can_redo() -> bool:
	return _history().has_redo()


func _begin(action_name: String) -> void:
	undo_redo.create_action(action_name)


func _commit() -> void:
	undo_redo.commit_action()
	transport_changed.emit() # refreshes undo/redo buttons


# EditorUndoRedoManager wants (object, method, args...), so unpack bound Callables.
func _add_do(c: Callable) -> void:
	undo_redo.callv("add_do_method", [c.get_object(), c.get_method()] + c.get_bound_arguments())


func _add_undo(c: Callable) -> void:
	undo_redo.callv("add_undo_method", [c.get_object(), c.get_method()] + c.get_bound_arguments())


func _do_undo(action_name: String, do_call: Callable, undo_call: Callable) -> void:
	_begin(action_name)
	_add_do(do_call)
	_add_undo(undo_call)
	_commit()


## Undoable property change on any model object.
func set_props(obj: Object, props: Dictionary, action_name := "") -> void:
	var old := {}
	var changed := false
	for key: String in props:
		old[key] = obj.get(key)
		if old[key] != props[key]:
			changed = true
	if not changed:
		return
	if action_name == "":
		action_name = "Edit " + ", ".join(PackedStringArray(props.keys()))
	_do_undo(action_name, _apply_props.bind(obj, props), _apply_props.bind(obj, old))


## Live preview while dragging: changes the object without creating an undo step.
func preview_set(obj: Object, props: Dictionary) -> void:
	_apply_props(obj, props)


## Finishes a drag of several objects as one undo step.
## items: Array of [object, original_props_dict].
func commit_drags(items: Array, action_name: String) -> void:
	var changed := false
	for it: Array in items:
		for key: String in it[1]:
			if it[0].get(key) != it[1][key]:
				changed = true
	if not changed:
		return
	_begin(action_name)
	for it: Array in items:
		var now := {}
		for key: String in it[1]:
			now[key] = it[0].get(key)
		_add_do(_apply_props.bind(it[0], now))
		_add_undo(_apply_props.bind(it[0], it[1]))
	_commit()


func _apply_props(obj: Object, props: Dictionary) -> void:
	for key: String in props:
		obj.set(key, props[key])
	if obj == project:
		engine.set_loop(project.loop_enabled, project.loop_start_sec, project.loop_end_sec)
		transport_changed.emit()
	project_changed.emit(false)


# --- Transport ----------------------------------------------------------------

func play_pause() -> void:
	playing = not playing
	if playing:
		engine.play(playhead_sec)
	else:
		engine.stop()
	transport_changed.emit()


func stop() -> void:
	if playing:
		playing = false
		engine.stop()
	elif playhead_sec != 0.0:
		seek(0.0)
	transport_changed.emit()


func seek(t: float) -> void:
	playhead_sec = maxf(0.0, t)
	engine.seek(playhead_sec)
	playhead_changed.emit()


# Scrubbing (drag on the ruler): the playhead follows the mouse, the audio follows like tape.
var scrubbing := false


func scrub_begin(t: float) -> void:
	if playing:
		stop()
	scrubbing = true
	engine.scrub_begin(playhead_sec)
	scrub_to(t)


func scrub_to(t: float) -> void:
	playhead_sec = maxf(0.0, t)
	engine.scrub_to(playhead_sec)
	playhead_changed.emit()


func scrub_end() -> void:
	if not scrubbing:
		return
	scrubbing = false
	engine.scrub_end()
	seek(playhead_sec)


func toggle_loop() -> void:
	set_props(project, {"loop_enabled": not project.loop_enabled}, "Toggle Loop")


## Fallback clock so the playhead still moves when the native engine isn't built. With the
## engine, the position comes from AWEngine.position_changed instead.
func tick_preview(delta: float) -> void:
	if not playing or engine.is_available():
		return
	playhead_sec += delta
	var end := project.loop_end_sec if project.loop_enabled else project.content_end_sec()
	if playhead_sec >= end:
		if project.loop_enabled:
			playhead_sec = project.loop_start_sec
		else:
			playhead_sec = end
			playing = false
			transport_changed.emit()
	playhead_changed.emit()


func format_clock(t: float) -> String:
	return "%02d:%06.3f" % [int(t / 60.0), fmod(t, 60.0)]


# --- Snap ---------------------------------------------------------------------

func snap(t: float) -> float:
	return t if snap_sec <= 0.0 else roundf(t / snap_sec) * snap_sec


func set_snap(value: float) -> void:
	snap_sec = value
	if value > 0.0:
		_last_snap = value
	transport_changed.emit()
	timeline_view.changed.emit()


func toggle_snap() -> void:
	set_snap(_last_snap if snap_sec <= 0.0 else 0.0)


func snap_target_on(key: String) -> bool:
	for t: Array in SNAP_TARGETS:
		if t[0] == key:
			return bool(AWImporter.get_pref("audio_workstation/snap/" + key, t[2]))
	return false


func set_snap_target(key: String, on: bool) -> void:
	AWImporter.set_pref("audio_workstation/snap/" + key, on)
	timeline_view.changed.emit()
	transport_changed.emit()


## Times that attract while snapping (project time), leaving out `exclude` clips' own edges.
func snap_targets(exclude: Array = []) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if snap_sec <= 0.0:
		return out
	if snap_target_on("edges"):
		for c in project.clips:
			if not exclude.has(c):
				out.append(c.start_sec)
				out.append(c.end_sec())
	if snap_target_on("playhead"):
		out.append(playhead_sec)
	if snap_target_on("markers"):
		for m in project.markers:
			out.append(m.time_sec)
	if snap_target_on("transients"):
		for c in project.clips:
			if not exclude.has(c):
				out.append_array(clip_transients(c))
	return out


## Snaps `t`: to the nearest target within SNAP_PX pixels, else to the time grid. `targets` from
## snap_targets(). Returns t unchanged with snap off.
func snap_to(t: float, targets: PackedFloat64Array) -> float:
	if snap_sec <= 0.0:
		return t
	var reach := SNAP_PX / maxf(timeline_view.pixels_per_sec, 1e-6)
	var best := INF
	var hit := t
	for x in targets:
		var d := absf(x - t)
		if d < best:
			best = d
			hit = x
	return hit if best <= reach else snap(t)


## Like snap_to for a span: moves `start` so that either its start or its end (start + length)
## lands on a target; the time grid applies to the start otherwise. Returns the new start.
func snap_span(start: float, length: float, targets: PackedFloat64Array) -> float:
	if snap_sec <= 0.0:
		return start
	var reach := SNAP_PX / maxf(timeline_view.pixels_per_sec, 1e-6)
	var best := INF
	var shift := 0.0
	for x in targets:
		for edge in [start, start + length]:
			var d := absf(x - edge)
			if d < best:
				best = d
				shift = x - edge
	return start + shift if best <= reach else snap(start)


# --- Transients -----------------------------------------------------------------------

const TRANSIENT_RATE := 200.0 # envelope frames per second
var _transient_cache := {} # source path -> PackedFloat64Array of source times


## Onsets in a sound file (seconds in the file): where the level jumps well above the recent average.
func source_transients(path: String) -> PackedFloat64Array:
	if _transient_cache.has(path):
		return _transient_cache[path]
	var out := PackedFloat64Array()
	var env := engine.get_peaks(path, TRANSIENT_RATE)
	var avg := 0.0
	var last := -1e9
	var top := 0.0
	for v in env:
		top = maxf(top, v)
	var floor_level := maxf(top * 0.06, 0.003)
	for i in env.size():
		var v := env[i]
		var t := i / TRANSIENT_RATE
		if v > floor_level and v > avg * 2.2 + 0.01 and t - last > 0.06:
			# The onset starts where the rise begins: step back while the level keeps falling.
			var j := i
			while j > 0 and env[j - 1] < env[j] and i - j < 4:
				j -= 1
			out.append(j / TRANSIENT_RATE)
			last = t
		avg = avg * 0.85 + v * 0.15
	_transient_cache[path] = out
	return out


## A clip's transients in project time (only those inside the part that plays).
func clip_transients(c: AWClip) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if c.source_path == "":
		return out
	for st in source_transients(c.source_path):
		var local := (c.source_offset_sec + c.length_sec - st) if c.reversed else (st - c.source_offset_sec)
		if local > 0.0005 and local < c.length_sec:
			out.append(c.local_to_project(local))
	return out


# --- Time selection ---------------------------------------------------------------------

## Selected time range (Shift+drag on the ruler), project time; x < 0 = none. Not saved.
var time_sel := Vector2(-1.0, -1.0)
signal time_selection_changed


func has_time_selection() -> bool:
	return time_sel.x >= 0.0 and time_sel.y > time_sel.x + 1e-6


func set_time_selection(a: float, b: float) -> void:
	time_sel = Vector2(maxf(0.0, minf(a, b)), maxf(0.0, maxf(a, b)))
	time_selection_changed.emit()
	timeline_view.changed.emit()


func clear_time_selection() -> void:
	if time_sel.x < 0.0:
		return
	time_sel = Vector2(-1.0, -1.0)
	time_selection_changed.emit()
	timeline_view.changed.emit()


## A clip cut at project times `cuts` (inside it): [left props for the clip itself, right pieces].
## Pieces keep their sound, curves and LFOs where they were.
func _cut(clip: AWClip, cuts: Array) -> Array:
	var work := clip.duplicate_clip()
	var pieces: Array[AWClip] = []
	var sorted := cuts.duplicate()
	sorted.sort()
	sorted.reverse() # cut from the right, so the left part keeps its start
	for t: float in sorted:
		var local := work.project_to_local(t)
		if local <= MIN_LEN or local >= work.length_sec - MIN_LEN:
			continue
		var right := work.duplicate_clip()
		right.start_sec = t
		right.length_sec = work.length_sec - local
		right.source_offset_sec = work.source_offset_sec if work.reversed else work.source_offset_sec + local
		right.fade_in_sec = 0.0
		for c in right.chain.curves:
			right.chain.set_keys(c, _shifted(right.chain.get_keys(c), -local))
			if c.lfo:
				c.lfo.start_sec -= local
				c.lfo.end_sec -= local
		if work.reversed:
			work.source_offset_sec += work.length_sec - local
		work.length_sec = local
		work.fade_out_sec = 0.0
		work.invalidate_warp()
		pieces.push_front(right)
	return [{"length_sec": work.length_sec, "fade_out_sec": work.fade_out_sec, "source_offset_sec": work.source_offset_sec}, pieces]


## Splits every clip (not on locked rows) at both edges of the time selection. One undo step.
func split_at_time_selection() -> int:
	return _cut_time_selection(false)


## Removes the audio inside the time selection from every clip (not on locked rows): clips are cut
## at the edges and the parts inside are deleted. Nothing moves. One undo step.
func delete_in_time_selection() -> int:
	return _cut_time_selection(true)


func _cut_time_selection(remove_inside: bool) -> int:
	if not has_time_selection():
		message.emit("Shift+drag on the ruler to select a time range first.")
		return 0
	var a := time_sel.x
	var b := time_sel.y
	var touched := 0
	_begin("Delete Inside Selection" if remove_inside else "Split at Selection")
	for clip in project.clips.duplicate():
		if project.row_locked(clip.row) or clip.end_sec() <= a + 1e-6 or clip.start_sec >= b - 1e-6:
			continue
		var cuts := []
		for t in [a, b]:
			if t > clip.start_sec + 1e-6 and t < clip.end_sec() - 1e-6:
				cuts.append(t)
		var res := _cut(clip, cuts)
		var left: Dictionary = res[0]
		var pieces: Array[AWClip] = res[1]
		var old := {"length_sec": clip.length_sec, "fade_out_sec": clip.fade_out_sec, "source_offset_sec": clip.source_offset_sec}
		var keep_left := true
		if remove_inside and clip.start_sec >= a - 1e-6:
			keep_left = false # the clip's first part lies inside
		if not cuts.is_empty() or not keep_left:
			touched += 1
		if keep_left:
			if not cuts.is_empty():
				_add_do(_apply_props.bind(clip, left))
				_add_undo(_apply_props.bind(clip, old))
		else:
			_add_do(_apply_remove_clip.bind(clip))
			_add_undo(_apply_insert_clip.bind(clip, project.clips.find(clip)))
		var idx := project.clips.find(clip) + 1
		for p in pieces:
			var inside := p.start_sec >= a - 1e-6 and p.start_sec < b - 1e-6
			if remove_inside and inside:
				continue
			_add_do(_apply_insert_clip.bind(p, idx))
			_add_undo(_apply_remove_clip.bind(p))
			idx += 1
	_commit()
	message.emit(("Removed the audio inside the selection from %d clip%s." if remove_inside else "Split %d clip%s at the selection.") % [touched, "" if touched == 1 else "s"])
	return touched


## Loops the time selection.
func loop_time_selection() -> void:
	if has_time_selection():
		set_props(project, {"loop_start_sec": time_sel.x, "loop_end_sec": time_sel.y, "loop_enabled": true}, "Loop Selection")


# --- Markers ----------------------------------------------------------------------------

## Adds a marker (at the playhead by default). One undo step. Returns it.
func add_marker(t := -1.0, marker_name := "") -> AWMarker:
	if t < 0.0:
		t = playhead_sec
	var m := AWMarker.create(t, marker_name if marker_name != "" else "Marker %d" % (project.markers.size() + 1))
	_do_undo("Add Marker", _apply_add_marker.bind(m), _apply_remove_marker.bind(m))
	message.emit("Added %s at %s (M). Drag it on the ruler; double-click to rename; right-click to delete." % [m.name, format_clock(t)])
	return m


func remove_marker(m: AWMarker) -> void:
	_do_undo("Delete Marker", _apply_remove_marker.bind(m), _apply_add_marker.bind(m))


func _apply_add_marker(m: AWMarker) -> void:
	if not project.markers.has(m):
		project.markers.append(m)
	sort_markers()
	project_changed.emit(false)


func _apply_remove_marker(m: AWMarker) -> void:
	project.markers.erase(m)
	project_changed.emit(false)


func sort_markers() -> void:
	project.markers.sort_custom(func(a: AWMarker, b: AWMarker) -> bool: return a.time_sec < b.time_sec)


## Moves the playhead to the next (dir = 1) or previous (dir = -1) marker.
func jump_marker(dir: int) -> void:
	var best := -1.0
	for m in project.markers:
		if dir > 0 and m.time_sec > playhead_sec + 1e-4 and (best < 0.0 or m.time_sec < best):
			best = m.time_sec
		elif dir < 0 and m.time_sec < playhead_sec - 1e-4 and (best < 0.0 or m.time_sec > best):
			best = m.time_sec
	if best >= 0.0:
		seek(best)


## Adds clips for sound files from anywhere on disk, one row each, starting at `row` / `t`.
## Files outside the project are copied into it when `copy` is true, else used where they are.
func import_files(paths: PackedStringArray, row: int, t: float, copy: bool) -> Array[AWClip]:
	var added: Array[AWClip] = []
	var copied := 0
	var external := 0
	var failed := PackedStringArray()
	var folder := AWImporter.sound_folder(project_path, project.title)
	for p in paths:
		if not is_audio_file(p):
			continue
		var use := AWImporter.project_path_of(p)
		if use == "":
			if copy:
				use = AWImporter.copy_into_project(p, folder)
				if use == "":
					failed.append(p.get_file())
					continue
				copied += 1
				if Engine.is_editor_hint():
					AWExporter.tell_editor(use, false)
			else:
				use = p.replace("\\", "/")
				external += 1
		added.append(add_clip_from_path(use, row, t))
		row += 1
	if not added.is_empty():
		set_selection(added)
	var msg := "Added %d sound%s." % [added.size(), "" if added.size() == 1 else "s"]
	if copied > 0:
		msg += " Copied %d into %s." % [copied, AWImporter.ROOT.path_join(folder).trim_prefix("res://")]
	if external > 0:
		msg += " %d stay%s outside the project (marked; right-click > Copy Into Project to bring %s in)." % [external, "s" if external == 1 else "", "it" if external == 1 else "them"]
	if not failed.is_empty():
		msg += " Couldn't copy: %s." % ", ".join(failed)
	message.emit(msg)
	return added


func is_clip_external(c: AWClip) -> bool:
	return c != null and AWImporter.is_external(c.source_path)


## Copies an outside file into the project and points every clip that uses it there (one undo step).
func copy_clip_into_project(clip: AWClip) -> void:
	if not is_clip_external(clip):
		return
	var dest := AWImporter.copy_into_project(clip.source_path, AWImporter.sound_folder(project_path, project.title))
	if dest == "":
		message.emit("Couldn't copy %s into the project." % clip.source_path.get_file())
		return
	if Engine.is_editor_hint():
		AWExporter.tell_editor(dest, false)
	relink_clip(clip, dest)


func is_audio_file(path: String) -> bool:
	return path.get_extension().to_lower() in AUDIO_EXTENSIONS


# --- Clip selection -----------------------------------------------------------

func select_clip(clip: AWClip, mode := "replace") -> void:
	selected_group = null
	var members := group_members(clip)
	match mode:
		"replace":
			if selection.size() == members.size() and members.all(func(m: AWClip) -> bool: return selection.has(m)):
				_focus(clip)
				return
			selection = members
		"add":
			for m in members:
				if not selection.has(m):
					selection.append(m)
		"toggle":
			if selection.has(clip):
				for m in members:
					selection.erase(m)
			else:
				for m in members:
					if not selection.has(m):
						selection.append(m)
	selection_changed.emit()
	if selection.has(clip):
		_focus(clip)


func set_selection(clips: Array[AWClip]) -> void:
	selected_group = null
	selection = []
	for c in clips:
		for m in group_members(c):
			if not selection.has(m):
				selection.append(m)
	selection_changed.emit()
	if not selection.is_empty():
		_focus(selection.back())


## Selecting a clip selects only that clip (since 0.19); the group strip selects a whole group.
func group_members(clip: AWClip) -> Array[AWClip]:
	return [clip] as Array[AWClip]


# --- Groups (frames on the grid) ------------------------------------------------
# A group is a frame: clips that start inside its time span on its rows belong to it, live.

## The group whose strip was clicked (its clips are selected too), or null.
var selected_group: AWGroup = null

signal groups_changed


## Selects a group: its clips, and the group itself (so Delete / Ctrl+Shift+G act on it).
func select_group(g: AWGroup) -> void:
	selected_group = g
	selection = project.group_clips(g) if g else ([] as Array[AWClip])
	selection_changed.emit()
	groups_changed.emit()
	if not selection.is_empty():
		_focus(selection.back())


## Frames the selected clips (Ctrl+G): from the first start to the last end, over their rows.
func group_selected() -> AWGroup:
	if selection.is_empty():
		message.emit("Select one or more clips to group them.")
		return null
	var s := INF
	var e := -INF
	var r0 := 1 << 30
	var r1 := -1
	for c in selection:
		s = minf(s, c.start_sec)
		e = maxf(e, c.end_sec())
		r0 = mini(r0, c.row)
		r1 = maxi(r1, c.row)
	if project.group_overlaps(s, e, r0, r1):
		message.emit("A group can't overlap another group.")
		return null
	var g := AWGroup.new()
	g.name = _unique_group_name("Group %d" % (project.groups.size() + 1))
	g.start_sec = s
	g.end_sec = maxf(e, s + 0.05)
	g.row = r0
	g.row_count = r1 - r0 + 1
	g.color = selection[0].color
	_do_undo("Group Clips", _apply_add_group.bind(g, project.groups.size()), _apply_remove_group.bind(g))
	select_group(g)
	message.emit("Grouped %d clips. Drag the strip to move the group, the ▼ grip in its corner to add rows." % selection.size())
	return g


## Removes the selected group, or the groups of the selected clips (the clips stay).
func ungroup_selected() -> void:
	var gs: Array[AWGroup] = []
	if selected_group:
		gs.append(selected_group)
	for c in selection:
		var g := project.group_of(c)
		if g and not gs.has(g):
			gs.append(g)
	if gs.is_empty():
		return
	_begin("Ungroup")
	for g in gs:
		_add_do(_apply_remove_group.bind(g))
		_add_undo(_apply_add_group.bind(g, project.groups.find(g)))
	_commit()
	selected_group = null
	groups_changed.emit()
	message.emit("Ungrouped %d group%s." % [gs.size(), "" if gs.size() == 1 else "s"])


func remove_group(g: AWGroup) -> void:
	_do_undo("Remove Group", _apply_remove_group.bind(g), _apply_add_group.bind(g, project.groups.find(g)))


func _unique_group_name(base: String) -> String:
	var names := {}
	for g in project.groups:
		names[g.name] = true
	var n := project.groups.size() + 1
	var nm := base
	while names.has(nm):
		n += 1
		nm = "Group %d" % n
	return nm


func _apply_add_group(g: AWGroup, index: int) -> void:
	if not project.groups.has(g):
		project.groups.insert(clampi(index, 0, project.groups.size()), g)
	groups_changed.emit()
	project_changed.emit(true)


func _apply_remove_group(g: AWGroup) -> void:
	project.groups.erase(g)
	if selected_group == g:
		selected_group = null
	if chain_tab == ChainTab.GROUP and tab_group == g:
		chain_tab = ChainTab.CLIP
		tab_group = null
		_reset_curve_focus()
		chain_target_changed.emit()
	groups_changed.emit()
	project_changed.emit(true)


## True when `g` could take this frame without overlapping another group.
func group_frame_ok(g: AWGroup, s: float, e: float, r0: int, r1: int) -> bool:
	return s >= 0.0 and e > s and r0 >= 0 and r1 >= r0 and not project.group_overlaps(s, e, r0, r1, g)


## Moves a group by dt seconds and drow rows, with its clips. Refused (false) if it would overlap
## another group. Undoable when `commit`; otherwise a live preview (the caller commits later).
func move_group(g: AWGroup, dt: float, drow: int) -> bool:
	dt = maxf(dt, -g.start_sec)
	drow = maxi(drow, -g.row)
	if not group_frame_ok(g, g.start_sec + dt, g.end_sec + dt, g.row + drow, g.last_row() + drow):
		return false
	var items: Array = [[g, {"start_sec": g.start_sec, "end_sec": g.end_sec, "row": g.row}]]
	for c in project.group_clips(g):
		items.append([c, {"start_sec": c.start_sec, "row": c.row}])
		c.start_sec += dt
		c.row += drow
	g.start_sec += dt
	g.end_sec += dt
	g.row += drow
	commit_drags(items, "Move Group")
	groups_changed.emit()
	return true


## Live frame change during a drag (no undo step); returns false (and changes nothing) if the frame
## would overlap another group. `clips` move along by dt / drow (a moved group's clips).
func preview_group(g: AWGroup, frame: Dictionary, clips: Array = [], orig: Dictionary = {}, dt := 0.0, drow := 0) -> bool:
	var s: float = frame.get("start_sec", g.start_sec)
	var e: float = frame.get("end_sec", g.end_sec)
	var r: int = frame.get("row", g.row)
	var n: int = frame.get("row_count", g.row_count)
	if not group_frame_ok(g, s, e, r, r + n - 1):
		return false
	for key: String in frame:
		g.set(key, frame[key])
	for c: AWClip in clips:
		var o: Dictionary = orig[c]
		c.start_sec = o.start_sec + dt
		c.row = o.row + drow
	project_changed.emit(false)
	groups_changed.emit()
	return true


func set_group_props(g: AWGroup, props: Dictionary, action_name: String) -> void:
	set_props(g, props, action_name)
	groups_changed.emit()


## Gives a group an effect chain (one bus for all its clips) and shows its tab.
func new_group_chain(g: AWGroup) -> AWChain:
	if g.chain:
		open_group_tab(g)
		return g.chain
	var ch := AWChain.new()
	ch.name = g.name
	set_props(g, {"chain": ch}, "Add Group Chain")
	open_group_tab(g)
	return ch


func remove_group_chain(g: AWGroup) -> void:
	if g.chain == null:
		return
	set_props(g, {"chain": null}, "Remove Group Chain")
	if chain_tab == ChainTab.GROUP and tab_group == g:
		set_chain_tab(ChainTab.CLIP)


## Shows a group's chain on the chain panel (its curves run on the group's clock).
func open_group_tab(g: AWGroup) -> void:
	if g == null or g.chain == null:
		return
	if chain_tab == ChainTab.GROUP and tab_group == g:
		return
	chain_tab = ChainTab.GROUP
	tab_group = g
	tab_chain = null
	_reset_curve_focus()
	chain_target_changed.emit()


func clear_selection() -> void:
	selected_group = null
	if selection.is_empty():
		return
	selection.clear()
	selection_changed.emit()


func select_all_clips() -> void:
	set_selection(project.clips)


func is_selected(clip: AWClip) -> bool:
	return selection.has(clip)


func _focus(clip: AWClip) -> void:
	var want_tab := ChainTab.CHAIN if clip and clip.fx_chain else ChainTab.CLIP
	var want_chain: AWChain = clip.fx_chain if clip else null
	if focus_clip == clip and chain_tab == want_tab and tab_chain == want_chain:
		return
	focus_clip = clip
	chain_tab = want_tab
	tab_chain = want_chain
	tab_group = null
	_reset_curve_focus()
	chain_target_changed.emit()


# --- Which chain is shown -----------------------------------------------------

func set_chain_tab(tab: ChainTab) -> void:
	if chain_tab == tab:
		return
	chain_tab = tab
	if tab != ChainTab.CHAIN:
		tab_chain = null
	if tab != ChainTab.GROUP:
		tab_group = null
	_reset_curve_focus()
	chain_target_changed.emit()


## Shows a shared chain's tab. The focused clip stays if it uses the chain, else the first clip
## that does becomes the curves' clock.
func open_chain_tab(chain: AWChain) -> void:
	if chain == null:
		return
	if chain_tab == ChainTab.CHAIN and tab_chain == chain:
		return
	chain_tab = ChainTab.CHAIN
	tab_chain = chain
	tab_group = null
	_reset_curve_focus()
	chain_target_changed.emit()


## The chain whose cards and curves are shown.
func active_chain() -> AWChain:
	match chain_tab:
		ChainTab.MASTER:
			return project.master_chain
		ChainTab.GROUP:
			return tab_group.chain if tab_group else null
		ChainTab.CHAIN:
			var vc := view_clip()
			if curve_on_clip and vc:
				return vc.chain
			return tab_chain
	return focus_clip.chain if focus_clip else null


func active_chain_name() -> String:
	match chain_tab:
		ChainTab.MASTER:
			return "Master"
		ChainTab.GROUP:
			return tab_group.name if tab_group else ""
		ChainTab.CHAIN:
			var vc := view_clip()
			if curve_on_clip and vc:
				return vc.name
			return tab_chain.name if tab_chain else ""
	return focus_clip.name if focus_clip else ""


## The clip whose clock the curves run on: the focused clip (on a chain tab, if it uses the chain;
## otherwise the chain's first clip). Null on the master.
func view_clip() -> AWClip:
	match chain_tab:
		ChainTab.CLIP:
			return focus_clip
		ChainTab.CHAIN:
			if focus_clip and focus_clip.fx_chain == tab_chain:
				return focus_clip
			for c in project.clips:
				if c.fx_chain == tab_chain:
					return c
	return null


## On a chain tab: show the chain's curves (false) or the view clip's own (true).
func set_curve_on_clip(on: bool) -> void:
	if curve_on_clip == on:
		return
	curve_on_clip = on
	_reset_curve_focus()
	chain_target_changed.emit()


# --- Shared chains --------------------------------------------------------------------

## Clips using a chain, in timeline order.
func chain_clips(chain: AWChain) -> Array[AWClip]:
	var out: Array[AWClip] = []
	for c in project.clips:
		if c.fx_chain == chain:
			out.append(c)
	out.sort_custom(func(a: AWClip, b: AWClip) -> bool: return a.start_sec < b.start_sec or (a.start_sec == b.start_sec and a.row < b.row))
	return out


## The clips an assignment applies to: the selection (groups included) if it holds `clip`, else
## `clip` and its group.
func _assign_targets(clip: AWClip) -> Array[AWClip]:
	if clip == null:
		return selection.duplicate()
	if selection.has(clip):
		return selection.duplicate()
	return group_members(clip)


## Makes a new, empty shared chain for the selected clips (or `clip` and its group) and opens it.
## One undo step.
func new_chain_for(clip: AWClip = null) -> AWChain:
	var targets := _assign_targets(clip)
	if targets.is_empty():
		message.emit("Select one or more clips (or a group) first; the new chain is attached to them.")
		return null
	var ch := AWChain.new()
	ch.name = _unique_chain_name("Chain %d" % (project.chains.size() + 1))
	_begin("New Chain")
	_add_do(_apply_add_chain.bind(ch, project.chains.size()))
	_add_undo(_apply_remove_chain_raw.bind(ch))
	for c in targets:
		_add_do(_apply_props.bind(c, {"fx_chain": ch}))
		_add_undo(_apply_props.bind(c, {"fx_chain": c.fx_chain}))
	_commit()
	open_chain_tab(ch)
	message.emit("%s is attached to %d clip%s. Add effects with +." % [ch.name, targets.size(), "" if targets.size() == 1 else "s"])
	return ch


## Puts the selected clips (or `clip` and its group) on `chain` (null = no chain). One undo step.
func set_clip_chain(clip: AWClip, chain: AWChain) -> void:
	var targets := _assign_targets(clip)
	if targets.is_empty():
		return
	_begin("Use Chain" if chain else "Remove Chain")
	for c in targets:
		_add_do(_apply_props.bind(c, {"fx_chain": chain}))
		_add_undo(_apply_props.bind(c, {"fx_chain": c.fx_chain}))
	_commit()
	if focus_clip and targets.has(focus_clip):
		_focus_refresh()


func rename_chain(chain: AWChain, new_name: String) -> void:
	new_name = new_name.strip_edges()
	if chain and new_name != "" and new_name != chain.name:
		set_props(chain, {"name": _unique_chain_name(new_name, chain)}, "Rename Chain")


## Deletes a shared chain; its clips play dry. One undo step.
func delete_chain(chain: AWChain) -> void:
	if chain == null or not project.chains.has(chain):
		return
	var users := chain_clips(chain)
	_begin("Delete Chain")
	for c in users:
		_add_do(_apply_props.bind(c, {"fx_chain": null}))
	_add_do(_apply_remove_chain_raw.bind(chain))
	_add_undo(_apply_add_chain.bind(chain, project.chains.find(chain)))
	for c in users:
		_add_undo(_apply_props.bind(c, {"fx_chain": chain}))
	_commit()
	if tab_chain == chain:
		_focus_refresh()


## A copy of a chain (effects and curves) as a new chain on the same clips' selection. One undo step.
func duplicate_chain(chain: AWChain) -> AWChain:
	var ch := chain.duplicate(true) as AWChain
	ch.name = _unique_chain_name(chain.name + " copy")
	_do_undo("Duplicate Chain", _apply_add_chain.bind(ch, project.chains.size()), _apply_remove_chain_raw.bind(ch))
	return ch


func _apply_add_chain(ch: AWChain, index: int) -> void:
	if not project.chains.has(ch):
		project.chains.insert(clampi(index, 0, project.chains.size()), ch)
	project_changed.emit(true)


func _apply_remove_chain_raw(ch: AWChain) -> void:
	project.chains.erase(ch)
	if tab_chain == ch:
		tab_chain = null
		chain_tab = ChainTab.CLIP
		chain_target_changed.emit()
	project_changed.emit(true)


func _unique_chain_name(base: String, except: AWChain = null) -> String:
	var taken := {}
	for c in project.chains:
		if c != except:
			taken[c.name] = true
	if not taken.has(base):
		return base
	var n := 2
	while taken.has("%s %d" % [base, n]):
		n += 1
	return "%s %d" % [base, n]


## Re-runs the tab choice for the focused clip (after its chain changed).
func _focus_refresh() -> void:
	var c := focus_clip
	focus_clip = null
	if c and project.clips.has(c):
		_focus(c)
	else:
		chain_tab = ChainTab.CLIP
		tab_chain = null
		chain_target_changed.emit()


func _reset_curve_focus() -> void:
	active_curve = null
	solo_curve = null
	close_lfo()
	curve_view_changed.emit()


# --- Curve time mapping -------------------------------------------------------
# Clip curves live in clip (audio) time: 0 = the clip's first played sample, and the curves'
# playhead runs at the clip's playback rate (slower when pitched down). Master curves live in
# project time. The graph shows either clip time or project time; the warp converts.

func _clip_view() -> bool:
	return view_clip() != null


func is_clip_local_view() -> bool:
	return _clip_view() and curve_time == CurveTime.CLIP


## Project time -> the time a chain's curves are evaluated at.
func chain_local_time(chain: AWChain, project_t: float) -> float:
	for g in project.groups:
		if g.chain == chain:
			return project_t - g.start_sec
	var vc := view_clip()
	if vc and (vc.chain == chain or vc.fx_chain == chain):
		return vc.project_to_local(project_t)
	for c in project.clips:
		if c.chain == chain or c.fx_chain == chain:
			return c.project_to_local(project_t)
	return project_t


## Kept for older callers: curves are always shown in project time now.
func set_curve_time(_mode: CurveTime) -> void:
	pass


func set_edit_mode(m: EditMode) -> void:
	if edit_mode == m:
		return
	edit_mode = m
	edit_mode_changed.emit()


func toggle_edit_mode() -> void:
	set_edit_mode(EditMode.CLIPS if edit_mode == EditMode.CURVES else EditMode.CURVES)


## View time -> curve-local time.
func view_to_local(v: float) -> float:
	if _group_view():
		return v - tab_group.start_sec
	if _clip_view() and curve_time == CurveTime.PROJECT:
		return view_clip().project_to_local(v)
	return v


func local_to_view(t: float) -> float:
	if _group_view():
		return t + tab_group.start_sec
	if _clip_view() and curve_time == CurveTime.PROJECT:
		return view_clip().local_to_project(t)
	return t


## On a group's tab the curves run on the group's clock (0 = its start).
func _group_view() -> bool:
	return chain_tab == ChainTab.GROUP and tab_group != null


## View time -> project time (for the playhead and seeking).
func view_to_project(v: float) -> float:
	return view_clip().local_to_project(v) if is_clip_local_view() else v


func project_to_view(p: float) -> float:
	return view_clip().project_to_local(p) if is_clip_local_view() else p


## How far a key may be placed, in the chain's local time. Curves are not limited to the clip:
## they may run on through a tail or past it, up to the length of the automation track.
func curve_domain_len() -> float:
	return AWChain.MAX_TIME


## Where a new curve or LFO ends by default: the clip's own length (the master's content).
## Keys can be moved or added past it; beyond the last key a curve holds its value.
func curve_owner_len() -> float:
	if _group_view():
		return tab_group.span()
	if view_clip() != null:
		return view_clip().length_sec
	return project.content_end_sec() if project != null else 10.0


## The stretch curves are drawn and framed over: the clip's own length, or on through
## the export end when that lies later (so tails can be shaped). Master: the whole sound.
func curve_span_len() -> float:
	if project == null:
		return 10.0
	var end := project.export_end_resolved()
	if _group_view():
		return maxf(tab_group.span(), end - tab_group.start_sec)
	if chain_tab == ChainTab.CLIP and focus_clip != null:
		var own := focus_clip.length_sec
		if end > focus_clip.end_sec():
			own = maxf(own, view_clip().project_to_local(end))
		return own
	return maxf(project.content_end_sec(), end)


func curve_domain_end_view() -> float:
	if project == null:
		return 10.0
	return local_to_view(curve_span_len())


## Fits the timeline (both axes); in curve mode also resets the value zoom.
func frame_curves() -> void:
	if edit_mode == EditMode.CURVES:
		value_view.reset()
	fit_requested.emit()


# --- Curve display (view state, not undoable) ---------------------------------

func set_active_curve(c: AWCurve) -> void:
	if c != null:
		_show_curve_owner(c)
		set_edit_mode(EditMode.CURVES) # opening a curve shows the curve layer
	if active_curve == c:
		return
	active_curve = c
	curve_view_changed.emit()


## On a chain tab, switches the curve view between the chain and the clip's own curves so `c`
## (just made, selected or given an LFO) is visible.
func _show_curve_owner(c: AWCurve) -> void:
	if chain_tab != ChainTab.CHAIN:
		return
	var ch := active_chain()
	if ch and ch.curves.has(c):
		return
	if tab_chain and tab_chain.curves.has(c):
		curve_on_clip = false
		chain_target_changed.emit()
		return
	for clip in chain_clips(tab_chain):
		if clip.chain and clip.chain.curves.has(c):
			focus_clip = clip
			curve_on_clip = true
			chain_target_changed.emit()
			return


func is_curve_visible(c: AWCurve) -> bool:
	if solo_curve != null and active_chain() != null and active_chain().curves.has(solo_curve):
		return c == solo_curve
	return c.display != AWCurve.Display.OFF


## Visible and not dimmed: keys can be edited.
func is_curve_editable(c: AWCurve) -> bool:
	return is_curve_visible(c) and (c == solo_curve or c.display == AWCurve.Display.ON)


func cycle_curve_display(c: AWCurve) -> void:
	c.display = ((c.display + 1) % 3) as AWCurve.Display
	if c.display == AWCurve.Display.OFF and active_curve == c:
		active_curve = null
	_curve_view_edited()


func set_curve_display(c: AWCurve, mode: AWCurve.Display) -> void:
	c.display = mode
	_curve_view_edited()


func toggle_solo(c: AWCurve) -> void:
	solo_curve = null if solo_curve == c else c
	if solo_curve:
		active_curve = c
	curve_view_changed.emit()


## Mute = hide this curve (display Off). Toggles back to On.
func toggle_mute(c: AWCurve) -> void:
	c.display = AWCurve.Display.ON if c.display == AWCurve.Display.OFF else AWCurve.Display.OFF
	if solo_curve == c:
		solo_curve = null
	_curve_view_edited()


func show_all_curves() -> void:
	var ch := active_chain()
	if ch == null:
		return
	solo_curve = null
	for c in ch.curves:
		c.display = AWCurve.Display.ON
	_curve_view_edited()


func _curve_view_edited() -> void:
	curve_view_changed.emit()
	project_changed.emit(false) # the display mode is saved with the project


# --- Clip edits ---------------------------------------------------------------

func add_clip_from_path(path: String, row: int, start: float) -> AWClip:
	var used := project.clips.size()
	var clip := AWClip.create(path.get_file().get_basename(), maxf(0.0, start), 1.0, maxi(row, 0),
		AWProject.CLIP_COLORS[used % AWProject.CLIP_COLORS.size()])
	clip.source_path = path
	clip.source_uid = AWProjectIO.uid_for_path(path)
	var length := engine.get_source_length(path)
	if length > 0.0:
		clip.length_sec = length
	_do_undo("Add Clip", _apply_insert_clip.bind(clip, project.clips.size()), _apply_remove_clip.bind(clip))
	select_clip(clip)
	return clip


## Splits at project time t. The cut lands on the audio moment playing at t.
func split_clip(clip: AWClip, t: float) -> void:
	var local := clip.project_to_local(t)
	if local <= MIN_LEN or local >= clip.length_sec - MIN_LEN:
		message.emit("Put the playhead inside the clip to split it.")
		return
	var right := clip.duplicate_clip()
	right.name = clip.name + " (2)"
	right.start_sec = t
	right.length_sec = clip.length_sec - local
	# A reversed clip's first half plays the end of its source range.
	right.source_offset_sec = clip.source_offset_sec if clip.reversed else clip.source_offset_sec + local
	right.fade_in_sec = 0.0
	# Right half's curves shift so they keep playing the same values at the same moment.
	for c in right.chain.curves:
		right.chain.set_keys(c, _shifted(right.chain.get_keys(c), -local))
		if c.lfo: # keep the oscillation's phase and fades on the same moments
			c.lfo.start_sec -= local
			c.lfo.end_sec -= local
	var old := {"length_sec": clip.length_sec, "fade_out_sec": clip.fade_out_sec, "source_offset_sec": clip.source_offset_sec}
	var now := {"length_sec": local, "fade_out_sec": 0.0,
		"source_offset_sec": clip.source_offset_sec + (clip.length_sec - local) if clip.reversed else clip.source_offset_sec}
	_begin("Split Clip")
	_add_do(_apply_props.bind(clip, now))
	_add_do(_apply_insert_clip.bind(right, project.clips.find(clip) + 1))
	_add_undo(_apply_remove_clip.bind(right))
	_add_undo(_apply_props.bind(clip, old))
	_commit()


func split_selected_at_playhead() -> void:
	var targets := selection.filter(func(c: AWClip) -> bool:
		return playhead_sec > c.start_sec and playhead_sec < c.end_sec())
	if targets.is_empty():
		message.emit("Select a clip under the playhead to split it.")
	for c: AWClip in targets:
		split_clip(c, playhead_sec)


func duplicate_selected() -> void:
	if selection.is_empty():
		return
	var copies: Array[AWClip] = []
	var gids := _fresh_group_ids(selection)
	_begin("Duplicate Clips")
	for c in selection:
		var copy := c.duplicate_clip()
		copy.group_id = gids.get(c.group_id, 0)
		copy.start_sec = c.end_sec()
		copies.append(copy)
		_add_do(_apply_insert_clip.bind(copy, project.clips.size() + copies.size() - 1))
		_add_undo(_apply_remove_clip.bind(copy))
	_commit()
	set_selection(copies)


func delete_selected_clips() -> void:
	if selection.is_empty():
		return
	_begin("Delete Clips")
	var doomed := selection.duplicate()
	doomed.sort_custom(func(a: AWClip, b: AWClip) -> bool: return project.clips.find(a) < project.clips.find(b))
	for c: AWClip in doomed:
		_add_do(_apply_remove_clip.bind(c))
	doomed.reverse()
	for c: AWClip in doomed:
		_add_undo(_apply_insert_clip.bind(c, project.clips.find(c)))
	_commit()


# --- Clipboard, nudge, trim to playhead, rename, colour -------------------------------

## Copied clips (independent copies), kept while the editor runs, so they paste into another sound too.
static var clipboard: Array[AWClip] = []


func copy_selected() -> void:
	if selection.is_empty():
		return
	clipboard.clear()
	for c in _in_project_order(selection):
		clipboard.append(c.duplicate_clip())
	message.emit("Copied %d clip%s." % [clipboard.size(), "" if clipboard.size() == 1 else "s"])


func cut_selected() -> void:
	if selection.is_empty():
		return
	copy_selected()
	var n := clipboard.size()
	delete_selected_clips()
	message.emit("Cut %d clip%s." % [n, "" if n == 1 else "s"])


## Pastes the clipboard at the playhead, each clip on the row it was copied from. One undo step.
func paste() -> void:
	if clipboard.is_empty():
		message.emit("Nothing to paste. Copy clips with Ctrl+C first.")
		return
	var base := INF
	for c in clipboard:
		base = minf(base, c.start_sec)
	var pasted: Array[AWClip] = []
	var gids := _fresh_group_ids(clipboard)
	var foreign := {} # chains from another sound -> their copy here
	_begin("Paste Clips")
	for c in clipboard:
		var copy := c.duplicate_clip()
		copy.group_id = gids.get(c.group_id, 0)
		if copy.fx_chain and not project.chains.has(copy.fx_chain):
			if not foreign.has(copy.fx_chain):
				var dup := copy.fx_chain.duplicate(true) as AWChain
				dup.name = _unique_chain_name(dup.name)
				foreign[copy.fx_chain] = dup
				_add_do(_apply_add_chain.bind(dup, project.chains.size() + foreign.size() - 1))
				_add_undo(_apply_remove_chain_raw.bind(dup))
			copy.fx_chain = foreign[copy.fx_chain]
		copy.start_sec = playhead_sec + (c.start_sec - base)
		pasted.append(copy)
		_add_do(_apply_insert_clip.bind(copy, project.clips.size() + pasted.size() - 1))
		_add_undo(_apply_remove_clip.bind(copy))
	_commit()
	set_selection(pasted)
	_recompute_missing()


## New group ids for copies, so copied groups stay groups of their own (old id -> new id).
func _fresh_group_ids(clips: Array[AWClip]) -> Dictionary:
	var next := 1
	for c in project.clips:
		next = maxi(next, c.group_id + 1)
	var out := {}
	for c in clips:
		if c.group_id != 0 and not out.has(c.group_id):
			out[c.group_id] = next
			next += 1
	return out


## Mutes or unmutes the selection (or `clip` if it isn't selected), following `clip`. One undo step.
func toggle_mute_clips(clip: AWClip) -> void:
	var targets: Array[AWClip] = selection if selection.has(clip) else ([clip] as Array[AWClip])
	var to := not clip.muted
	_begin("Unmute Clips" if not to else "Mute Clips")
	for c in targets:
		_add_do(_apply_props.bind(c, {"muted": to}))
		_add_undo(_apply_props.bind(c, {"muted": c.muted}))
	_commit()


func _in_project_order(clips: Array[AWClip]) -> Array[AWClip]:
	var out := clips.duplicate()
	out.sort_custom(func(a: AWClip, b: AWClip) -> bool: return project.clips.find(a) < project.clips.find(b))
	return out


## Moves the selection by `steps` snap steps in time (10 ms when snap is off) and `rows` rows.
func nudge_selected(steps: float, rows: int) -> void:
	if selection.is_empty():
		return
	var step := snap_sec if snap_sec > 0.0 else 0.01
	var dt := steps * step
	var min_start := INF
	var min_row := 1 << 30
	for c in selection:
		min_start = minf(min_start, c.start_sec)
		min_row = mini(min_row, c.row)
	dt = maxf(dt, -min_start)
	rows = maxi(rows, -min_row)
	if is_zero_approx(dt) and rows == 0:
		return
	_begin("Nudge Clips")
	for c in selection:
		var old := {"start_sec": c.start_sec, "row": c.row}
		_add_do(_apply_props.bind(c, {"start_sec": c.start_sec + dt, "row": c.row + rows}))
		_add_undo(_apply_props.bind(c, old))
	_commit()


## Trims the start ("start") or end ("end") of the selected clips under the playhead to it. One undo step.
func trim_selected_to_playhead(side: String) -> void:
	var targets := selection.filter(func(c: AWClip) -> bool:
		return playhead_sec > c.start_sec + 1e-6 and playhead_sec < c.end_sec() - 1e-6)
	if targets.is_empty():
		message.emit("Put the playhead inside a selected clip to trim it there.")
		return
	_begin("Trim Start to Playhead" if side == "start" else "Trim End to Playhead")
	for c: AWClip in targets:
		var local := c.project_to_local(playhead_sec)
		var before := {"start_sec": c.start_sec, "length_sec": c.length_sec, "source_offset_sec": c.source_offset_sec,
			"fade_in_sec": c.fade_in_sec, "fade_out_sec": c.fade_out_sec}
		var keys_before := clip_curve_keys(c)
		var after := before.duplicate()
		var keys_after := keys_before
		if side == "start":
			after.merge(left_trim_props(c, local), true)
			after["start_sec"] = playhead_sec
			after["fade_in_sec"] = minf(c.fade_in_sec, c.length_sec - local)
			keys_after = []
			for item: Array in keys_before:
				keys_after.append([item[0], _shifted(item[1], -local), (item[2] - Vector2(local, local)) if item[2] is Vector2 else null])
		else:
			after.merge(right_trim_props(c, local), true)
			after["fade_out_sec"] = minf(c.fade_out_sec, local)
		_add_do(_apply_clip_state.bind(c, after, keys_after))
		_add_undo(_apply_clip_state.bind(c, before, keys_before))
	_commit()


## Props for removing `cut` seconds of audio from a clip's start (negative reveals). A reversed clip
## plays its source backwards, so its start is the source's end.
func left_trim_props(c: AWClip, cut: float) -> Dictionary:
	if c.reversed:
		return {"length_sec": c.length_sec - cut}
	return {"length_sec": c.length_sec - cut, "source_offset_sec": c.source_offset_sec + cut}


## Props for a new clip length set at its end.
func right_trim_props(c: AWClip, new_len: float) -> Dictionary:
	if c.reversed:
		return {"length_sec": new_len, "source_offset_sec": c.source_offset_sec + (c.length_sec - new_len)}
	return {"length_sec": new_len}


## Reverses (or un-reverses) the selection, or `clip` if it isn't selected. The clip keeps its place
## and length and plays the same part of the file backwards. One undo step.
func toggle_reverse_clips(clip: AWClip) -> void:
	var targets: Array[AWClip] = selection if selection.has(clip) else ([clip] as Array[AWClip])
	var to := not clip.reversed
	_begin("Reverse Clips" if to else "Unreverse Clips")
	for c in targets:
		_add_do(_apply_props.bind(c, {"reversed": to}))
		_add_undo(_apply_props.bind(c, {"reversed": c.reversed}))
	_commit()


## Sets the fade-in ("in") or fade-out ("out") shape of the selection, or `clip`. One undo step.
func set_fade_shape(clip: AWClip, side: String, shape: AWClip.FadeShape) -> void:
	var targets: Array[AWClip] = selection if selection.has(clip) else ([clip] as Array[AWClip])
	var prop := "fade_in_shape" if side == "in" else "fade_out_shape"
	_begin("Fade Shape")
	for c in targets:
		_add_do(_apply_props.bind(c, {prop: shape}))
		_add_undo(_apply_props.bind(c, {prop: c.get(prop)}))
	_commit()


## Crossfades overlapping selected clips: sorted by start, each overlapping pair gets an
## equal-power fade-out / fade-in across the overlap (any rows). One undo step. Returns pairs done.
func crossfade_selected() -> int:
	var clips := selection.duplicate()
	clips.sort_custom(func(a: AWClip, b: AWClip) -> bool: return a.start_sec < b.start_sec)
	var pairs := []
	for i in clips.size():
		for j in range(i + 1, clips.size()):
			var a: AWClip = clips[i]
			var b: AWClip = clips[j]
			if b.start_sec < a.end_sec() - 1e-4 and b.end_sec() > a.end_sec() and b.start_sec > a.start_sec:
				pairs.append([a, b])
	if pairs.is_empty():
		message.emit("Select clips that overlap in time to crossfade them.")
		return 0
	_begin("Crossfade")
	for pr: Array in pairs:
		var a: AWClip = pr[0]
		var b: AWClip = pr[1]
		var a_fade := a.length_sec - a.project_to_local(b.start_sec)
		var b_fade := b.project_to_local(a.end_sec())
		_add_do(_apply_props.bind(a, {"fade_out_sec": clampf(a_fade, 0.0, a.length_sec - a.fade_in_sec), "fade_out_shape": AWClip.FadeShape.EQUAL_POWER}))
		_add_undo(_apply_props.bind(a, {"fade_out_sec": a.fade_out_sec, "fade_out_shape": a.fade_out_shape}))
		_add_do(_apply_props.bind(b, {"fade_in_sec": clampf(b_fade, 0.0, b.length_sec - b.fade_out_sec), "fade_in_shape": AWClip.FadeShape.EQUAL_POWER}))
		_add_undo(_apply_props.bind(b, {"fade_in_sec": b.fade_in_sec, "fade_in_shape": b.fade_in_shape}))
	_commit()
	message.emit("Crossfaded %d pair%s." % [pairs.size(), "" if pairs.size() == 1 else "s"])
	return pairs.size()


# --- Rows (layers) ----------------------------------------------------------------------

## Sets a row setting ("name", "muted", "solo", "locked", "color") as one undo step.
func set_row_prop(i: int, prop: String, value: Variant) -> void:
	if i < 0:
		return
	var r := _ensure_row(i)
	if r.get(prop) == value:
		return
	set_props(r, {prop: value}, {"name": "Rename Row", "muted": "Mute Row", "solo": "Solo Row", "locked": "Lock Row", "color": "Row Colour"}.get(prop, "Edit Row"))
	if prop == "locked" and value:
		var keep: Array[AWClip] = []
		for c in selection:
			if c.row != i:
				keep.append(c)
		if keep.size() != selection.size():
			set_selection(keep)


## Solo only this row (Ctrl+click on S): one undo step.
func solo_only_row(i: int) -> void:
	_ensure_row(i)
	_begin("Solo Row Only")
	for k in project.rows.size():
		var r := project.rows[k]
		if r == null:
			continue
		var want := k == i
		if r.solo != want:
			_add_do(_apply_props.bind(r, {"solo": want}))
			_add_undo(_apply_props.bind(r, {"solo": r.solo}))
	_commit()


func _ensure_row(i: int) -> AWRow:
	while project.rows.size() <= i:
		project.rows.append(AWRow.new())
	if project.rows[i] == null:
		project.rows[i] = AWRow.new()
	return project.rows[i]


func rename_clip(c: AWClip, new_name: String) -> void:
	new_name = new_name.strip_edges()
	if c != null and new_name != "" and new_name != c.name:
		set_props(c, {"name": new_name}, "Rename Clip")


## Colours the selection (or `clip` if it isn't selected). One undo step.
func set_clip_color(clip: AWClip, col: Color) -> void:
	var targets: Array[AWClip] = selection if selection.has(clip) else ([clip] as Array[AWClip])
	_begin("Clip Colour")
	for c in targets:
		_add_do(_apply_props.bind(c, {"color": col}))
		_add_undo(_apply_props.bind(c, {"color": c.color}))
	_commit()


# Curves follow the audio: when a clip's left edge moves by dt, its keys move by -dt so every
# key stays on the same moment of the sound. Keys that fall outside the clip are kept (hidden),
# so trimming back out brings them back.

## [[curve, keys], ...] for every curve on a clip. Used as the "before" state of a trim.
## Each item: [curve, keys, LFO span as Vector2(start, end) or null].
func clip_curve_keys(clip: AWClip) -> Array:
	var out := []
	for c in clip.chain.curves:
		out.append([c, clip.chain.get_keys(c), Vector2(c.lfo.start_sec, c.lfo.end_sec) if c.lfo else null])
	return out


## Live preview of a left trim: keys (and LFO spans) = originals shifted by -dt.
func preview_shift_curves(clip: AWClip, original: Array, dt: float) -> void:
	for item: Array in original:
		clip.chain.set_keys(item[0], _shifted(item[1], -dt))
		_set_lfo_span(item[0], item[2], -dt)


## Finishes a left trim (clip props + curve shifts) as one undo step.
func commit_clip_trim(clip: AWClip, orig_props: Dictionary, orig_keys: Array, action_name: String) -> void:
	var now_props := {}
	var changed := false
	for key: String in orig_props:
		now_props[key] = clip.get(key)
		changed = changed or now_props[key] != orig_props[key]
	if not changed:
		return
	var now_keys := clip_curve_keys(clip)
	_apply_clip_state(clip, orig_props, orig_keys)
	_do_undo(action_name, _apply_clip_state.bind(clip, now_props, now_keys), _apply_clip_state.bind(clip, orig_props, orig_keys))


func _apply_clip_state(clip: AWClip, props: Dictionary, key_sets: Array) -> void:
	for key: String in props:
		clip.set(key, props[key])
	for item: Array in key_sets:
		clip.chain.set_keys(item[0], item[1])
		_set_lfo_span(item[0], item[2] if item.size() > 2 else null, 0.0)
	project_changed.emit(false)


static func _set_lfo_span(c: AWCurve, span: Variant, dt: float) -> void:
	if c.lfo and span is Vector2:
		c.lfo.start_sec = (span as Vector2).x + dt
		c.lfo.end_sec = (span as Vector2).y + dt


static func _shifted(keys: Array, dt: float) -> Array:
	var out := keys.duplicate(true)
	for k: Dictionary in out:
		k["t"] = k.t + dt
	return out


func _apply_insert_clip(clip: AWClip, index: int) -> void:
	project.clips.insert(clampi(index, 0, project.clips.size()), clip)
	project_changed.emit(true)


func _apply_remove_clip(clip: AWClip) -> void:
	project.clips.erase(clip)
	if selection.has(clip):
		selection.erase(clip)
		selection_changed.emit()
	if focus_clip == clip:
		focus_clip = null
		_reset_curve_focus()
		chain_target_changed.emit()
	project_changed.emit(true)


# --- Effect edits -------------------------------------------------------------

func add_effect(chain: AWChain, type: String, index := -1) -> AWEffect:
	var e := AWEffect.create(type, chain.new_effect_id())
	var idx := chain.effects.size() if index < 0 else clampi(index, chain.first_movable(), chain.effects.size())
	_do_undo("Add Effect", _apply_insert_effect.bind(chain, e, idx, []), _apply_remove_effect.bind(chain, e))
	return e


func remove_effect(chain: AWChain, e: AWEffect) -> void:
	if e.is_fixed():
		return
	var saved := []
	for c in chain.curves_of(e.id):
		saved.append([c, chain.get_keys(c), chain.curves.find(c)])
	_do_undo("Remove Effect",
		_apply_remove_effect.bind(chain, e),
		_apply_insert_effect.bind(chain, e, chain.effects.find(e), saved))


func move_effect(chain: AWChain, e: AWEffect, new_index: int) -> void:
	if e.is_fixed():
		return
	var old := chain.effects.find(e)
	var target := clampi(new_index, chain.first_movable(), chain.effects.size() - 1)
	if old == target:
		return
	_do_undo("Reorder Effect", _apply_move_effect.bind(chain, e, target), _apply_move_effect.bind(chain, e, old))


var detail_chain: AWChain
var detail_effect: AWEffect


## Shows an effect's custom panel in the Audio Effect dock (null closes it).
func open_detail(chain: AWChain, e: AWEffect) -> void:
	if detail_effect == e and detail_chain == chain:
		return
	detail_chain = chain
	detail_effect = e
	detail_changed.emit()


func reset_effect(chain: AWChain, e: AWEffect) -> void:
	set_props(e, {"params": AWEffectLibrary.default_params(e.effect_type)}, "Reset Effect")


## Static parameter value (used when the parameter has no curve).
## `spread`: with several clips selected, a Clip-card change reaches them all (relatively). The Clips
## card's rows edit one clip each and pass false.
func set_param(e: AWEffect, key: String, value: float, spread := true) -> void:
	var others := _relative_targets(e, key) if spread else ([] as Array[AWEffect])
	var p := e.params.duplicate()
	p[key] = value
	if others.is_empty():
		set_props(e, {"params": p}, "Edit " + AWEffectLibrary.param_label(e.effect_type, key))
		return
	# Several clips selected: the same change (not the same value) reaches every one of them.
	var delta := value - float(e.get_param(key))
	_begin("Edit %s (%d clips)" % [AWEffectLibrary.param_label(e.effect_type, key), others.size() + 1])
	_add_do(_apply_props.bind(e, {"params": p}))
	_add_undo(_apply_props.bind(e, {"params": e.params.duplicate()}))
	for o in others:
		_add_do(_apply_props.bind(o, {"params": _shifted_params(o, key, delta)}))
		_add_undo(_apply_props.bind(o, {"params": o.params.duplicate()}))
	_commit()


func preview_param(e: AWEffect, key: String, value: float, spread := true) -> void:
	var delta := value - float(e.get_param(key))
	var p := e.params.duplicate()
	p[key] = value
	preview_set(e, {"params": p})
	for o in (_relative_targets(e, key) if spread else ([] as Array[AWEffect])):
		preview_set(o, {"params": _shifted_params(o, key, delta)})


## Clip-card values that change relatively on every selected clip when one is edited.
const RELATIVE_KEYS := ["gain_db", "pitch_semitones", "pan"]


## The other selected clips' Clip cards, when `e` is the focused clip's Clip card and several
## clips are selected.
func _relative_targets(e: AWEffect, key: String) -> Array[AWEffect]:
	var out: Array[AWEffect] = []
	if key not in RELATIVE_KEYS or focus_clip == null or selection.size() < 2 or not selection.has(focus_clip):
		return out
	if focus_clip.chain == null or focus_clip.chain.effects.is_empty() or focus_clip.chain.effects[0] != e:
		return out
	for c in selection:
		if c != focus_clip and c.chain and not c.chain.effects.is_empty():
			out.append(c.chain.effects[0])
	return out


static func _shifted_params(o: AWEffect, key: String, delta: float) -> Dictionary:
	var spec := AWEffectLibrary.param_spec(o.effect_type, key)
	var p := o.params.duplicate()
	p[key] = clampf(float(o.get_param(key)) + delta, spec[0], spec[1])
	return p


func _apply_insert_effect(chain: AWChain, e: AWEffect, index: int, saved_curves: Array) -> void:
	chain.effects.insert(clampi(index, 0, chain.effects.size()), e)
	for item: Array in saved_curves:
		_insert_curve_raw(chain, item[0], item[1], item[2])
	project_changed.emit(true)


func _apply_remove_effect(chain: AWChain, e: AWEffect) -> void:
	for c in chain.curves_of(e.id):
		_remove_curve_raw(chain, c)
	chain.effects.erase(e)
	project_changed.emit(true)


func _apply_move_effect(chain: AWChain, e: AWEffect, index: int) -> void:
	chain.effects.erase(e)
	chain.effects.insert(clampi(index, 0, chain.effects.size()), e)
	project_changed.emit(true)


# --- Curve edits --------------------------------------------------------------

## Right-click > Make Curve: starts a flat curve at the current value across the owner.
func make_curve(chain: AWChain, e: AWEffect, param: String) -> AWCurve:
	if chain.get_curve(e.id, param):
		return chain.get_curve(e.id, param)
	if chain_tab == ChainTab.CHAIN and chain != tab_chain:
		# A clip's Gain / Pitch / Pan on a chain tab: show that clip's curves.
		for clip in chain_clips(tab_chain):
			if clip.chain == chain:
				focus_clip = clip
				curve_on_clip = true
				chain_target_changed.emit()
	var c := AWCurve.new()
	c.effect_id = e.id
	c.param = param
	c.color = chain.next_curve_color()
	c.scale = AWEffectLibrary.default_scale(e.effect_type, param) as AWCurve.Scale
	var r := Vector2(AWEffectLibrary.param_spec(e.effect_type, param)[0], AWEffectLibrary.param_spec(e.effect_type, param)[1])
	var v := AWCurveMath.to_norm(c.scale, e.get_param(param), r.x, r.y)
	var end := curve_owner_len()
	var h := Vector2(end / 3.0, 0.0)
	var keys := [
		{"t": 0.0, "v": v, "in": -h, "out": h, "mode": AWCurve.HandleMode.BALANCED},
		{"t": end, "v": v, "in": -h, "out": h, "mode": AWCurve.HandleMode.BALANCED},
	]
	_do_undo("Make Curve", _apply_add_curve.bind(chain, c, keys, chain.curves.size()), _apply_remove_curve.bind(chain, c))
	solo_curve = null
	set_active_curve(c)
	return c


func remove_curve(chain: AWChain, c: AWCurve) -> void:
	_do_undo("Remove Curve",
		_apply_remove_curve.bind(chain, c),
		_apply_add_curve.bind(chain, c, chain.get_keys(c), chain.curves.find(c)))


func set_curve_keys(chain: AWChain, c: AWCurve, keys: Array, action_name: String) -> void:
	_do_undo(action_name, _apply_keys.bind(chain, c, keys), _apply_keys.bind(chain, c, chain.get_keys(c)))


func preview_curve_keys(chain: AWChain, c: AWCurve, keys: Array) -> void:
	_apply_keys(chain, c, keys)


## Finishes a key/handle drag. `original` = keys from before the drag started.
func commit_curve_drag(chain: AWChain, c: AWCurve, original: Array, action_name: String) -> void:
	var now := chain.get_keys(c)
	if now == original:
		return
	chain.set_keys(c, original)
	set_curve_keys(chain, c, now, action_name)


func _apply_keys(chain: AWChain, c: AWCurve, keys: Array) -> void:
	chain.set_keys(c, keys)
	project_changed.emit(false)


func _apply_add_curve(chain: AWChain, c: AWCurve, keys: Array, index: int) -> void:
	_insert_curve_raw(chain, c, keys, index)
	project_changed.emit(true)


func _apply_remove_curve(chain: AWChain, c: AWCurve) -> void:
	_remove_curve_raw(chain, c)
	project_changed.emit(true)


func _insert_curve_raw(chain: AWChain, c: AWCurve, keys: Array, index: int) -> void:
	chain.curves.insert(clampi(index, 0, chain.curves.size()), c)
	chain.set_keys(c, keys)


func _remove_curve_raw(chain: AWChain, c: AWCurve) -> void:
	chain.remove_track(c)
	chain.curves.erase(c)
	if lfo_curve == c:
		close_lfo()
	if active_curve == c:
		active_curve = null
	if solo_curve == c:
		solo_curve = null
	curve_view_changed.emit()


# --- LFO ----------------------------------------------------------------------

## Width of the step a baked jump takes (seconds).
const BAKE_EDGE := 0.0005

## Opens the LFO panel for a curve, adding a default LFO first if it has none.
func open_lfo(chain: AWChain, c: AWCurve) -> void:
	_show_curve_owner(c)
	if c.lfo == null:
		add_lfo(chain, c)
	if c.display != AWCurve.Display.ON:
		set_curve_display(c, AWCurve.Display.ON)
	set_active_curve(c)
	lfo_curve = c
	lfo_panel_changed.emit()
	curve_view_changed.emit()


## Brings up the Audio LFO dock (the plugin shows it on lfo_panel_changed while lfo_list_open).
func show_lfo_list() -> void:
	lfo_list_open = true
	lfo_panel_changed.emit()
	lfo_list_open = false


## Every LFO in the project, Master first then clips in timeline order:
## [{chain, curve, clip (null for Master), label "Clip 2\\Low Pass\\Cutoff"}].
func all_lfos() -> Array:
	var out := []
	_collect_lfos(out, project.master_chain, null, "Master")
	for ch in project.chains:
		var users := chain_clips(ch)
		_collect_lfos(out, ch, users[0] if not users.is_empty() else null, ch.name)
	for clip in project.clips:
		_collect_lfos(out, clip.chain, clip, clip.name)
	return out


func _collect_lfos(out: Array, ch: AWChain, clip: AWClip, owner_name: String) -> void:
	for c in ch.curves:
		if c.lfo == null:
			continue
		var e := ch.effect_of(c)
		if e == null:
			continue
		var same := 0
		var nth := 0
		for o in ch.effects:
			if o.effect_type == e.effect_type:
				same += 1
				if o == e:
					nth = same
		var ename := e.effect_type + (" #%d" % nth if same > 1 else "")
		out.append({"chain": ch, "curve": c, "clip": clip,
			"label": "%s\\%s\\%s" % [owner_name, ename, AWEffectLibrary.param_label(e.effect_type, c.param)]})


## Jumps to an LFO from all_lfos(): selects its clip (or the Master tab) and opens it.
func goto_lfo(entry: Dictionary) -> void:
	var clip: AWClip = entry["clip"]
	var ch: AWChain = entry["chain"]
	if project.chains.has(ch):
		if clip and focus_clip != clip:
			select_clip(clip)
		curve_on_clip = false
		open_chain_tab(ch)
		chain_target_changed.emit()
	elif clip != null:
		if focus_clip != clip:
			select_clip(clip)
		_focus(clip)
		if chain_tab == ChainTab.CHAIN:
			set_curve_on_clip(true)
	else:
		set_chain_tab(ChainTab.MASTER)
	open_lfo(entry["chain"], entry["curve"])


func close_lfo() -> void:
	if lfo_curve == null:
		return
	lfo_curve = null
	lfo_panel_changed.emit()
	curve_view_changed.emit()


## Default LFO: across the whole owner, swinging a quarter of the range either side of
## the curve's value at the start, 4 Hz, short fades.
func add_lfo(chain: AWChain, c: AWCurve) -> AWLfo:
	var l := AWLfo.new()
	var n := chain.base_norm(c, 0.0)
	l.min_value = chain.from_norm(c, clampf(n - 0.25, 0.0, 1.0))
	l.max_value = chain.from_norm(c, clampf(n + 0.25, 0.0, 1.0))
	if is_equal_approx(l.min_value, l.max_value):
		l.min_value = chain.from_norm(c, 0.25)
		l.max_value = chain.from_norm(c, 0.75)
	l.start_sec = 0.0
	l.end_sec = curve_owner_len()
	l.fade_in_sec = minf(0.25, l.span() * 0.25)
	l.fade_out_sec = minf(0.25, l.span() * 0.25)
	l.random_seed = randi() % 10000
	set_props(c, {"lfo": l}, "Add LFO")
	return l


func remove_lfo(c: AWCurve) -> void:
	if lfo_curve == c:
		close_lfo()
	set_props(c, {"lfo": null}, "Remove LFO")


## Replaces the LFO with ordinary keys that reproduce it (linear keys, 16 per cycle, plus
## a key pair at every jump of Square / Saw / Random so edges stay sharp), keeping the drawn
## keys outside the LFO's span. One undo step.
func bake_lfo(chain: AWChain, c: AWCurve) -> void:
	var l := c.lfo
	if l == null:
		return
	var old_keys := chain.get_keys(c)
	var fmax := maxf(l.freq_hz, maxf(l.freq_hz + l.freq_accel * l.span(), 0.05)) * (1.0 + 0.75 * l.jitter_rate)
	var step := clampf(1.0 / (fmax * 16.0), 0.002, 0.05)
	if l.span() / step > 4000.0:
		step = l.span() / 4000.0
	var keys := []
	for k: Dictionary in old_keys:
		if k.t < l.start_sec - 1e-6 or k.t > l.end_sec + 1e-6:
			keys.append(k)
	var times := PackedFloat64Array()
	var t := l.start_sec
	while t < l.end_sec:
		times.append(t)
		t += step
	times.append(l.end_sec)
	# Jumps: Square every half cycle, Saw and Random every cycle (found through the phase, so a
	# drifting frequency keeps sharp edges too).
	var jump := 0.0
	match l.shape:
		AWLfo.Shape.SQUARE: jump = 0.5
		AWLfo.Shape.SAW, AWLfo.Shape.RANDOM: jump = 1.0
	if jump > 0.0 and l.glide <= 0.0: # Glide has no hard edges
		var cycles := ceilf((l.warped_phase(l.start_sec) + 1e-9) / jump) * jump
		while true:
			var edge := l.time_of_warped_phase(cycles)
			if edge >= l.end_sec:
				break
			times.append(edge - BAKE_EDGE)
			times.append(edge)
			cycles += jump
	times.sort()
	var last := -INF
	for tt in times:
		if tt - last < BAKE_EDGE * 0.5:
			continue
		last = tt
		# Just before an edge, sample a hair earlier so the key holds the pre-jump value.
		keys.append({"t": tt, "v": chain.sample_norm(c, tt), "in": Vector2.ZERO, "out": Vector2.ZERO,
			"mode": AWCurve.HandleMode.LINEAR})
	if lfo_curve == c:
		close_lfo()
	_do_undo("Bake LFO to Keys", _apply_bake.bind(chain, c, keys, null), _apply_bake.bind(chain, c, old_keys, l))


func _apply_bake(chain: AWChain, c: AWCurve, keys: Array, lfo: AWLfo) -> void:
	c.lfo = lfo
	chain.set_keys(c, keys)
	project_changed.emit(false)
