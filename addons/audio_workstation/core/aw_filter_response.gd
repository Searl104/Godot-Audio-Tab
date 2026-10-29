@tool
class_name AWFilterResponse
extends RefCounted
## Frequency response of the engine's filters, for drawing. The maths mirrors
## extension/src/aw_effects.cpp (RBJ biquads, same resonance-to-Q map, same EQ6 bands),
## so what the panel draws is what the engine does.

const EQ_FREQS := [32.0, 100.0, 320.0, 1000.0, 3200.0, 10000.0]
const EQ_Q := 1.0


static func resonance_to_q(res: float) -> float:
	var r := clampf(res, 0.0, 1.0)
	if r <= 0.5:
		return 0.35 + (r / 0.5) * (0.707 - 0.35)
	return 0.707 * pow(20.0, (r - 0.5) / 0.5)


## |H| in dB of the biquad (b0 b1 b2 a0 a1 a2, unnormalised) at frequency f.
static func _mag_db(c: PackedFloat64Array, f: float, sr: float) -> float:
	var w := TAU * f / sr
	var c1 := cos(w)
	var s1 := sin(w)
	var c2 := cos(2.0 * w)
	var s2 := sin(2.0 * w)
	var nr := c[0] + c[1] * c1 + c[2] * c2
	var ni := -(c[1] * s1 + c[2] * s2)
	var dr := c[3] + c[4] * c1 + c[5] * c2
	var di := -(c[4] * s1 + c[5] * s2)
	var n := nr * nr + ni * ni
	var d := dr * dr + di * di
	return 10.0 * log(maxf(n, 1e-30) / maxf(d, 1e-30)) / log(10.0)


static func _clamp_hz(fc: float, sr: float) -> float:
	return clampf(fc, 10.0, sr * 0.49)


static func lowpass_coeffs(cutoff: float, res: float, sr: float) -> PackedFloat64Array:
	var w0 := TAU * _clamp_hz(cutoff, sr) / sr
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * resonance_to_q(res))
	return PackedFloat64Array([(1 - cw) * 0.5, 1 - cw, (1 - cw) * 0.5, 1 + alpha, -2 * cw, 1 - alpha])


static func peaking_coeffs(f0: float, gain_db: float, q: float, sr: float) -> PackedFloat64Array:
	var a := pow(10.0, gain_db / 40.0)
	var w0 := TAU * _clamp_hz(f0, sr) / sr
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * q)
	return PackedFloat64Array([1 + alpha * a, -2 * cw, 1 - alpha * a, 1 + alpha / a, -2 * cw, 1 - alpha / a])


static func lowpass_db(f: float, cutoff: float, res: float, sr: float) -> float:
	return _mag_db(lowpass_coeffs(cutoff, res, sr), f, sr)


## Total EQ6 response: gains is the six band dB values in EQ_FREQS order.
static func eq_db(f: float, gains: PackedFloat32Array, sr: float) -> float:
	var total := 0.0
	for i in 6:
		total += _mag_db(peaking_coeffs(EQ_FREQS[i], gains[i], EQ_Q, sr), f, sr)
	return total


## Response curve sampled on a log frequency axis (20 Hz..20 kHz) for drawing.
static func sample_log(fn: Callable, points: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points)
	for i in points:
		out[i] = fn.call(freq_at(float(i) / (points - 1)))
	return out


static func freq_at(n: float) -> float:
	return 20.0 * pow(1000.0, clampf(n, 0.0, 1.0))


static func norm_of(f: float) -> float:
	return clampf(log(maxf(f, 20.0) / 20.0) / log(1000.0), 0.0, 1.0)


## Inverse of resonance_to_q, for dragging the low-pass peak.
static func q_to_resonance(q: float) -> float:
	q = clampf(q, 0.35, 0.707 * 20.0)
	if q <= 0.707:
		return (q - 0.35) / (0.707 - 0.35) * 0.5
	return 0.5 + 0.5 * log(q / 0.707) / log(20.0)
