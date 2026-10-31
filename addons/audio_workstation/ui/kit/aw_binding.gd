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
var dragging := false
## Property mode (e.g. an LFO field): the object and property edited instead of an effect
## parameter. Such a binding has no curve of its own.
var target: Object
var prop := ""
var default := 0.0
## Property mode only: show values formatted like this effect parameter (Hz, dB ...).
var like_effect := ""
var like_param := ""
## Extra help shown in the control's tooltip.
var tooltip := ""
## False: edits only this effect even with several clips selected (the Clips card rows).
var spread := true
## Property mode: shown (and typed) as value * unit_factor, e.g. 1000 to show Hz/s as mHz/s.
var unit_factor := 1.0
## > 1 makes small values fine and large ones coarse. Bipolar ranges (lo < 0): the middle is
## fine (value = hi * sign(x) * |x|^power for a knob position x in -1..1). Ranges from 0: the
## start is fine (value = hi * n^power for a knob position n in 0..1).
var power := 1.0
var _orig := 0.0


func _init(p_doc: AWDocument, p_chain: AWChain, p_effect: AWEffect, p_param: String, p_scale := -1) -> void:
	doc = p_doc
	chain = p_chain
	effect = p_effect
	param = p_param
	if p_effect == null:
		return
	var spec := AWEffectLibrary.param_spec(effect.effect_type, param)
	lo = spec[0]
	hi = spec[1]
	step = spec[3]
	unit = spec[4]
	label = spec[5]
	scale = p_scale if p_scale >= 0 else AWEffectLibrary.default_scale(effect.effect_type, param)


## A binding to a plain property of a model object (undoable through the document).
static func for_property(p_doc: AWDocument, p_target: Object, p_prop: String, p_label: String, p_lo: float, p_hi: float,
		p_step: float, p_default: float, p_unit := "", p_scale := AWCurve.Scale.LINEAR) -> AWParamBinding:
	var b := AWParamBinding.new(p_doc, null, null, "")
	b.target = p_target
	b.prop = p_prop
	b.label = p_label
	b.lo = p_lo
	b.hi = p_hi
	b.step = p_step
	b.default = p_default
	b.unit = p_unit
	b.scale = p_scale
	return b


func is_property() -> bool:
	return prop != ""


func default_value() -> float:
	if is_property():
		return default
	return AWEffectLibrary.param_spec(effect.effect_type, param)[2]


func curve() -> AWCurve:
	return null if is_property() else chain.get_curve(effect.id, param)


func has_curve() -> bool:
	return curve() != null


func value() -> float:
	return target.get(prop) if is_property() else effect.get_param(param)


func live_value() -> float:
	var c := curve()
	if c == null:
		return value()
	var local := clampf(doc.chain_local_time(chain, doc.playhead_sec), 0.0, doc.curve_domain_len())
	return chain.sample(c, local)


func to_norm(v: float) -> float:
	if power > 1.0 and hi > 0.0 and lo >= 0.0:
		return pow(clampf(v / hi, 0.0, 1.0), 1.0 / power)
	if power > 1.0 and hi > 0.0:
		var x := clampf(v / hi, -1.0, 1.0)
		return 0.5 + 0.5 * signf(x) * pow(absf(x), 1.0 / power)
	return AWCurveMath.to_norm(scale, v, lo, hi)


func from_norm(n: float) -> float:
	if power > 1.0 and hi > 0.0 and lo >= 0.0:
		return snappedf(hi * pow(clampf(n, 0.0, 1.0), power), step)
	if power > 1.0 and hi > 0.0:
		var x := clampf(n, 0.0, 1.0) * 2.0 - 1.0
		return snappedf(hi * signf(x) * pow(absf(x), power), step)
	return snappedf(AWCurveMath.from_norm(scale, n, lo, hi), step)


func _decimals() -> int:
	var st := step * unit_factor
	return 0 if st >= 1.0 else (1 if st >= 0.1 else (2 if st >= 0.01 else 3))


func text(v := NAN) -> String:
	var x := live_value() if is_nan(v) else v
	if is_property():
		if like_effect != "":
			return AWEffectLibrary.format_value(like_effect, like_param, x)
		return String.num(x * unit_factor, _decimals()) + (" " + unit if unit != "" else "")
	return AWEffectLibrary.format_value(effect.effect_type, param, x)


## The value as typed into an entry field (no unit).
func edit_text() -> String:
	return String.num(value() * unit_factor, _decimals())


## Parses what the user typed ("2000", "2k", "-6 dB", "0.25"). NAN when it isn't a number.
func parse_text(t: String) -> float:
	var re := RegEx.create_from_string("^\\s*([+-]?(?:\\d+\\.?\\d*|\\.\\d+))\\s*(k?)")
	var m := re.search(t.to_lower())
	if m == null:
		return NAN
	var v := m.get_string(1).to_float()
	if m.get_string(2) == "k":
		v *= 1000.0
	return v / unit_factor


func begin() -> void:
	dragging = true
	_orig = value()


func preview(v: float) -> void:
	v = clampf(v, lo, hi)
	if is_property():
		doc.preview_set(target, {prop: v})
	else:
		doc.preview_param(effect, param, v, spread)


## Ends a drag: puts the original back and records the change as one undo step.
func commit() -> void:
	if not dragging:
		return
	dragging = false
	var now := value()
	if is_property():
		doc.preview_set(target, {prop: _orig})
		doc.set_props(target, {prop: now}, "Edit " + label)
	else:
		doc.preview_param(effect, param, _orig, spread)
		doc.set_param(effect, param, now, spread)


func set_value(v: float) -> void:
	v = clampf(v, lo, hi)
	if is_property():
		doc.set_props(target, {prop: v}, "Edit " + label)
	else:
		doc.set_param(effect, param, v, spread)


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
	if is_property():
		m.add_item("Reset to Default", 3)
	elif c == null:
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
