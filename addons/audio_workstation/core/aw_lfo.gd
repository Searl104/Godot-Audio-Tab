@tool
class_name AWLfo
extends Resource
## A low-frequency oscillator riding on one automation curve (right-click a curve > LFO).
##
## Between start_sec and end_sec (curve time, so it runs on the clip's clock and slows when
## Pitch drops) the parameter swings between min_value and max_value. Fade In / Fade Out
## cross-fade from the drawn curve into the oscillation and back out. The swing happens on
## the curve's scale, so a cutoff LFO swings evenly in octaves.

enum Shape { SINE, TRIANGLE, SQUARE, SAW, RANDOM }
const SHAPE_NAMES := ["Sine", "Triangle", "Square", "Saw", "Random"]
## Absolute: swing between Min and Max. Relative: wobble ±Depth around the drawn curve.
enum Mode { ABSOLUTE, RELATIVE }

@export var enabled: bool = true
@export var shape: Shape = Shape.SINE
## Parameter units (e.g. Hz, dB). If min > max they are treated as swapped.
@export var max_value: float = 1.0
@export var min_value: float = 0.0
@export_range(0.05, 100.0, 0.01, "exp") var freq_hz: float = 4.0
## Frequency change per second (Hz/s; the panel shows dHz/s, tenths of a hertz per second, positive speeds up, negative slows down). A slowing
## LFO stops at 0 Hz and holds its last phase.
@export_range(-100.0, 100.0, 0.01) var freq_accel: float = 0.0
## How the fades are shaped: 0 = straight ramps, 1 = fully eased (smoothstep).
@export_range(0.0, 1.0, 0.01) var fade_smoothing: float = 0.0
@export var fade_in_sec: float = 0.25
@export var fade_out_sec: float = 0.25
## Active span in curve time. Phase is anchored at start_sec.
@export var start_sec: float = 0.0
@export var end_sec: float = 1.0
## Seed for the Random shape and for Jitter.
@export var random_seed: int = 1
@export var mode: Mode = Mode.ABSOLUTE
## Relative mode: swing ± this share of the parameter's range (on the curve's scale; 0.1 = ±10%).
@export_range(0.0, 1.0, 0.001) var depth: float = 0.1
## Where the cycle starts at start_sec, in degrees.
@export_range(0.0, 360.0, 0.1) var phase_deg: float = 0.0
## Randomizes each cycle's length (0..1; 1 = cycles vary by about ±50%).
@export_range(0.0, 1.0, 0.01) var jitter_rate: float = 0.0
## Randomizes each cycle's height (0..1; 1 = some cycles nearly flat).
@export_range(0.0, 1.0, 0.01) var jitter_depth: float = 0.0
## Softens the jumps of Square, Saw and Random (0 = hard, 1 = Square becomes a sine, Random fully smooth).
@export_range(0.0, 1.0, 0.01) var glide: float = 0.0
## ADSR on the swing (how much LFO is heard): Attack = fade_in_sec, then Decay falls from full to
## Sustain, which holds until Release = fade_out_sec, the last part of the span. (Before format 7,
## decay_sec was a half-life; old sounds are converted on open.)
@export_range(0.0, 240.0, 0.01) var decay_sec: float = 0.0
## Level held after Decay (0..1).
@export_range(0.0, 1.0, 0.01) var sustain: float = 1.0


## Everything that changes the LFO's output, for caches.
func signature() -> Array:
	return [shape, max_value, min_value, freq_hz, fade_in_sec, fade_out_sec, start_sec, end_sec, random_seed,
		freq_accel, fade_smoothing, mode, depth, phase_deg, jitter_rate, jitter_depth, glide, decay_sec, sustain]


## Pseudo-random 0..1 for integer k (same formula in C++).
static func hash01(k: float, seed: float) -> float:
	var r := sin(k * 12.9898 + seed * 78.233) * 43758.5453
	return r - floorf(r)


static func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


func span() -> float:
	return maxf(end_sec - start_sec, 0.0)


## Cycles completed at curve time t (the phase), with the frequency drifting by freq_accel.
func phase(t: float) -> float:
	var tau := t - start_sec
	if tau <= 0.0 or is_zero_approx(freq_accel):
		return tau * freq_hz
	if freq_accel < 0.0:
		var tz := freq_hz / -freq_accel # the moment the frequency reaches 0
		tau = minf(tau, tz)
	return freq_hz * tau + 0.5 * freq_accel * tau * tau


## Curve time at which the phase reaches `cycles`, or INF if it never does.
func time_of_phase(cycles: float) -> float:
	if is_zero_approx(freq_accel):
		return start_sec + cycles / maxf(freq_hz, 1e-6)
	var disc := freq_hz * freq_hz + 2.0 * freq_accel * cycles
	if disc < 0.0:
		return INF
	return start_sec + (-freq_hz + sqrt(disc)) / freq_accel


