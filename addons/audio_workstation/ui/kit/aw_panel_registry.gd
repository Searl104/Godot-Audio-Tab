@tool
class_name AWPanelRegistry
extends RefCounted
## Maps an effect type to its custom panel. Effects without an entry use the generic
## parameter rows on the card. To give a new effect a panel: write an AWEffectPanel
## subclass (full layout, plus a compact one for the card) and add it to PANELS here.

const PANELS := {
	"Low Pass": preload("../panels/aw_lowpass_panel.gd"),
	"EQ": preload("../panels/aw_eq_panel.gd"),
}


static func has_panel(effect_type: String) -> bool:
	return PANELS.has(effect_type)


static func create(effect_type: String) -> AWEffectPanel:
	return PANELS[effect_type].new() if PANELS.has(effect_type) else null
