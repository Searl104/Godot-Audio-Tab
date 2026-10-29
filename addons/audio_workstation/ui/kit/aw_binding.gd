@tool
class_name AWParamBinding
extends RefCounted
## The one place where a control talks to a parameter. Every kit widget (knob, fader,
## plot handle) edits through this, so undo, the curve dot, "driven by a curve" display
## and the right-click menu behave identically everywhere.
##
##   preview()/commit() : live drag, then one undo step
##   set_value()        : a single undoable edit
##   live_value()       : the curve's value at the playhead if driven, else the static value

var doc: AWDocument
var chain: AWChain
var effect: AWEffect
var param: String
var lo: float
var hi: float
var step: float
var unit: String
var label: String
## How a 0..1 control position maps to the value: AWCurve.Scale.LINEAR / LOG / FADER.
var scale: int
var _orig := 0.0
var dragging := false


func _init(p_doc: AWDocument, p_chain: AWChain, p_effect: AWEffect, p_param: String, p_scale := -1) -> void:
	doc = p_doc
	chain = p_chain
	effect = p_effect
	param = p_param
	var spec := AWEffectLibrary.param_spec(effect.effect_type, param)
	lo = spec[0]
	hi = spec[1]
	step = spec[3]
	unit = spec[4]
	label = spec[5]
	scale = p_scale if p_scale >= 0 else AWEffectLibrary.default_scale(effect.effect_type, param)


func default_value() -> float:
	return AWEffectLibrary.param_spec(effect.effect_type, param)[2]


func curve() -> AWCurve:
	return chain.get_curve(effect.id, param)


func has_curve() -> bool:
	return curve() != null


func value() -> float:
	return effect.get_param(param)


func live_value() -> float:
	var c := curve()
	if c == null:
		return value()
	var local := clampf(doc.chain_local_time(chain, doc.playhead_sec), 0.0, doc.curve_domain_len())
	return chain.sample(c, local)


func to_norm(v: float) -> float:
	return AWCurveMath.to_norm(scale, v, lo, hi)


func from_norm(n: float) -> float:
	return snappedf(AWCurveMath.from_norm(scale, n, lo, hi), step)


func text(v := NAN) -> String:
	return AWEffectLibrary.format_value(effect.effect_type, param, live_value() if is_nan(v) else v)


func begin() -> void:
	dragging = true
	_orig = value()


func preview(v: float) -> void:
	doc.preview_param(effect, param, clampf(v, lo, hi))


## Ends a drag: puts the original back and records the change as one undo step.
func commit() -> void:
	if not dragging:
		return
	dragging = false
	var now := value()
	doc.preview_param(effect, param, _orig)
	doc.set_param(effect, param, now)


func set_value(v: float) -> void:
	doc.set_param(effect, param, clampf(v, lo, hi))


func reset() -> void:
	set_value(default_value())


## Clicking a driven control selects its curve in the graph.
func select_curve() -> void:
	var c := curve()
	if c:
		doc.set_active_curve(c)


func open_menu(owner: Control, pos: Vector2, menu: PopupMenu = null) -> void:
	var m := menu
	if m == null:
		m = PopupMenu.new()
		owner.add_child(m)
		m.popup_hide.connect(m.queue_free, CONNECT_DEFERRED)
	if not m.id_pressed.is_connected(on_menu):
		m.id_pressed.connect(on_menu)
	var c := curve()
	m.clear()
	if c == null:
		m.add_item("Make Curve", 1)
		m.add_item("Add LFO…", 20)
		m.add_item("Reset to Default", 3)
	else:
		m.add_item("Select Curve", 4)
		m.add_radio_check_item("On", 10)
		m.set_item_checked(-1, c.display == AWCurve.Display.ON)
		m.add_radio_check_item("Dim", 11)
		m.set_item_checked(-1, c.display == AWCurve.Display.DIM)
		m.add_radio_check_item("Off", 12)
		m.set_item_checked(-1, c.display == AWCurve.Display.OFF)
		m.add_separator()
		m.add_item("Unsolo" if doc.solo_curve == c else "Solo", 5)
		m.add_item("Unmute" if c.display == AWCurve.Display.OFF else "Mute", 6)
		m.add_item("Show All Curves", 7)
		m.add_separator()
		m.add_item("Edit LFO…" if c.lfo else "LFO…", 21)
		if c.lfo:
			m.add_item("Remove LFO", 22)
		m.add_item("Remove Curve", 2)
	AWTheme.popup_at(m, owner, pos)


func on_menu(id: int) -> void:
	var c := curve()
	match id:
		1: doc.make_curve(chain, effect, param)
		2: doc.remove_curve(chain, c)
		3: reset()
		4:
			if c.display != AWCurve.Display.ON:
				doc.set_curve_display(c, AWCurve.Display.ON)
			doc.set_active_curve(c)
		5: doc.toggle_solo(c)
		6: doc.toggle_mute(c)
		7: doc.show_all_curves()
		10, 11, 12: doc.set_curve_display(c, (id - 10) as AWCurve.Display)
		20: doc.open_lfo(chain, doc.make_curve(chain, effect, param))
		21: doc.open_lfo(chain, c)
		22: doc.remove_lfo(c)


## Finishes a drag that moved several parameters of one effect (a plot handle moving
## cutoff and resonance together) as a single undo step.
static func commit_many(list: Array, action_name: String) -> void:
	if list.is_empty():
		return
	var first: AWParamBinding = list[0]
	var now := {}
	for b: AWParamBinding in list:
		if b.dragging:
			b.dragging = false
			now[b.param] = b.value()
	var orig := first.effect.params.duplicate()
	for b: AWParamBinding in list:
		if now.has(b.param):
			orig[b.param] = b._orig
	first.doc.preview_set(first.effect, {"params": orig})
	var merged := orig.duplicate()
	for k: String in now:
		merged[k] = now[k]
	first.doc.set_props(first.effect, {"params": merged}, action_name)