## Phase as heard: Phase offset plus Jitter's per-cycle stretch (still increasing).
func warped_phase(t: float) -> float:
	var p := phase(t) + phase_deg / 360.0
	if jitter_rate > 0.0:
		var k := floorf(p)
		var a := (hash01(k, random_seed + 17.0) - 0.5) * 0.5 * jitter_rate
		var b := (hash01(k + 1.0, random_seed + 17.0) - 0.5) * 0.5 * jitter_rate
		p += a + (b - a) * _smooth(p - k)
	return p


## Curve time in [start_sec, end_sec] where warped_phase reaches `cycles`, or INF (bisection;
## warped_phase never decreases).
func time_of_warped_phase(cycles: float) -> float:
	if warped_phase(end_sec) < cycles:
		return INF
	var a := start_sec
	var b := end_sec
	for i in 48:
		var m := (a + b) * 0.5
		if warped_phase(m) < cycles:
			a = m
		else:
			b = m
	return b


## Jitter's per-cycle height factor (1 = full), blended smoothly between cycles.
func cycle_amp(p: float) -> float:
	if jitter_depth <= 0.0:
		return 1.0
	var k := floorf(p)
	var a := 1.0 - jitter_depth * hash01(k, random_seed + 31.0)
	var b := 1.0 - jitter_depth * hash01(k + 1.0, random_seed + 31.0)
	return a + (b - a) * _smooth(p - k)


## Oscillator position 0..1 at curve time t (before Jitter's height factor).
func wave(t: float) -> float:
	return shape_at(warped_phase(t))


func shape_at(p: float) -> float:
	var fl := floorf(p)
	var ph := p - fl
	match shape:
		Shape.TRIANGLE:
			return 1.0 - absf(ph * 2.0 - 1.0)
		Shape.SQUARE:
			if glide <= 0.0:
				return 1.0 if ph < 0.5 else 0.0
			return 0.5 + 0.5 * clampf(sin(TAU * p) / glide, -1.0, 1.0)
		Shape.SAW:
			if glide <= 0.0 or ph < 1.0 - glide * 0.5:
				return ph / (1.0 - glide * 0.5)
			return 1.0 - _smooth((ph - (1.0 - glide * 0.5)) / (glide * 0.5))
		Shape.RANDOM:
			var r := hash01(fl, random_seed)
			if glide <= 0.0 or ph < 1.0 - glide:
				return r
			return r + (hash01(fl + 1.0, random_seed) - r) * _smooth((ph - (1.0 - glide)) / glide)
	return 0.5 + 0.5 * sin(TAU * p)


## Wave around its centre, -1..1, with Jitter's height applied.
func swing(t: float) -> float:
	var p := warped_phase(t)
	return (shape_at(p) * 2.0 - 1.0) * cycle_amp(p)


## Effective Attack (x) and Release (y): they never overlap, together at most the span.
func fades() -> Vector2:
	var fi := clampf(fade_in_sec, 0.0, span())
	var fo := clampf(fade_out_sec, 0.0, span() - fi)
	return Vector2(fi, fo)


## How much of the LFO is heard at curve time t: 0 = only the curve, 1 = only the LFO.
func envelope(t: float) -> float:
	if t < start_sec or t > end_sec or span() <= 0.0:
		return 0.0
	var f := fades()
	var rel_start := end_sec - f.y
	var e := ads_level(minf(t, rel_start) - start_sec, f.x)
	if f.y > 0.0 and t > rel_start:
		e *= _shape((end_sec - t) / f.y)
	return clampf(e, 0.0, 1.0)


## Attack, Decay, Sustain at `a` seconds after the start (attack length `att`).
func ads_level(a: float, att: float) -> float:
	if att > 0.0 and a < att:
		return _shape(a / att)
	if decay_sec > 0.0 and a < att + decay_sec:
		return 1.0 - (1.0 - sustain) * _shape((a - att) / decay_sec)
	return sustain


## A segment's 0..1 progress, eased by Smoothing.
func _shape(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return u + fade_smoothing * (u * u * (3.0 - 2.0 * u) - u)


## One-line description, e.g. "LFO sine 4.0 Hz · 0.20–0.80".
func summary(effect_type: String, param: String) -> String:
	var lo := minf(min_value, max_value)
	var hi := maxf(min_value, max_value)
	var spec := AWEffectLibrary.param_spec(effect_type, param)
	var unit: String = spec[4]
	var fmt := func(v: float) -> String: return AWEffectLibrary.format_value(effect_type, param, v).replace(" " + unit, "") if unit != "" else AWEffectLibrary.format_value(effect_type, param, v)
	if mode == Mode.RELATIVE:
		return "LFO %s %s Hz · ±%d%%" % [SHAPE_NAMES[shape].to_lower(), String.num(freq_hz, 2 if freq_hz < 1.0 else 1), int(round(depth * 100.0))]
	return "LFO %s %s Hz · %s–%s%s" % [SHAPE_NAMES[shape].to_lower(), String.num(freq_hz, 2 if freq_hz < 1.0 else 1),
		fmt.call(lo), fmt.call(hi), (" " + unit) if unit != "" else ""]
