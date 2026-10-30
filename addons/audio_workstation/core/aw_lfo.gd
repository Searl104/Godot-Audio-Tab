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

@export var enabled: bool = true
@export var shape: Shape = Shape.SINE
## Parameter units (e.g. Hz, dB). If min > max they are treated as swapped.
@export var max_value: float = 1.0
@export var min_value: float = 0.0
@export_range(0.05, 20.0, 0.01, "exp") var freq_hz: float = 4.0
## Frequency change per second (Hz/s; the panel shows mHz/s, positive speeds up, negative slows down). A slowing
## LFO stops at 0 Hz and holds its last phase.
@export_range(-5.0, 5.0, 0.001) var freq_accel: float = 0.0
## How the fades are shaped: 0 = straight ramps, 1 = fully eased (smoothstep).
@export_range(0.0, 1.0, 0.01) var fade_smoothing: float = 0.0
@export var fade_in_sec: float = 0.25
@export var fade_out_sec: float = 0.25
## Active span in curve time. Phase is anchored at start_sec.
@export var start_sec: float = 0.0
@export var end_sec: float = 1.0
## Seed for the Random (sample-and-hold) shape.
@export var random_seed: int = 1


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


## Oscillator position 0..1 at curve time t.
func wave(t: float) -> float:
	var p := phase(t)
	var ph := p - floorf(p)
	match shape:
		Shape.TRIANGLE:
			return 1.0 - absf(ph * 2.0 - 1.0)
		Shape.SQUARE:
			return 1.0 if ph < 0.5 else 0.0
		Shape.SAW:
			return ph
		Shape.RANDOM:
			var r := sin(floorf(p) * 12.9898 + random_seed * 78.233) * 43758.5453
			return r - floorf(r)
	return 0.5 + 0.5 * sin(TAU * p)


## Effective fades (they never overlap: together at most the span).
func fades() -> Vector2:
	var fi := clampf(fade_in_sec, 0.0, span())
	var fo := clampf(fade_out_sec, 0.0, span() - fi)
	return Vector2(fi, fo)


## How much of the LFO is heard at curve time t: 0 = only the curve, 1 = only the LFO.
func envelope(t: float) -> float:
	if t < start_sec or t > end_sec or span() <= 0.0:
		return 0.0
	var f := fades()
	var e := 1.0
	if f.x > 0.0:
		e = minf(e, (t - start_sec) / f.x)
	if f.y > 0.0:
		e = minf(e, (end_sec - t) / f.y)
	e = clampf(e, 0.0, 1.0)
	return e + fade_smoothing * (e * e * (3.0 - 2.0 * e) - e)


## One-line description, e.g. "LFO sine 4.0 Hz · 0.20–0.80".
func summary(effect_type: String, param: String) -> String:
	var lo := minf(min_value, max_value)
	var hi := maxf(min_value, max_value)
	var spec := AWEffectLibrary.param_spec(effect_type, param)
	var unit: String = spec[4]
	var fmt := func(v: float) -> String: return AWEffectLibrary.format_value(effect_type, param, v).replace(" " + unit, "") if unit != "" else AWEffectLibrary.format_value(effect_type, param, v)
	return "LFO %s %s Hz · %s–%s%s" % [SHAPE_NAMES[shape].to_lower(), String.num(freq_hz, 2 if freq_hz < 1.0 else 1),
		fmt.call(lo), fmt.call(hi), (" " + unit) if unit != "" else ""]
