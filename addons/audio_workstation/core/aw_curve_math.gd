@tool
class_name AWCurveMath
extends RefCounted
## Handle helpers for Bezier keys ({t, v, in, out, mode} dictionaries, sorted by t).


const FADER_EXP := 0.25


## Parameter value -> 0..1 on the curve's scale.
static func to_norm(scale: int, v: float, lo: float, hi: float) -> float:
	match scale:
		AWCurve.Scale.LOG:
			if lo > 0.0 and hi > lo:
				return clampf(log(maxf(v, lo) / lo) / log(hi / lo), 0.0, 1.0)
		AWCurve.Scale.FADER:
			var f0 := pow(db_to_linear(lo), FADER_EXP)
			var f1 := pow(db_to_linear(hi), FADER_EXP)
			return clampf((pow(db_to_linear(v), FADER_EXP) - f0) / (f1 - f0), 0.0, 1.0)
	return clampf((v - lo) / (hi - lo), 0.0, 1.0) if hi > lo else 0.0


## 0..1 on the curve's scale -> parameter value.
static func from_norm(scale: int, n: float, lo: float, hi: float) -> float:
	n = clampf(n, 0.0, 1.0)
	match scale:
		AWCurve.Scale.LOG:
			if lo > 0.0 and hi > lo:
				return lo * pow(hi / lo, n)
		AWCurve.Scale.FADER:
			var f0 := pow(db_to_linear(lo), FADER_EXP)
			var f1 := pow(db_to_linear(hi), FADER_EXP)
			return clampf(linear_to_db(pow(f0 + n * (f1 - f0), 1.0 / FADER_EXP)), lo, hi)
	return lo + n * (hi - lo)


## LINEAR keys point their handles a third of the way to their neighbours.
static func update_linear_handles(keys: Array) -> void:
	for i in keys.size():
		if keys[i].get("mode", 0) == AWCurve.HandleMode.LINEAR:
			_set_linear(keys, i)


static func _set_linear(keys: Array, i: int) -> void:
	var k: Dictionary = keys[i]
	k["in"] = Vector2.ZERO
	k["out"] = Vector2.ZERO
	if i > 0:
		k["in"] = Vector2(keys[i - 1].t - k.t, keys[i - 1].v - k.v) / 3.0
	if i < keys.size() - 1:
		k["out"] = Vector2(keys[i + 1].t - k.t, keys[i + 1].v - k.v) / 3.0


## Auto-smooth: tangent follows the line between the neighbours (Catmull-Rom style).
static func smooth(keys: Array, i: int) -> void:
	var k: Dictionary = keys[i]
	var prev: Dictionary = keys[i - 1] if i > 0 else k
	var next: Dictionary = keys[i + 1] if i < keys.size() - 1 else k
	var dt: float = next.t - prev.t
	var slope: float = (next.v - prev.v) / dt if dt > 0.0 else 0.0
	var in_len: float = (k.t - prev.t) / 3.0
	var out_len: float = (next.t - k.t) / 3.0
	k["in"] = Vector2(-in_len, -slope * in_len)
	k["out"] = Vector2(out_len, slope * out_len)
	k["mode"] = AWCurve.HandleMode.BALANCED


## Horizontal handles: ease in and out of this key (an S-curve between two flat keys).
static func flatten(keys: Array, i: int) -> void:
	var k: Dictionary = keys[i]
	var in_len: float = (k.t - keys[i - 1].t) / 3.0 if i > 0 else 0.1
	var out_len: float = (keys[i + 1].t - k.t) / 3.0 if i < keys.size() - 1 else 0.1
	k["in"] = Vector2(-in_len, 0.0)
	k["out"] = Vector2(out_len, 0.0)
	k["mode"] = AWCurve.HandleMode.MIRRORED if is_equal_approx(in_len, out_len) else AWCurve.HandleMode.BALANCED


## Applies a handle drag, keeping the opposite handle consistent with the key's mode.
## `px_per_unit` converts (seconds, value) to pixels so "balanced" keeps the opposite
## handle's on-screen length, like Godot's Bezier editor.
static func drag_handle(k: Dictionary, which: String, new_handle: Vector2, px_per_unit := Vector2.ONE) -> void:
	var mode: int = k.get("mode", AWCurve.HandleMode.BALANCED)
	if mode == AWCurve.HandleMode.LINEAR:
		return
	if which == "in":
		new_handle.x = minf(new_handle.x, 0.0)
	else:
		new_handle.x = maxf(new_handle.x, 0.0)
	k[which] = new_handle
	var other := "out" if which == "in" else "in"
	match mode:
		AWCurve.HandleMode.MIRRORED:
			k[other] = -new_handle
		AWCurve.HandleMode.BALANCED:
			var other_px: Vector2 = (k[other] as Vector2) * px_per_unit
			var new_px := new_handle * px_per_unit
			if new_px.length() > 0.0 and px_per_unit.x != 0.0 and px_per_unit.y != 0.0:
				k[other] = (-new_px.normalized() * other_px.length()) / px_per_unit
