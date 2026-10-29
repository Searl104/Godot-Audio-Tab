@tool
class_name AWSampler
extends RefCounted
## Evaluates automation curves over many times at once.
##
## With the native engine, this is one call into AWCore.sample_curve (a C++ port of
## AWChain.sample / sample_norm). Without it, the same values come from the GDScript
## functions, only slower. AWChain.sample and sample_norm stay the reference; the
## self-test compares both paths.
##
## Units: what each returned value means.

const VALUE := 0 ## the parameter's real value (what AWChain.sample returns)
const NORM := 1 ## height 0..1 on the curve's scale, LFO included (AWChain.sample_norm)
const GAIN := 2 ## linear gain from a dB parameter; -60 dB (the bottom of the range) is silence
const RATE := 3 ## playback rate from a semitone parameter
const BASE_NORM := 4 ## the drawn curve alone, without the LFO (AWChain.base_norm)

## Number of sampling calls so far (diagnostics; the self-test checks caching with it).
static var calls := 0
static var _core: Object
static var _probed := false


## The shared native core used for sampling, or null when it isn't built / is too old.
static func native() -> Object:
	if not _probed:
		_probed = true
		if ClassDB.class_exists(&"AWCore") and ClassDB.can_instantiate(&"AWCore"):
			var c: Object = ClassDB.instantiate(&"AWCore")
			if c.has_method("sample_curve") and c.has_method("sample_curve_at"):
				_core = c
	return _core


## Values at start + i * step, i in [0, count).
static func values(chain: AWChain, curve: AWCurve, start: float, step: float, count: int, unit: int) -> PackedFloat32Array:
	calls += 1
	var core := native()
	if core:
		return core.call("sample_curve", chain.automation, chain.native_spec(curve), start, step, count, unit)
	var out := PackedFloat32Array()
	out.resize(count)
	for i in count:
		out[i] = _one(chain, curve, start + i * step, unit)
	return out


## Values at arbitrary times (not necessarily evenly spaced).
static func values_at(chain: AWChain, curve: AWCurve, times: PackedFloat64Array, unit: int) -> PackedFloat32Array:
	calls += 1
	var core := native()
	if core:
		return core.call("sample_curve_at", chain.automation, chain.native_spec(curve), times, unit)
	var out := PackedFloat32Array()
	out.resize(times.size())
	for i in times.size():
		out[i] = _one(chain, curve, times[i], unit)
	return out


## The GDScript reference path for a single time.
static func _one(chain: AWChain, curve: AWCurve, t: float, unit: int) -> float:
	match unit:
		NORM:
			return chain.sample_norm(curve, t)
		BASE_NORM:
			return chain.base_norm(curve, t)
		GAIN:
			var db := chain.sample(curve, t)
			return 0.0 if db <= -59.9 else db_to_linear(db)
		RATE:
			return pow(2.0, chain.sample(curve, t) / 12.0)
	return chain.sample(curve, t)
