@tool
class_name AWChain
extends Resource
## An effect chain (one per clip, one for the master) plus its automation.
## Processing order = order of `effects`. effects[0] is always the fixed source card.
##
## Automation keys are stored as Bezier tracks in `automation`:
##   time  = seconds from the owner's start (clip start for clips, project start for master)
##   value = 0..1 on the curve's scale (AWCurve.Scale), not the raw parameter value.
## Use sample() for the real parameter value. Keys are exchanged with the UI as
## Dictionaries: {t, v (0..1), in: Vector2, out: Vector2, mode}.

@export var effects: Array[AWEffect] = []
@export var curves: Array[AWCurve] = []
@export var automation: Animation
@export var next_effect_id: int = 1

## Latest time (local seconds) a key can sit at: the length of the automation track.
const MAX_TIME := 3600.0

## Bumped whenever keys change, so cached data (e.g. a clip's time warp) knows to rebuild.
var revision := 0


func _init() -> void:
	if automation == null:
		automation = Animation.new()
		automation.length = MAX_TIME


static func create(fixed_type: String) -> AWChain:
	var c := AWChain.new()
	c.effects.append(AWEffect.create(fixed_type, 0))
	return c


func new_effect_id() -> int:
	next_effect_id += 1
	return next_effect_id - 1


func find_effect(id: int) -> AWEffect:
	for e in effects:
		if e.id == id:
			return e
	return null


func get_curve(effect_id: int, param: String) -> AWCurve:
	for c in curves:
		if c.effect_id == effect_id and c.param == param:
			return c
	return null


func curves_of(effect_id: int) -> Array[AWCurve]:
	var out: Array[AWCurve] = []
	for c in curves:
		if c.effect_id == effect_id:
			out.append(c)
	return out


func effect_of(curve: AWCurve) -> AWEffect:
	return find_effect(curve.effect_id)


## [min, max] of the parameter a curve drives.
func curve_range(curve: AWCurve) -> Vector2:
	var e := effect_of(curve)
	var spec := AWEffectLibrary.param_spec(e.effect_type if e else "", curve.param)
	return Vector2(spec[0], spec[1])


func curve_label(curve: AWCurve) -> String:
	var e := effect_of(curve)
	if e == null:
		return curve.param
	return "%s · %s" % [e.effect_type, AWEffectLibrary.param_label(e.effect_type, curve.param)]


func next_curve_color() -> Color:
	var used := []
	for c in curves:
		used.append(c.color)
	for col: Color in AWEffectLibrary.CURVE_COLORS:
		if not used.has(col):
			return col
	return AWEffectLibrary.CURVE_COLORS[curves.size() % AWEffectLibrary.CURVE_COLORS.size()]


# --- Keys ---------------------------------------------------------------------

func _track(curve: AWCurve, create_if_missing := false) -> int:
	var idx := automation.find_track(curve.track_path(), Animation.TYPE_BEZIER)
	if idx < 0 and create_if_missing:
		idx = automation.add_track(Animation.TYPE_BEZIER)
		automation.track_set_path(idx, curve.track_path())
	return idx


func get_keys(curve: AWCurve) -> Array:
	var out := []
	var t := _track(curve)
	if t < 0:
		return out
	for i in automation.track_get_key_count(t):
		out.append({
			"t": automation.track_get_key_time(t, i),
			"v": automation.bezier_track_get_key_value(t, i),
			"in": automation.bezier_track_get_key_in_handle(t, i),
			"out": automation.bezier_track_get_key_out_handle(t, i),
			"mode": curve.key_modes[i] if i < curve.key_modes.size() else AWCurve.HandleMode.BALANCED,
		})
	return out


## Replaces all keys of a curve. Keys are sorted by time; LINEAR keys get their handles recomputed.
func set_keys(curve: AWCurve, keys: Array) -> void:
	var sorted := keys.duplicate(true)
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.t < b.t)
	AWCurveMath.update_linear_handles(sorted)
	var t := _track(curve, true)
	for i in range(automation.track_get_key_count(t) - 1, -1, -1):
		automation.track_remove_key(t, i)
	var modes := PackedInt32Array()
	for k: Dictionary in sorted:
		automation.bezier_track_insert_key(t, k.t, k.v, k["in"], k.out)
		modes.append(k.get("mode", AWCurve.HandleMode.BALANCED))
	curve.key_modes = modes
	revision += 1


func remove_track(curve: AWCurve) -> void:
	var t := _track(curve)
	if t >= 0:
		automation.remove_track(t)
	revision += 1


