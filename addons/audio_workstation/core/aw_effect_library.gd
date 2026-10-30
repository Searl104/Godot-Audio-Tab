@tool
class_name AWEffectLibrary
extends RefCounted
## Catalogue of effects. Parameter keys are the real property names on the Godot
## AudioEffect class, so the logic phase can apply values with effect.set(key, value).
##
## params: key -> [min, max, default, step, unit, label]
## "engine": present when the native engine can run the effect: its numeric type id (must match
##   aw::EffectType in extension/src/aw_effects.h) and whether it rings on after its input stops
##   (so it needs a tail). The engine receives parameters in the order of "params" below.
## "Clip" and "Output" are fixed source cards (always first, can't be removed):
##   Clip   = per-clip gain, pitch (applied as playback rate) and pan.
##   Output = master output volume.

const CLIP_SOURCE := "Clip"
const MASTER_OUTPUT := "Output"

const EFFECTS := {
	"Clip": {
		"godot_class": "", "fixed": true,
		"params": {
			"gain_db": [-60.0, 24.0, 0.0, 0.1, "dB", "Gain"],
			"pitch_semitones": [-24.0, 24.0, 0.0, 0.01, "st", "Pitch"],
			"pan": [-1.0, 1.0, 0.0, 0.01, "", "Pan"],
		},
	},
	"Output": {
		"godot_class": "", "fixed": true,
		"params": {
			"volume_db": [-60.0, 12.0, 0.0, 0.1, "dB", "Volume"],
		},
	},
	"Reverb": {
		"godot_class": "AudioEffectReverb",
		"params": {
			"room_size": [0.0, 1.0, 0.8, 0.01, "", "Room"],
			"damping": [0.0, 1.0, 0.5, 0.01, "", "Damping"],
			"spread": [0.0, 1.0, 1.0, 0.01, "", "Spread"],
			"wet": [0.0, 1.0, 0.5, 0.01, "", "Wet"],
			"dry": [0.0, 1.0, 1.0, 0.01, "", "Dry"],
		},
	},
	"Delay": {
		"godot_class": "AudioEffectDelay",
		"params": {
			"tap1_delay_ms": [0.0, 1500.0, 250.0, 1.0, "ms", "Time"],
			"tap1_level_db": [-60.0, 0.0, -6.0, 0.1, "dB", "Level"],
			"feedback_level_db": [-60.0, 0.0, -6.0, 0.1, "dB", "Feedback"],
			"dry": [0.0, 1.0, 1.0, 0.01, "", "Dry"],
		},
	},
	"Chorus": {
		"godot_class": "AudioEffectChorus",
		"params": {
			"voice/1/rate_hz": [0.1, 20.0, 0.8, 0.01, "Hz", "Rate"],
			"voice/1/depth_ms": [0.0, 20.0, 2.0, 0.01, "ms", "Depth"],
			"wet": [0.0, 1.0, 0.5, 0.01, "", "Wet"],
			"dry": [0.0, 1.0, 1.0, 0.01, "", "Dry"],
		},
	},
	"Phaser": {
		"godot_class": "AudioEffectPhaser",
		"params": {
			"rate_hz": [0.01, 20.0, 0.5, 0.01, "Hz", "Rate"],
			"feedback": [0.1, 0.9, 0.7, 0.01, "", "Feedback"],
			"depth": [0.1, 4.0, 1.0, 0.01, "", "Depth"],
		},
	},
	"Distortion": {
		"godot_class": "AudioEffectDistortion",
		"params": {
			"drive": [0.0, 1.0, 0.3, 0.01, "", "Drive"],
			"pre_gain": [-60.0, 60.0, 0.0, 0.1, "dB", "Pre Gain"],
			"post_gain": [-80.0, 24.0, 0.0, 0.1, "dB", "Post Gain"],
			"keep_hf_hz": [1.0, 20500.0, 16000.0, 1.0, "Hz", "Keep HF"],
		},
	},
	"Low Pass": {
		"godot_class": "AudioEffectLowPassFilter", "engine": {"id": 1, "rings": true}, "color": "#4f9edb",
		"params": {
			"cutoff_hz": [20.0, 20500.0, 2000.0, 1.0, "Hz", "Cutoff"],
			"resonance": [0.0, 1.0, 0.5, 0.01, "", "Resonance"],
		},
	},
	"High Pass": {
		"godot_class": "AudioEffectHighPassFilter", "color": "#e08a4f", "engine": {"id": 2, "rings": true},
		"params": {
			"cutoff_hz": [20.0, 20500.0, 200.0, 1.0, "Hz", "Cutoff"],
			"resonance": [0.0, 1.0, 0.5, 0.01, "", "Resonance"],
		},
	},
	"Band Pass": {
		"godot_class": "AudioEffectBandPassFilter", "color": "#b07fe0", "engine": {"id": 3, "rings": true},
		"params": {
			"cutoff_hz": [20.0, 20500.0, 1000.0, 1.0, "Hz", "Cutoff"],
			"resonance": [0.0, 1.0, 0.5, 0.01, "", "Resonance"],
		},
	},
	"EQ": {
		"godot_class": "AudioEffectEQ6", "engine": {"id": 4, "rings": true}, "color": "#5ec26a",
		"params": {
			"band_db/32_hz": [-60.0, 24.0, 0.0, 0.1, "dB", "32 Hz"],
			"band_db/100_hz": [-60.0, 24.0, 0.0, 0.1, "dB", "100 Hz"],
			"band_db/320_hz": [-60.0, 24.0, 0.0, 0.1, "dB", "320 Hz"],
			"band_db/1000_hz": [-60.0, 24.0, 0.0, 0.1, "dB", "1 kHz"],
			"band_db/3200_hz": [-60.0, 24.0, 0.0, 0.1, "dB", "3.2 kHz"],
			"band_db/10000_hz": [-60.0, 24.0, 0.0, 0.1, "dB", "10 kHz"],
		},
	},
	"Compressor": {
		"godot_class": "AudioEffectCompressor",
		"params": {
			"threshold": [-60.0, 0.0, -12.0, 0.1, "dB", "Threshold"],
			"ratio": [1.0, 48.0, 4.0, 0.1, ":1", "Ratio"],
			"gain": [-20.0, 20.0, 0.0, 0.1, "dB", "Gain"],
			"attack_us": [20.0, 2000.0, 20.0, 1.0, "µs", "Attack"],
			"release_ms": [20.0, 2000.0, 250.0, 1.0, "ms", "Release"],
			"mix": [0.0, 1.0, 1.0, 0.01, "", "Mix"],
		},
	},
	"Limiter": {
		"godot_class": "AudioEffectHardLimiter",
		"params": {
			"pre_gain_db": [-24.0, 24.0, 0.0, 0.1, "dB", "Pre Gain"],
			"ceiling_db": [-24.0, 0.0, -0.3, 0.1, "dB", "Ceiling"],
			"release": [0.01, 1.0, 0.1, 0.01, "s", "Release"],
		},
	},
	"Amplify": {
		"godot_class": "AudioEffectAmplify", "color": "#d9b84a", "engine": {"id": 5, "rings": false},
		"params": {
			"volume_db": [-80.0, 24.0, 0.0, 0.1, "dB", "Volume"],
		},
	},
	"Stereo Enhance": {
		"godot_class": "AudioEffectStereoEnhance",
		"params": {
			"pan_pullout": [0.0, 4.0, 1.0, 0.01, "", "Width"],
			"time_pullout_ms": [0.0, 50.0, 0.0, 0.1, "ms", "Time"],
			"surround": [0.0, 1.0, 0.0, 0.01, "", "Surround"],
		},
	},
}

