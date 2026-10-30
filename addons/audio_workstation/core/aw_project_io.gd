@tool
class_name AWProjectIO
extends RefCounted
## Saving and opening sound files (.tres / .res), and making what was opened safe to use.
##
## open() never throws: it returns {ok, project, error, repairs}. A file that can't be used at all
## (not found, not ours, made by a newer version) gives ok = false and a message; a file that is
## merely damaged is repaired as far as possible and every repair is listed in `repairs`.

## version -> Callable(project) that brings a project of that version up by one. Empty until the
## format changes; the tests add one to prove the mechanism.
static var migrations := {}


## Writes the project. The file is written beside the target and moved into place, so a failed
## save never damages an existing file.
static func save(project: AWProject, path: String) -> Error:
	if path == "":
		return ERR_FILE_BAD_PATH
	project.format_version = AWProject.FORMAT_VERSION
	var tmp := path.get_basename() + ".aw_saving." + path.get_extension()
	var err := ResourceSaver.save(project, tmp)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return err
	if FileAccess.file_exists(path):
		var rm := DirAccess.remove_absolute(path)
		if rm != OK:
			DirAccess.remove_absolute(tmp)
			return rm
	var mv := DirAccess.rename_absolute(tmp, path)
	if mv != OK:
		DirAccess.remove_absolute(tmp)
	return mv


static func open(path: String) -> Dictionary:
	var res := {"ok": false, "project": null, "error": "", "repairs": []}
	if not FileAccess.file_exists(path):
		res.error = "The file doesn't exist: %s" % path
		return res
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded == null:
		res.error = "Couldn't read %s. It may be damaged or not a sound file." % path.get_file()
		return res
	var project := loaded as AWProject
	if project == null:
		res.error = "%s isn't an Audio Workstation sound (it is a %s)." % [path.get_file(), loaded.get_class()]
		return res
	if project.format_version > AWProject.FORMAT_VERSION:
		res.error = "%s was made by a newer version of Audio Workstation (format %d, this one reads up to %d)." % [path.get_file(), project.format_version, AWProject.FORMAT_VERSION]
		return res
	var repairs: Array = res.repairs
	while project.format_version < AWProject.FORMAT_VERSION:
		var step: Callable = migrations.get(project.format_version, Callable())
		if step.is_valid():
			step.call(project)
		repairs.append("Updated from format %d." % project.format_version)
		project.format_version += 1
	repairs.append_array(sanitize(project))
	res.project = project
	res.ok = true
	return res


# --- Repair --------------------------------------------------------------------

## Fixes what would crash or confuse the editor or the engine. Returns what it changed.
static func sanitize(p: AWProject) -> Array:
	var rep: Array = []
	if not _fin(p.length_sec) or p.length_sec <= 0.0:
		p.length_sec = 4.0
		rep.append("Project length was invalid; set to 4 s.")
	if not _fin(p.loop_start_sec) or not _fin(p.loop_end_sec) or p.loop_end_sec < p.loop_start_sec:
		p.loop_start_sec = 0.0
		p.loop_end_sec = maxf(p.length_sec * 0.5, 0.1)
		rep.append("Loop range was invalid; reset.")
	if p.export_bit_depth != 16 and p.export_bit_depth != 32:
		p.export_bit_depth = 16
		rep.append("Export bit depth was invalid; set to 16-bit.")
	if not AWProject.FORMATS.has(p.export_format):
		p.export_format = "wav"
		rep.append("Export format was unknown; set to WAV.")
	if not _fin(p.export_ogg_quality):
		p.export_ogg_quality = 5.0
	p.export_ogg_quality = clampf(p.export_ogg_quality, 0.0, 10.0)
	if not _fin(p.export_end_sec):
		p.export_end_sec = -1.0
		rep.append("Export end was invalid; set to automatic.")
	elif p.export_end_sec > AWProject.MAX_END_SEC:
		p.export_end_sec = AWProject.MAX_END_SEC
	if p.master_chain == null:
		p.master_chain = AWChain.create(AWEffectLibrary.MASTER_OUTPUT)
		rep.append("The master chain was missing; made a new one.")
	_sanitize_chain(p.master_chain, AWEffectLibrary.MASTER_OUTPUT, "Master", rep)
	var kept: Array[AWClip] = []
	for i in p.clips.size():
		var c := p.clips[i]
		if c == null:
			rep.append("Removed an empty clip entry.")
			continue
		var label := c.name if c.name != "" else "Clip %d" % (i + 1)
		_sanitize_clip(c, label, rep)
		kept.append(c)
	if kept.size() != p.clips.size():
		p.clips.assign(kept)
	return rep


static func _sanitize_clip(c: AWClip, label: String, rep: Array) -> void:
	if not _fin(c.start_sec) or c.start_sec < 0.0:
		c.start_sec = 0.0 if not _fin(c.start_sec) else maxf(c.start_sec, 0.0)
		rep.append("%s: start time was invalid." % label)
	if not _fin(c.length_sec) or c.length_sec < 0.001:
		c.length_sec = 1.0 if not _fin(c.length_sec) else 0.001
		rep.append("%s: length was invalid." % label)
	if not _fin(c.source_offset_sec) or c.source_offset_sec < 0.0:
		c.source_offset_sec = 0.0
	if not _fin(c.fade_in_sec) or c.fade_in_sec < 0.0:
		c.fade_in_sec = 0.0
	if not _fin(c.fade_out_sec) or c.fade_out_sec < 0.0:
		c.fade_out_sec = 0.0
	if c.row < 0:
		c.row = 0
	if c.chain == null:
		c.chain = AWChain.create(AWEffectLibrary.CLIP_SOURCE)
		rep.append("%s: its effect chain was missing; made a new one." % label)
	_sanitize_chain(c.chain, AWEffectLibrary.CLIP_SOURCE, label, rep)
	c.invalidate_warp()


