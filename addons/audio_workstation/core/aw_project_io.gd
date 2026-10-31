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
static var migrations := {5: _split_clip_chains, 6: _lfo_adsr, 7: _group_frames, 8: _filter_cards}


## Format 8 -> 9: Low Pass / High Pass / Band Pass cards become Filter cards of that type at
## 12 dB/oct (the same sound). Their curves stay (same ids and parameter names).
static func _filter_cards(p: AWProject) -> void:
	var chains: Array[AWChain] = [p.master_chain]
	chains.append_array(p.chains)
	for c in p.clips:
		if c and c.chain:
			chains.append(c.chain)
	for g in p.groups:
		if g and g.chain:
			chains.append(g.chain)
	for ch in chains:
		if ch == null:
			continue
		for e in ch.effects:
			if e and AWEffectLibrary.LEGACY_FILTERS.has(e.effect_type):
				convert_to_filter_card(e)


## Turns a legacy Low / High / Band Pass card into a Filter card in place.
static func convert_to_filter_card(e: AWEffect) -> void:
	var m: int = AWEffectLibrary.LEGACY_FILTERS[e.effect_type]
	var p := e.params.duplicate()
	e.effect_type = "Filter"
	p["mode"] = float(m)
	p["gain_db"] = 0.0
	p["slope_db"] = 12.0
	e.params = p


## Format 7 -> 8: clips that shared a group id become a group frame around them (from the first
## start to the last end, over their rows). A frame that would overlap an earlier one is dropped
## (its clips are left ungrouped).
static func _group_frames(p: AWProject) -> void:
	var by_id := {}
	for c in p.clips:
		if c and c.group_id != 0:
			if not by_id.has(c.group_id):
				by_id[c.group_id] = []
			by_id[c.group_id].append(c)
	var ids := by_id.keys()
	ids.sort()
	var n := 0
	for id: int in ids:
		var members: Array = by_id[id]
		var s := INF
		var e := -INF
		var r0 := 1 << 30
		var r1 := -1
		for c: AWClip in members:
			s = minf(s, c.start_sec)
			e = maxf(e, c.end_sec())
			r0 = mini(r0, c.row)
			r1 = maxi(r1, c.row)
		if p.group_overlaps(s, e, r0, r1):
			continue
		n += 1
		var g := AWGroup.new()
		g.name = "Group %d" % n
		g.start_sec = s
		g.end_sec = maxf(e, s + 0.01)
		g.row = r0
		g.row_count = r1 - r0 + 1
		g.color = (members[0] as AWClip).color
		p.groups.append(g)
	for c in p.clips:
		if c:
			c.group_id = 0


## Format 6 -> 7: an LFO's half-life Decay becomes an ADSR Decay down to Sustain 0 over about four
## half-lives (close, not identical); without one, Sustain stays at full.
static func _lfo_adsr(p: AWProject) -> void:
	var chains: Array[AWChain] = [p.master_chain]
	chains.append_array(p.chains)
	for c in p.clips:
		if c and c.chain:
			chains.append(c.chain)
	for ch in chains:
		if ch == null:
			continue
		for cv in ch.curves:
			var l := cv.lfo if cv else null
			if l == null:
				continue
			if l.decay_sec > 0.0:
				l.decay_sec = l.decay_sec * 4.0
				l.sustain = 0.0
			else:
				l.sustain = 1.0


## Format 5 -> 6: effects a clip owned (after its Clip card) move, with their curves, into a shared
## chain named "<clip> FX" that the clip uses.
static func _split_clip_chains(p: AWProject) -> void:
	for c in p.clips:
		if c == null or c.chain == null or c.fx_chain != null:
			continue
		var moved := split_clip_chain(c)
		if moved:
			p.chains.append(moved)


## Moves a clip's own effects (after the Clip card) and their curves into a new shared chain that
## the clip then uses. Returns the new chain, or null if there was nothing to move.
static func split_clip_chain(c: AWClip) -> AWChain:
	var own := c.chain
	var start := own.first_movable()
	if own.effects.size() <= start:
		return null
	var ch := AWChain.new()
	ch.name = (c.name if c.name != "" else "Clip") + " FX"
	ch.next_effect_id = own.next_effect_id
	for i in range(start, own.effects.size()):
		ch.effects.append(own.effects[i])
	for e in ch.effects:
		for cv in own.curves_of(e.id):
			var keys := own.get_keys(cv)
			own.remove_track(cv)
			own.curves.erase(cv)
			ch.curves.append(cv)
			ch.set_keys(cv, keys)
	own.effects.resize(start)
	c.fx_chain = ch
	return ch


