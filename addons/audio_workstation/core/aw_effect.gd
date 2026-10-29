@tool
class_name AWEffect
extends Resource
## One card in an effect chain. Static parameter values live in `params`;
## a parameter with an AWCurve in the same chain is driven by the curve instead.

## Unique within its chain. Curves reference effects by this id.
@export var id: int = 0
@export var effect_type: String = "Reverb"
@export var bypass: bool = false
@export var params: Dictionary = {}


func is_fixed() -> bool:
	return AWEffectLibrary.is_fixed(effect_type)


func get_param(key: String) -> float:
	return params.get(key, AWEffectLibrary.param_spec(effect_type, key)[2])


static func create(type: String, p_id: int) -> AWEffect:
	var e := AWEffect.new()
	e.effect_type = type
	e.id = p_id
	e.params = AWEffectLibrary.default_params(type)
	return e
