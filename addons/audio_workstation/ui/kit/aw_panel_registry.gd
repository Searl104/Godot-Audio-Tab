@tool
class_name AWPanelRegistry
extends RefCounted
## Maps an effect type to its custom panel. Effects without an entry use the generic
## parameter rows on the card. To give a new effect a panel: write an AWEffectPanel
## subclass (full layout, plus a compact one for the card) and add it to PANELS here.

const PANELS := {
	"Low Pass": preload("../panels/aw_filter_panel.gd"),
	"High Pass": preload("../panels/aw_filter_panel.gd"),
	"Band Pass": preload("../panels/aw_filter_panel.gd"),
	"Amplify": preload("../panels/aw_amplify_panel.gd"),
	"Distortion": preload("../panels/aw_distortion_panel.gd"),
	"Delay": preload("../panels/aw_delay_panel.gd"),
	"Compressor": preload("../panels/aw_compressor_panel.gd"),
	"Limiter": preload("../panels/aw_limiter_panel.gd"),
	"EQ": preload("../panels/aw_eq_panel.gd"),
	"Reverb": preload("../panels/aw_reverb_panel.gd"),
	"Gate": preload("../panels/aw_gate_panel.gd"),
	"Chorus": preload("../panels/aw_knob_panel.gd"),
	"Phaser": preload("../panels/aw_knob_panel.gd"),
	"Stereo Enhance": preload("../panels/aw_knob_panel.gd"),
}


## Effect types to treat as having no panel (so the generic rows show). For the tests of the rows.
static var suppressed := PackedStringArray()


static func has_panel(effect_type: String) -> bool:
	return PANELS.has(effect_type) and not suppressed.has(effect_type)


static func create(effect_type: String) -> AWEffectPanel:
	return PANELS[effect_type].new() if has_panel(effect_type) else null