func to_norm(curve: AWCurve, value: float) -> float:
	var r := curve_range(curve)
	return AWCurveMath.to_norm(curve.scale, value, r.x, r.y)


func from_norm(curve: AWCurve, n: float) -> float:
	var r := curve_range(curve)
	return AWCurveMath.from_norm(curve.scale, n, r.x, r.y)


## Real parameter value of a curve at a time.
func sample(curve: AWCurve, local_time: float) -> float:
	var t := _track(curve)
	if t < 0 or automation.track_get_key_count(t) == 0:
		var e := effect_of(curve)
		return e.get_param(curve.param) if e else 0.0
	return from_norm(curve, sample_norm(curve, local_time))


## Curve height (0..1 on its scale) at a time, including its LFO; what you hear and what
## the graph draws as the solid line.
func sample_norm(curve: AWCurve, local_time: float) -> float:
	var b := base_norm(curve, local_time)
	var l := curve.lfo
	if l == null or not l.enabled:
		return b
	var e := l.envelope(local_time)
	if e <= 0.0:
		return b
	var sw := l.swing(local_time)
	if l.mode == AWLfo.Mode.RELATIVE:
		return clampf(b + l.depth * sw * e, 0.0, 1.0)
	var lo := to_norm(curve, minf(l.min_value, l.max_value))
	var hi := to_norm(curve, maxf(l.min_value, l.max_value))
	var w := lo + (hi - lo) * (0.5 + 0.5 * sw)
	return clampf(b + (w - b) * e, 0.0, 1.0)


func has_active_lfo(curve: AWCurve) -> bool:
	return curve.lfo != null and curve.lfo.enabled


## The drawn curve alone (its keys), without the LFO.
func base_norm(curve: AWCurve, local_time: float) -> float:
	var t := _track(curve)
	if t < 0 or automation.track_get_key_count(t) == 0:
		var e := effect_of(curve)
		return to_norm(curve, e.get_param(curve.param)) if e else 0.0
	var first := automation.track_get_key_time(t, 0)
	var last := automation.track_get_key_time(t, automation.track_get_key_count(t) - 1)
	if local_time <= first:
		return automation.bezier_track_get_key_value(t, 0)
	if local_time >= last:
		return automation.bezier_track_get_key_value(t, automation.track_get_key_count(t) - 1)
	return clampf(automation.bezier_track_interpolate(t, local_time), 0.0, 1.0)


## Everything the native sampler (AWCore.sample_curve) needs to evaluate a curve exactly like
## sample() / sample_norm() do.
func native_spec(curve: AWCurve) -> Dictionary:
	var r := curve_range(curve)
	var e := effect_of(curve)
	var spec := {
		"track": _track(curve),
		"scale": curve.scale,
		"lo": r.x,
		"hi": r.y,
		"static_norm": to_norm(curve, e.get_param(curve.param)) if e else 0.0,
	}
	var l := curve.lfo
	if l != null and l.enabled:
		spec["lfo"] = {
			"shape": l.shape, "min": l.min_value, "max": l.max_value, "freq": l.freq_hz,
			"fade_in": l.fade_in_sec, "fade_out": l.fade_out_sec,
			"start": l.start_sec, "end": l.end_sec, "seed": l.random_seed,
			"accel": l.freq_accel, "smooth": l.fade_smoothing,
			"mode": l.mode, "depth": l.depth, "phase": l.phase_deg / 360.0, "jit_rate": l.jitter_rate,
			"jit_depth": l.jitter_depth, "glide": l.glide, "decay": l.decay_sec,
		}
	return spec


## Changes how a curve is scaled while keeping every key at the same parameter value.
## Handles are re-derived (smoothed) because their shape doesn't carry across scales.
## (For the future per-curve scale toggle.)
func set_curve_scale(curve: AWCurve, new_scale: AWCurve.Scale) -> void:
	if curve.scale == new_scale:
		return
	var keys := get_keys(curve)
	for k: Dictionary in keys:
		k["v"] = from_norm(curve, k.v)
	curve.scale = new_scale
	for k: Dictionary in keys:
		k["v"] = to_norm(curve, k.v)
	for i in keys.size():
		if keys[i].mode != AWCurve.HandleMode.LINEAR:
			AWCurveMath.smooth(keys, i)
	set_keys(curve, keys)


## Effective value of a parameter at a time: the curve if one exists, else the static value.
func value_at(effect: AWEffect, param: String, local_time: float) -> float:
	var c := get_curve(effect.id, param)
	return sample(c, local_time) if c else effect.get_param(param)
