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


static func highpass_coeffs(cutoff: float, res: float, sr: float) -> PackedFloat64Array:
	var w0 := TAU * _clamp_hz(cutoff, sr) / sr
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * resonance_to_q(res))
	return PackedFloat64Array([(1 + cw) * 0.5, -(1 + cw), (1 + cw) * 0.5, 1 + alpha, -2 * cw, 1 - alpha])


## Band pass with 0 dB at the centre.
static func bandpass_coeffs(cutoff: float, res: float, sr: float) -> PackedFloat64Array:
	var w0 := TAU * _clamp_hz(cutoff, sr) / sr
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * resonance_to_q(res))
	return PackedFloat64Array([alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha])


static func peaking_coeffs(f0: float, gain_db: float, q: float, sr: float) -> PackedFloat64Array:
	var a := pow(10.0, gain_db / 40.0)
	var w0 := TAU * _clamp_hz(f0, sr) / sr
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * q)
	return PackedFloat64Array([1 + alpha * a, -2 * cw, 1 - alpha * a, 1 + alpha / a, -2 * cw, 1 - alpha / a])


static func lowpass_db(f: float, cutoff: float, res: float, sr: float) -> float:
	return _mag_db(lowpass_coeffs(cutoff, res, sr), f, sr)


## Response of a Low Pass / High Pass / Band Pass card at frequency f.
static func filter_db(kind: String, f: float, cutoff: float, res: float, sr: float) -> float:
	match kind:
		"High Pass":
			return _mag_db(highpass_coeffs(cutoff, res, sr), f, sr)
		"Band Pass":
			return _mag_db(bandpass_coeffs(cutoff, res, sr), f, sr)
	return _mag_db(lowpass_coeffs(cutoff, res, sr), f, sr)


# --- The Filter card (mirrors MultiFilterFx in aw_effects.cpp) ---------------------------

## Complex response of a biquad (b0 b1 b2 a0 a1 a2) at frequency f, as Vector2(re, im).
static func _h(c: PackedFloat64Array, f: float, sr: float) -> Vector2:
	var w := TAU * f / sr
	var n := Vector2(c[0] + c[1] * cos(w) + c[2] * cos(2.0 * w), -(c[1] * sin(w) + c[2] * sin(2.0 * w)))
	var d := Vector2(c[3] + c[4] * cos(w) + c[5] * cos(2.0 * w), -(c[4] * sin(w) + c[5] * sin(2.0 * w)))
	return _cdiv(n, d)


static func _cmul(a: Vector2, b: Vector2) -> Vector2:
	return Vector2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)


static func _cdiv(a: Vector2, b: Vector2) -> Vector2:
	var m := maxf(b.x * b.x + b.y * b.y, 1e-30)
	return Vector2((a.x * b.x + a.y * b.y) / m, (a.y * b.x - a.x * b.y) / m)


## The four biquad stages of a Filter card (stage 0 takes the resonance; pass modes use
## Butterworth Q for the rest; band pass and notch use the resonance throughout).
static func filter_card_stages(mode: int, fc: float, res: float, gain: float, sr: float) -> Array:
	var w0 := TAU * clampf(fc, 10.0, sr * 0.45) / sr
	var cw := cos(w0)
	var sw := sin(w0)
	var q0 := resonance_to_q(res)
	var out := []
	for i in 4:
		var q := q0 if (i == 0 or mode == 2 or mode == 3) else 0.70710678
		var alpha := sw / (2.0 * q)
		match mode:
			0: out.append(PackedFloat64Array([(1 - cw) * 0.5, 1 - cw, (1 - cw) * 0.5, 1 + alpha, -2 * cw, 1 - alpha]))
			1: out.append(PackedFloat64Array([(1 + cw) * 0.5, -(1 + cw), (1 + cw) * 0.5, 1 + alpha, -2 * cw, 1 - alpha]))
			2: out.append(PackedFloat64Array([alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha]))
			3: out.append(PackedFloat64Array([1, -2 * cw, 1, 1 + alpha, -2 * cw, 1 - alpha]))
			_:
				var A := pow(10.0, gain / 40.0)
				var sa := 2.0 * sqrt(A) * alpha
				if mode == 4:
					out.append(PackedFloat64Array([A * ((A + 1) - (A - 1) * cw + sa), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - sa),
						(A + 1) + (A - 1) * cw + sa, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - sa]))
				elif mode == 5:
					out.append(PackedFloat64Array([A * ((A + 1) + (A - 1) * cw + sa), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - sa),
						(A + 1) - (A - 1) * cw + sa, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sa]))
				else:
					out.append(PackedFloat64Array([1 + alpha * A, -2 * cw, 1 - alpha * A, 1 + alpha / A, -2 * cw, 1 - alpha / A]))
	return out


## |H| in dB of a Filter card at frequency f (the slope blend included).
static func filter_card_db(f: float, mode: int, fc: float, res: float, gain: float, slope: float, sr: float) -> float:
	var st := filter_card_stages(mode, fc, res, gain, sr)
	if mode >= 4:
		return _db(_h(st[0], f, sr))
	var w := TAU * f / sr
	var a := 1.0 - exp(-TAU * clampf(fc, 10.0, sr * 0.45) / sr)
	# One-pole low pass: a / (1 - (1 - a) e^-jw); high pass is 1 minus it.
	var pole := _cdiv(Vector2(a, 0.0), Vector2(1.0 - (1.0 - a) * cos(w), (1.0 - a) * sin(w)))
	if mode == 1:
		pole = Vector2(1.0, 0.0) - pole
	var ys: Array[Vector2] = [pole]
	var acc := Vector2(1.0, 0.0)
	for c: PackedFloat64Array in st:
		acc = _cmul(acc, _h(c, f, sr))
		ys.append(acc)
	var depth := clampf(slope, 6.0, 48.0) / 12.0
	if mode >= 2:
		depth = maxf(depth, 1.0)
	var y: Vector2
	if depth < 1.0:
		y = ys[0].lerp(ys[1], (depth - 0.5) / 0.5)
	else:
		var lo := mini(4, floori(depth))
		y = ys[4] if lo >= 4 else ys[lo].lerp(ys[lo + 1], depth - lo)
	return _db(y)


static func _db(h: Vector2) -> float:
	return 10.0 * log(maxf(h.x * h.x + h.y * h.y, 1e-30)) / log(10.0)


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
