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
signal playhead_changed
signal transport_changed
signal message(text: String)
## The LFO panel opened, closed, or switched curve.
signal lfo_panel_changed
## Export bit depth, tail or file name changed (not a sound edit, so no plan rebuild).
signal export_settings_changed

enum ChainTab { MASTER, CLIP }
enum CurveTime { CLIP, PROJECT }

const AUDIO_EXTENSIONS := ["wav", "ogg", "mp3"]
const MIN_LEN := 0.01
## [label, seconds]; 0 = off.
const SNAP_OPTIONS := [
	["Off", 0.0], ["1 ms", 0.001], ["10 ms", 0.01], ["50 ms", 0.05],
	["100 ms", 0.1], ["250 ms", 0.25], ["500 ms", 0.5], ["1 s", 1.0],
]

var project: AWProject
var engine: AWEngine
var undo_redo: EditorUndoRedoManager
var project_path := ""

# Transport
var playing := false
var playhead_sec := 0.0

# Selection
var selection: Array[AWClip] = []
## The clip whose chain the Clip tab shows. Stays set when the grid selection is cleared.
var focus_clip: AWClip = null
var chain_tab := ChainTab.CLIP

# Curves (view state)
var curve_time := CurveTime.CLIP
var active_curve: AWCurve = null
var solo_curve: AWCurve = null
## Curve whose LFO panel is open (null = closed).
var lfo_curve: AWCurve = null

# Views
var timeline_view := AWTimeView.new()
var curve_view := AWTimeView.new()
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
	curve_view.content_end = func() -> float: return curve_domain_end_view() + 0.5
	project_changed.connect(func(structural: bool) -> void:
		for c in project.clips:
			c.invalidate_warp() # a static Pitch change alters timing too
		engine.project_edited(structural))


# --- Project / file stubs -----------------------------------------------------

func set_project(p: AWProject) -> void:
	project = p
	selection.clear()
	focus_clip = p.clips[p.clips.size() - 1] if not p.clips.is_empty() else null
	active_curve = null
	solo_curve = null
	playhead_sec = 0.0
	engine.set_project(p)
	project_changed.emit(true)
	selection_changed.emit()
	chain_target_changed.emit()
	curve_view_changed.emit()
	playhead_changed.emit()
	transport_changed.emit()


func new_project() -> void:
	project_path = ""
	set_project(AWProject.create_default())


func save_project(path: String) -> void:
	message.emit("Save isn't implemented yet (interface phase): %s" % path) # TODO(logic): ResourceSaver


func load_project(path: String) -> void:
	message.emit("Open isn't implemented yet (interface phase): %s" % path) # TODO(logic): ResourceLoader


func set_export_bit_depth(bits: int) -> void:
	project.export_bit_depth = bits
	export_settings_changed.emit()


## Places the export end marker (undoable). Negative = back to automatic.
func set_export_end(sec: float) -> void:
	var v := -1.0 if sec < 0.0 else clampf(sec, 0.0, AWProject.MAX_END_SEC)
	set_props(project, {"export_end_sec": v}, "Set Export End")


func set_export_path(path: String) -> void:
	project.export_path = path.strip_edges()
	export_settings_changed.emit()


## The export file as a loadable path: relative names live under res://.
func export_target() -> String:
	var p := project.export_path.strip_edges().replace("\\", "/")
	if p == "" or p.begins_with("res://") or p.begins_with("user://") or p.is_absolute_path():
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
	var bytes_per_sample := project.export_bit_depth / 8
	return int(ceil(export_length_sec() * AudioServer.get_mix_rate())) * 2 * bytes_per_sample + 44


func export_now() -> void:
	var t := export_target()
	if t == "":
		message.emit("Enter a file name to export to.")
		return
	export_wav(t)


func export_wav(path: String) -> void:
	message.emit("WAV export isn't implemented yet (interface phase): %s" % path) # TODO(logic): engine.render_wav


func export_audio_stream(path: String) -> void:
	message.emit("AudioStream export isn't implemented yet (interface phase): %s" % path) # TODO(logic)


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


func is_audio_file(path: String) -> bool:
	return path.get_extension().to_lower() in AUDIO_EXTENSIONS


# --- Clip selection -----------------------------------------------------------

func select_clip(clip: AWClip, mode := "replace") -> void:
	match mode:
		"replace":
			if selection.size() == 1 and selection[0] == clip:
				_focus(clip)
				return
			selection = [clip]
		"add":
			if not selection.has(clip):
				selection.append(clip)
		"toggle":
			if selection.has(clip):
				selection.erase(clip)
			else:
				selection.append(clip)
	selection_changed.emit()
	if selection.has(clip):
		_focus(clip)


func set_selection(clips: Array[AWClip]) -> void:
	selection = clips.duplicate()
	selection_changed.emit()
	if not selection.is_empty():
		_focus(selection.back())


func clear_selection() -> void:
	if selection.is_empty():
		return
	selection.clear()
	selection_changed.emit()


func select_all_clips() -> void:
	set_selection(project.clips)


func is_selected(clip: AWClip) -> bool:
	return selection.has(clip)


func _focus(clip: AWClip) -> void:
	var tab_changed := chain_tab != ChainTab.CLIP
	if focus_clip == clip and not tab_changed:
		return
	focus_clip = clip
	chain_tab = ChainTab.CLIP
	_reset_curve_focus()
	chain_target_changed.emit()


# --- Which chain is shown -----------------------------------------------------

