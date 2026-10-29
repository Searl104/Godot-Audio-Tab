@tool
class_name AWEffectPanel
extends VBoxContainer
## Base class for a custom effect panel. A panel is built from kit widgets that edit
## parameters through AWParamBinding, so it never touches undo or curves itself.
## Subclasses override build() and refresh().

var doc: AWDocument
var chain: AWChain
var effect: AWEffect


func setup(p_doc: AWDocument, p_chain: AWChain, p_effect: AWEffect) -> void:
	doc = p_doc
	chain = p_chain
	effect = p_effect
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	build()
	refresh()


func bind(param: String, scale := -1) -> AWParamBinding:
	return AWParamBinding.new(doc, chain, effect, param, scale)


func accent() -> Color:
	return AWEffectLibrary.effect_color(effect.effect_type)


func build() -> void:
	pass


func refresh() -> void:
	pass

