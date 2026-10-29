@tool
class_name AWPanelRegistry
extends RefCounted
## Maps an effect type to its custom panel. Effects without an entry use the generic
## parameter rows on the card. To give a new effect a panel: write an AWEffectPanel
## subclass, add it to PANELS here, and (if it has a frequency response) to response().

const PANELS := {
	"Low Pass": preload("../panels/aw_lowpass_panel.gd"),
	"EQ": preload("../panels/aw_eq_panel.gd"),
}


static func has_panel(effect_type: String) -> bool:
	return PANELS.has(effect_type)


static func create(effect_type: String) -> AWEffectPanel:
	return PANELS[effect_type].new() if PANELS.has(effect_type) else null


## Sampled response in dB for the card thumbnail; empty when the effect has none.
static func response(doc: AWDocument, chain: AWChain, effect: AWEffect, points: int) -> PackedFloat32Array:
	var sr := AudioServer.get_mix_rate()
	match effect.effect_type:
		"Low Pass":
			var fc := AWParamBinding.new(doc, chain, effect, "cutoff_hz").live_value()
			var res := AWParamBinding.new(doc, chain, effect, "resonance").live_value()
			return AWFilterResponse.sample_log(func(f: float) -> float: return AWFilterResponse.lowpass_db(f, fc, res, sr), points)
		"EQ":
			var g := PackedFloat32Array()
			for k: String in AWEffectLibrary.param_schema("EQ"):
				g.append(AWParamBinding.new(doc, chain, effect, k).live_value())
			return AWFilterResponse.sample_log(func(f: float) -> float: return AWFilterResponse.eq_db(f, g, sr), points)
	return PackedFloat32Array()