static func _sanitize_chain(ch: AWChain, fixed_type: String, label: String, rep: Array) -> void:
	if ch.automation == null:
		ch.automation = Animation.new()
		ch.automation.length = AWChain.MAX_TIME
	var effects: Array[AWEffect] = []
	var seen_ids := {}
	for e in ch.effects:
		if e == null:
			rep.append("%s: removed an empty effect entry." % label)
			continue
		if not AWEffectLibrary.EFFECTS.has(e.effect_type):
			rep.append("%s: removed the unknown effect \"%s\"." % [label, e.effect_type])
			continue
		if AWEffectLibrary.is_fixed(e.effect_type) and (not effects.is_empty() or e.effect_type != fixed_type):
			rep.append("%s: removed a misplaced %s card." % [label, e.effect_type])
			continue
		if seen_ids.has(e.id):
			var old := e.id
			e.id = ch.new_effect_id()
			while seen_ids.has(e.id):
				e.id = ch.new_effect_id()
			rep.append("%s: %s shared an id with another effect (%d); renumbered." % [label, e.effect_type, old])
		seen_ids[e.id] = true
		_sanitize_params(e, label, rep)
		effects.append(e)
	if effects.is_empty() or effects[0].effect_type != fixed_type:
		var src := AWEffect.create(fixed_type, 0)
		while seen_ids.has(src.id):
			src.id = ch.new_effect_id()
		seen_ids[src.id] = true
		effects.push_front(src)
		rep.append("%s: its %s card was missing; added." % [label, fixed_type])
	ch.effects.assign(effects)
	var top := 0
	for e in ch.effects:
		top = maxi(top, e.id)
	if ch.next_effect_id <= top:
		ch.next_effect_id = top + 1
	# Curves: each needs an effect and a parameter that exist, once.
	var curves: Array[AWCurve] = []
	var pairs := {}
	for c in ch.curves:
		if c == null:
			rep.append("%s: removed an empty curve entry." % label)
			continue
		var e := ch.find_effect(c.effect_id)
		var key := "%d:%s" % [c.effect_id, c.param]
		if e == null or not AWEffectLibrary.param_schema(e.effect_type).has(c.param):
			rep.append("%s: removed a curve for %s, which no longer exists." % [label, c.param])
			ch.remove_track(c)
			continue
		if pairs.has(key):
			rep.append("%s: removed a duplicate curve for %s." % [label, c.param])
			continue
		pairs[key] = true
		if _sanitize_curve(ch, c, label, rep):
			curves.append(c)
	ch.curves.assign(curves)
	ch.revision += 1


static func _sanitize_params(e: AWEffect, label: String, rep: Array) -> void:
	var schema := AWEffectLibrary.param_schema(e.effect_type)
	for key in e.params.keys():
		if not schema.has(key):
			e.params.erase(key)
			rep.append("%s: dropped the unknown setting %s.%s." % [label, e.effect_type, key])
			continue
		var v: Variant = e.params[key]
		var spec: Array = schema[key]
		if (typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT) or not _fin(float(v)):
			e.params[key] = spec[2]
			rep.append("%s: %s %s was not a number; reset." % [label, e.effect_type, spec[5]])
		else:
			e.params[key] = clampf(float(v), float(spec[0]), float(spec[1]))


## Returns false when the curve had to be removed.
static func _sanitize_curve(ch: AWChain, c: AWCurve, label: String, rep: Array) -> bool:
	var keys := ch.get_keys(c)
	var track_keys := 0
	var t := ch.automation.find_track(c.track_path(), Animation.TYPE_BEZIER)
	if t >= 0:
		track_keys = ch.automation.track_get_key_count(t)
	if c.key_modes.size() != track_keys:
		var modes := PackedInt32Array()
		for i in track_keys:
			modes.append(c.key_modes[i] if i < c.key_modes.size() else AWCurve.HandleMode.BALANCED)
		c.key_modes = modes
		rep.append("%s: curve %s had mismatched key data; fixed." % [label, c.param])
	if c.lfo != null:
		var l := c.lfo
		l.freq_hz = clampf(l.freq_hz if _fin(l.freq_hz) else 4.0, 0.05, 20.0)
		l.freq_accel = clampf(l.freq_accel if _fin(l.freq_accel) else 0.0, -5.0, 5.0)
		l.fade_smoothing = clampf(l.fade_smoothing if _fin(l.fade_smoothing) else 0.0, 0.0, 1.0)
		l.fade_in_sec = maxf(l.fade_in_sec if _fin(l.fade_in_sec) else 0.0, 0.0)
		l.fade_out_sec = maxf(l.fade_out_sec if _fin(l.fade_out_sec) else 0.0, 0.0)
		if not _fin(l.max_value):
			l.max_value = 1.0
		if not _fin(l.min_value):
			l.min_value = 0.0
		if not _fin(l.start_sec) or l.start_sec < 0.0:
			l.start_sec = 0.0
		if not _fin(l.end_sec) or l.end_sec < l.start_sec:
			l.end_sec = l.start_sec + 1.0
			rep.append("%s: the LFO on %s had an invalid range; reset." % [label, c.param])
	if keys.size() > 0:
		var bad := false
		for k: Dictionary in keys:
			if not _fin(float(k.t)) or not _fin(float(k.v)):
				bad = true
		if bad:
			rep.append("%s: curve %s had invalid keys; removed the curve." % [label, c.param])
			ch.remove_track(c)
			return false
	return true


static func _fin(x: float) -> bool:
	return not is_nan(x) and not is_inf(x)