## Colours handed out to new curves, in order.
const CURVE_COLORS := [
	Color("#4f9edb"), Color("#5ec26a"), Color("#e8834a"), Color("#e6c84a"),
	Color("#b38bfa"), Color("#e8607a"), Color("#4fc9c0"), Color("#d96ab2"),
]


static func addable_names() -> PackedStringArray:
	var out := PackedStringArray()
	for k: String in EFFECTS:
		if not EFFECTS[k].get("fixed", false):
			out.append(k)
	return out


static func is_fixed(effect: String) -> bool:
	return EFFECTS.has(effect) and EFFECTS[effect].get("fixed", false)


static func godot_class(effect: String) -> String:
	return EFFECTS[effect]["godot_class"] if EFFECTS.has(effect) else ""


static func param_schema(effect: String) -> Dictionary:
	return EFFECTS[effect]["params"] if EFFECTS.has(effect) else {}


static func param_spec(effect: String, param: String) -> Array:
	var schema := param_schema(effect)
	return schema[param] if schema.has(param) else [0.0, 1.0, 0.0, 0.01, "", param]


static func param_label(effect: String, param: String) -> String:
	return param_spec(effect, param)[5]


## Natural curve scale for a parameter: LOG for frequencies, FADER for decibels.
static func default_scale(effect: String, param: String) -> int:
	var spec := param_spec(effect, param)
	var unit: String = spec[4]
	if unit == "Hz" and float(spec[0]) > 0.0:
		return AWCurve.Scale.LOG
	if unit == "dB":
		return AWCurve.Scale.FADER
	return AWCurve.Scale.LINEAR


## Native engine type id for an effect card, or 0 when the engine can't run it yet (skipped, no sound).
static func engine_id(effect: String) -> int:
	return int(EFFECTS.get(effect, {}).get("engine", {}).get("id", 0))


## True when the effect keeps sounding after its input stops (it needs a tail).
static func engine_rings(effect: String) -> bool:
	return bool(EFFECTS.get(effect, {}).get("engine", {}).get("rings", false))


## Parameter keys in the order the engine expects (the schema's order).
static func engine_keys(effect: String) -> Array:
	return param_schema(effect).keys()


static func default_params(effect: String) -> Dictionary:
	var out := {}
	var schema := param_schema(effect)
	for key: String in schema:
		out[key] = schema[key][2]
	return out


static func format_value(effect: String, param: String, value: float) -> String:
	var spec := param_spec(effect, param)
	var step: float = spec[3]
	var unit: String = spec[4]
	var decimals := 0 if step >= 1.0 else (1 if step >= 0.1 else 2)
	var text := String.num(value, decimals)
	return text + (" " + unit if unit != "" else "")


static func effect_color(effect: String) -> Color:
	if is_fixed(effect):
		return Color("#9aa4b2")
	if EFFECTS.has(effect) and EFFECTS[effect].has("color"):
		return Color(EFFECTS[effect]["color"])
	var idx := EFFECTS.keys().find(effect)
	return Color.from_hsv(fmod(float(maxi(idx, 0)) * 0.13, 1.0), 0.45, 0.85)