func set_chain_tab(tab: ChainTab) -> void:
	if chain_tab == tab:
		return
	chain_tab = tab
	_reset_curve_focus()
	chain_target_changed.emit()


func active_chain() -> AWChain:
	if chain_tab == ChainTab.MASTER:
		return project.master_chain
	return focus_clip.chain if focus_clip else null


func active_chain_name() -> String:
	if chain_tab == ChainTab.MASTER:
		return "Master"
	return focus_clip.name if focus_clip else ""


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
	return chain_tab == ChainTab.CLIP and focus_clip != null


func is_clip_local_view() -> bool:
	return _clip_view() and curve_time == CurveTime.CLIP


## Project time -> the time a chain's curves are evaluated at.
func chain_local_time(chain: AWChain, project_t: float) -> float:
	for c in project.clips:
		if c.chain == chain:
			return c.project_to_local(project_t)
	return project_t


func set_curve_time(mode: CurveTime) -> void:
	if curve_time == mode:
		return
	curve_time = mode
	frame_curves()
	curve_view_changed.emit()


## View time -> curve-local time.
func view_to_local(v: float) -> float:
	if _clip_view() and curve_time == CurveTime.PROJECT:
		return focus_clip.project_to_local(v)
	return v


func local_to_view(t: float) -> float:
	if _clip_view() and curve_time == CurveTime.PROJECT:
		return focus_clip.local_to_project(t)
	return t


## View time -> project time (for the playhead and seeking).
func view_to_project(v: float) -> float:
	return focus_clip.local_to_project(v) if is_clip_local_view() else v


func project_to_view(p: float) -> float:
	return focus_clip.project_to_local(p) if is_clip_local_view() else p


## Length of the chain's owner in its local time.
func curve_domain_len() -> float:
	if chain_tab == ChainTab.CLIP:
		return focus_clip.length_sec if focus_clip else project.length_sec
	return project.content_end_sec()


func curve_domain_end_view() -> float:
	if project == null:
		return 10.0
	return local_to_view(curve_domain_len())


func frame_curves() -> void:
	curve_view.min_time = 0.0
	curve_view.frame(local_to_view(0.0), curve_domain_end_view())


# --- Curve display (view state, not undoable) ---------------------------------

func set_active_curve(c: AWCurve) -> void:
	if active_curve == c:
		return
	active_curve = c
	curve_view_changed.emit()


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
	right.source_offset_sec = clip.source_offset_sec + local
	right.fade_in_sec = 0.0
	# Right half's curves shift so they keep playing the same values at the same moment.
	for c in right.chain.curves:
		right.chain.set_keys(c, _shifted(right.chain.get_keys(c), -local))
		if c.lfo: # keep the oscillation's phase and fades on the same moments
			c.lfo.start_sec -= local
			c.lfo.end_sec -= local
	var old := {"length_sec": clip.length_sec, "fade_out_sec": clip.fade_out_sec}
	var now := {"length_sec": local, "fade_out_sec": 0.0}
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
	_begin("Duplicate Clips")
	for c in selection:
		var copy := c.duplicate_clip()
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
	var idx := chain.effects.size() if index < 0 else clampi(index, 1, chain.effects.size())
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
	var target := clampi(new_index, 1, chain.effects.size() - 1)
	if old == target:
		return
	_do_undo("Reorder Effect", _apply_move_effect.bind(chain, e, target), _apply_move_effect.bind(chain, e, old))


func reset_effect(chain: AWChain, e: AWEffect) -> void:
	set_props(e, {"params": AWEffectLibrary.default_params(e.effect_type)}, "Reset Effect")


## Static parameter value (used when the parameter has no curve).
func set_param(e: AWEffect, key: String, value: float) -> void:
	var p := e.params.duplicate()
	p[key] = value
	set_props(e, {"params": p}, "Edit " + AWEffectLibrary.param_label(e.effect_type, key))


func preview_param(e: AWEffect, key: String, value: float) -> void:
	var p := e.params.duplicate()
	p[key] = value
	preview_set(e, {"params": p})


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
	var c := AWCurve.new()
	c.effect_id = e.id
	c.param = param
	c.color = chain.next_curve_color()
	c.scale = AWEffectLibrary.default_scale(e.effect_type, param) as AWCurve.Scale
	var r := Vector2(AWEffectLibrary.param_spec(e.effect_type, param)[0], AWEffectLibrary.param_spec(e.effect_type, param)[1])
	var v := AWCurveMath.to_norm(c.scale, e.get_param(param), r.x, r.y)
	var end := curve_domain_len()
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
	if c.lfo == null:
		add_lfo(chain, c)
	if c.display != AWCurve.Display.ON:
		set_curve_display(c, AWCurve.Display.ON)
	set_active_curve(c)
	lfo_curve = c
	lfo_panel_changed.emit()
	curve_view_changed.emit()


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
	l.end_sec = curve_domain_len()
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
	var step := clampf(1.0 / (maxf(l.freq_hz, 0.05) * 16.0), 0.002, 0.05)
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
	# Jumps: Square every half cycle, Saw and Random every cycle.
	var jump := 0.0
	match l.shape:
		AWLfo.Shape.SQUARE: jump = 0.5 / maxf(l.freq_hz, 0.05)
		AWLfo.Shape.SAW, AWLfo.Shape.RANDOM: jump = 1.0 / maxf(l.freq_hz, 0.05)
	if jump > 0.0:
		var edge := l.start_sec + jump
		while edge < l.end_sec:
			times.append(edge - BAKE_EDGE)
			times.append(edge)
			edge += jump
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
