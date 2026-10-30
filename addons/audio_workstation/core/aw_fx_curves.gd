@tool
class_name AWFxCurves
extends RefCounted
## Static transfer curves of the dynamics and distortion effects, for drawing. They mirror
## extension/src/aw_effects.cpp, and the self-test checks them against the engine's output.


## Waveshaper constant for the Distortion drive (0..1): tanh(k x) / k.
static func dist_k(drive: float) -> float:
	return 1.0 + 19.0 * clampf(drive, 0.0, 1.0)


static func shape(x: float, k: float) -> float:
	return tanh(k * x) / k


## Distortion output for an input amplitude (the keep-HF split is not part of a static curve).
static func distortion(x: float, drive: float, pre_db: float, post_db: float) -> float:
	return shape(x * db_to_linear(pre_db), dist_k(drive)) * db_to_linear(post_db)


## Compressor output level (dB) for an input level, with makeup and mix applied.
static func compressor_db(in_db: float, thr: float, ratio: float, makeup_db: float, mix: float) -> float:
	var over := maxf(in_db - thr, 0.0)
	var wet_db := in_db - over * (1.0 - 1.0 / maxf(ratio, 1.0)) + makeup_db
	var lin := (1.0 - mix) * db_to_linear(in_db) + mix * db_to_linear(wet_db)
	return linear_to_db(maxf(lin, 1e-6))


## Limiter output level (dB): pre-gain, then nothing above the ceiling.
static func limiter_db(in_db: float, pre_db: float, ceiling_db: float) -> float:
	return minf(in_db + pre_db, minf(ceiling_db, 0.0))