## Writes the project. The file is written beside the target and moved into place, so a failed
## save never damages an existing file.
## `adopt`: make `project` the cached resource for `path` (not for the recovery copy).
static func save(project: AWProject, path: String, adopt := true) -> Error:
	if path == "":
		return ERR_FILE_BAD_PATH
	project.format_version = AWProject.FORMAT_VERSION
	stamp_uids(project)
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
	# The sound being edited becomes THE resource for this path. Otherwise the editor keeps an older
	# cached copy (in the Inspector, or from a double-click) that a later editor save would write back
	# over this one, and loading the path would return the stale copy.
	if adopt and project.resource_path != path:
		project.take_over_path(path)
	return OK


static func open(path: String) -> Dictionary:
	var res := {"ok": false, "project": null, "error": "", "repairs": []}
	if not FileAccess.file_exists(path):
		res.error = "The file doesn't exist: %s" % path
		return res
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
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
	repairs.append_array(refresh_sources(project))
	res.project = project
	res.ok = true
	return res


# --- Repair --------------------------------------------------------------------

## Fixes what would crash or confuse the editor or the engine. Returns what it changed.
static func sanitize(p: AWProject) -> Array:
	var rep: Array = []
	# Shared chains: each one named, unique, without a fixed card.
	_project_chains = p.chains
	for i in range(p.chains.size() - 1, -1, -1):
		if p.chains[i] == null:
			p.chains.remove_at(i)
			rep.append("Removed an empty chain entry.")
	var names := {}
	for ch in p.chains:
		if ch.name.strip_edges() == "" or names.has(ch.name):
			ch.name = "Chain %d" % (names.size() + 1)
		names[ch.name] = true
		_sanitize_chain(ch, "", "Chain \"%s\"" % ch.name, rep)
	for i in range(p.groups.size() - 1, -1, -1):
		var g := p.groups[i]
		if g == null or not _fin(g.start_sec) or not _fin(g.end_sec):
			p.groups.remove_at(i)
			rep.append("Removed an invalid group.")
			continue
		g.start_sec = maxf(g.start_sec, 0.0)
		g.end_sec = maxf(g.end_sec, g.start_sec + 0.01)
		g.row = maxi(g.row, 0)
		g.row_count = maxi(g.row_count, 1)
		if g.chain:
			_sanitize_chain(g.chain, "", "Group \"%s\"" % g.name, rep)
	for i in range(p.groups.size() - 1, -1, -1):
		var g := p.groups[i]
		for j in i:
			if p.groups[j].overlaps(g.start_sec, g.end_sec, g.row, g.last_row()):
				p.groups.remove_at(i)
				rep.append("Removed group \"%s\": it overlapped another group." % g.name)
				break
	for i in p.rows.size():
		if p.rows[i] == null:
			p.rows[i] = AWRow.new()
	for i in range(p.markers.size() - 1, -1, -1):
		var m := p.markers[i]
		if m == null or not _fin(m.time_sec) or m.time_sec < 0.0:
			p.markers.remove_at(i)
			rep.append("Removed an invalid marker.")
	p.markers.sort_custom(func(a: AWMarker, b: AWMarker) -> bool: return a.time_sec < b.time_sec)
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
	if c.fx_chain != null and not _project_chains.has(c.fx_chain):
		# A chain the project doesn't list (e.g. pasted from elsewhere): list it.
		_project_chains.append(c.fx_chain)
		rep.append("%s: its effect chain wasn't listed; added it." % label)
	c.invalidate_warp()


