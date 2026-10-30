@tool
class_name AWClipWarp
extends RefCounted
## Maps a clip's audio time ("clip time", where its curves live) to elapsed project time.
##
## Pitch is applied as playback rate: rate(s) = 2^(pitch(s) / 12), with pitch read from the
## clip's own Pitch curve (or static value) at audio time s. Lower pitch plays slower, so the
## clip lasts longer and its curves' playhead advances more slowly:
##     project_elapsed(s) = integral from 0 to s of 1 / rate(u) du
## Outside the curve's keys the rate is constant, so the mapping extends exactly in both
## directions (needed for trimming back into hidden audio).

const STEP := 0.002

var _const_rate := 1.0
var _s_min := 0.0
var _s_max := 0.0
var _rate_lo := 1.0
var _rate_hi := 1.0
var _cum := PackedFloat64Array() # project elapsed at _s_min + i * STEP, relative to s = 0


static func build(clip: AWClip) -> AWClipWarp:
	var w := AWClipWarp.new()
	var ch := clip.chain
	var src: AWEffect = ch.effects[0] if (ch and not ch.effects.is_empty()) else null
	if src == null:
		return w
	var curve := ch.get_curve(src.id, "pitch_semitones")
	if curve == null or ch.get_keys(curve).size() < 2:
		w._const_rate = rate_for(ch.value_at(src, "pitch_semitones", 0.0))
		return w
	var keys := ch.get_keys(curve)
	w._s_min = minf(0.0, keys.front().t)
	w._s_max = maxf(keys.back().t, w._s_min + STEP)
	var n := int(ceilf((w._s_max - w._s_min) / STEP)) + 1
	w._cum.resize(n)
	var rates := AWSampler.values(ch, curve, w._s_min, STEP, n, AWSampler.RATE)
	var prev_inv := 1.0 / rates[0]
	w._rate_lo = 1.0 / prev_inv
	w._cum[0] = 0.0
	for i in range(1, n):
		var inv := 1.0 / rates[i]
		w._cum[i] = w._cum[i - 1] + (prev_inv + inv) * 0.5 * STEP
		prev_inv = inv
	w._rate_hi = 1.0 / prev_inv
	w._s_max = w._s_min + (n - 1) * STEP
	# Re-base so that audio time 0 maps to project elapsed 0.
	var zero := w._table_warp(0.0)
	for i in n:
		w._cum[i] -= zero
	return w


## Playback rate over the clip's audio time, for the native core. Entry i is the rate at
## audio time i * step_sec. A single entry means a constant rate. The table covers 0..length_sec
## (plus one entry), matching what build() integrates, so both give the same timing.
static func rate_table(clip: AWClip, length_sec: float, step_sec: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var ch := clip.chain
	var src: AWEffect = ch.effects[0] if (ch and not ch.effects.is_empty()) else null
	if src == null:
		out.append(1.0)
		return out
	var curve := ch.get_curve(src.id, "pitch_semitones")
	if curve == null or ch.get_keys(curve).size() < 2:
		out.append(rate_for(ch.value_at(src, "pitch_semitones", 0.0)))
		return out
	return AWSampler.values(ch, curve, 0.0, step_sec, int(ceilf(length_sec / step_sec)) + 2, AWSampler.RATE)


## What the warp depends on besides the clip's length: the Pitch curve's keys, scale and LFO,
## and the static Pitch value. Used to skip rebuilding an unchanged warp.
static func signature(clip: AWClip) -> Array:
	var ch := clip.chain
	var src: AWEffect = ch.effects[0] if (ch and not ch.effects.is_empty()) else null
	if src == null:
		return []
	var curve := ch.get_curve(src.id, "pitch_semitones")
	if curve == null:
		return [src.get_param("pitch_semitones")]
	var l := curve.lfo
	var lfo: Array = []
	if l != null and l.enabled:
		lfo = [l.shape, l.max_value, l.min_value, l.freq_hz, l.fade_in_sec, l.fade_out_sec, l.start_sec, l.end_sec, l.random_seed, l.freq_accel, l.fade_smoothing]
	return [hash(ch.get_keys(curve)), curve.scale, src.get_param("pitch_semitones"), lfo]


static func rate_for(semitones: float) -> float:
	return pow(2.0, semitones / 12.0)


func is_constant() -> bool:
	return _cum.is_empty()


## Audio time -> project time elapsed since the clip's start.
func warp(s: float) -> float:
	if is_constant():
		return s / _const_rate
	return _table_warp(s)


## Project time elapsed since the clip's start -> audio time.
func unwarp(p: float) -> float:
	if is_constant():
		return p * _const_rate
	var last := _cum.size() - 1
	if p <= _cum[0]:
		return _s_min - (_cum[0] - p) * _rate_lo
	if p >= _cum[last]:
		return _s_max + (p - _cum[last]) * _rate_hi
	var i := _cum.bsearch(p) - 1
	i = clampi(i, 0, last - 1)
	var span := _cum[i + 1] - _cum[i]
	var f := (p - _cum[i]) / span if span > 0.0 else 0.0
	return _s_min + (i + f) * STEP


func _table_warp(s: float) -> float:
	var last := _cum.size() - 1
	if s <= _s_min:
		return _cum[0] - (_s_min - s) / _rate_lo
	if s >= _s_max:
		return _cum[last] + (s - _s_max) / _rate_hi
	var x := (s - _s_min) / STEP
	var i := mini(int(x), last - 1)
	return lerpf(_cum[i], _cum[i + 1], x - i)