static var _project_chains: Array[AWChain] = []


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
		if AWEffectLibrary.is_fixed(e.effect_type) and (fixed_type == "" or not effects.is_empty() or e.effect_type != fixed_type):
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
	if fixed_type != "" and (effects.is_empty() or effects[0].effect_type != fixed_type):
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
		l.freq_hz = clampf(l.freq_hz if _fin(l.freq_hz) else 4.0, 0.05, 100.0)
		l.freq_accel = clampf(l.freq_accel if _fin(l.freq_accel) else 0.0, -100.0, 100.0)
		l.fade_smoothing = clampf(l.fade_smoothing if _fin(l.fade_smoothing) else 0.0, 0.0, 1.0)
		for prop: Array in [["depth", 0.1, 0.0, 1.0], ["phase_deg", 0.0, 0.0, 360.0], ["jitter_rate", 0.0, 0.0, 1.0],
				["jitter_depth", 0.0, 0.0, 1.0], ["glide", 0.0, 0.0, 1.0], ["decay_sec", 0.0, 0.0, 240.0], ["sustain", 1.0, 0.0, 1.0]]:
			var v: float = l.get(prop[0])
			var fixed := clampf(v if _fin(v) else float(prop[1]), float(prop[2]), float(prop[3]))
			if fixed != v:
				l.set(prop[0], fixed)
				rep.append("An LFO's %s was out of range; fixed." % prop[0])
		if l.mode != AWLfo.Mode.ABSOLUTE and l.mode != AWLfo.Mode.RELATIVE:
			l.mode = AWLfo.Mode.ABSOLUTE
			rep.append("An LFO had an unknown mode; set to Absolute.")
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


# --- Source files --------------------------------------------------------------

## "uid://..." for a file Godot knows, or "".
static func uid_for_path(path: String) -> String:
	if path == "":
		return ""
	var id := ResourceLoader.get_resource_uid(path)
	return ResourceUID.id_to_text(id) if id != ResourceUID.INVALID_ID else ""


## Where Godot currently keeps the file with this UID, or "".
static func path_for_uid(uid: String) -> String:
	if uid == "":
		return ""
	var id := ResourceUID.text_to_id(uid)
	if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
		return ""
	return ResourceUID.get_id_path(id)


static func source_exists(path: String) -> bool:
	return path != "" and FileAccess.file_exists(path)


## Records each clip's file UID (done on save).
static func stamp_uids(p: AWProject) -> void:
	for c in p.clips:
		if c != null and c.source_path != "":
			var u := uid_for_path(c.source_path)
			if u != "":
				c.source_uid = u


## Points clips at their files' current paths (a file moved or renamed in the editor keeps its
## UID). Returns what changed.
static func refresh_sources(p: AWProject) -> Array:
	var rep: Array = []
	for c in p.clips:
		if c == null:
			continue
		if c.source_uid != "":
			var now := path_for_uid(c.source_uid)
			if now != "" and now != c.source_path and source_exists(now):
				rep.append("%s: its sound moved to %s." % [c.name, now])
				c.name = follow_name(c.name, c.source_path, now)
				c.source_path = now
		elif c.source_path != "":
			c.source_uid = uid_for_path(c.source_path)
	return rep


## A clip named after its file ("boom", or "boom 2" after a duplicate) takes the new file's name.
## Names the user typed are kept.
static func follow_name(name: String, old_path: String, new_path: String) -> String:
	var old_base := old_path.get_file().get_basename()
	var new_base := new_path.get_file().get_basename()
	if old_base == "" or old_base == new_base or not name.begins_with(old_base):
		return name
	var rest := name.substr(old_base.length())
	if rest != "" and not rest.begins_with(" ") and not rest.begins_with("(") and not rest.begins_with("_") and not rest.begins_with("-"):
		return name # "boomerang" isn't named after "boom"
	return new_base + rest


## File name -> full path for every audio file under `dir` (first found wins). Used to relink.
static func index_audio_files(dir: String, limit := 20000) -> Dictionary:
	var out := {}
	var stack: Array[String] = [dir]
	var seen := 0
	while not stack.is_empty() and seen < limit:
		var d: String = stack.pop_back()
		for f in DirAccess.get_files_at(d):
			seen += 1
			var ext := f.get_extension().to_lower()
			if (ext == "wav" or ext == "ogg" or ext == "mp3") and not out.has(f):
				out[f] = d.path_join(f)
		for sub in DirAccess.get_directories_at(d):
			if not sub.begins_with("."):
				stack.append(d.path_join(sub))
	return out
