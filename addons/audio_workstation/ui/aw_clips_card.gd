@tool
class_name AWClipsCard
extends PanelContainer
## First card of a shared chain: one row per clip on the chain, with that clip's own Gain, Pitch
## and Pan (each clip keeps its own; the chain's effects are shared). Click a name to select the
## clip; × takes it off the chain. Knobs work like the Clip card's (right-click: curve, LFO).

const WIDTH := 240.0
const KNOB := 36.0

var doc: AWDocument
var chain: AWChain
var rows: Array = [] # [{clip, knobs: Array[AWKnob], name: Button}]
var _style := StyleBoxFlat.new()


func setup(p_doc: AWDocument, p_chain: AWChain) -> void:
	doc = p_doc
	chain = p_chain


func _ready() -> void:
	name = "ClipsCard"
	custom_minimum_size.x = WIDTH
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style.bg_color = AWTheme.color(self, &"base_color", Color(0.2, 0.23, 0.27))
	_style.border_color = AWEffectLibrary.effect_color(AWEffectLibrary.CLIP_SOURCE)
	_style.border_width_top = 3
	_style.set_corner_radius_all(4)
	_style.set_content_margin_all(6)
	add_theme_stylebox_override("panel", _style)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	add_child(col)
	var title := Label.new()
	title.text = "Clips"
	title.add_theme_font_size_override("font_size", get_theme_default_font_size() + 1)
	title.tooltip_text = "The clips that play through this chain. Gain, Pitch and Pan belong to each clip."
	col.add_child(title)
	col.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)
	col.add_child(scroll)
	var users := doc.chain_clips(chain)
	if users.is_empty():
		var none := AWTheme.dim_label("No clips use this chain. Select clips, then right-click this tab > Use for Selected Clips.", 0.6)
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(none)
	for c in users:
		list.add_child(_row(c))
	refresh()


func _row(c: AWClip) -> Control:
	# Two lines: colour, name and × on top; the clip's Gain, Pitch, Pan below.
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var top := HBoxContainer.new()
	var sw := ColorRect.new()
	sw.color = c.color
	sw.custom_minimum_size = Vector2(4, 0)
	top.add_child(sw)
	var nm := Button.new()
	nm.flat = true
	nm.text = c.name
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.alignment = HORIZONTAL_ALIGNMENT_LEFT
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.focus_mode = Control.FOCUS_NONE
	nm.tooltip_text = "Select %s" % c.name
	nm.pressed.connect(func() -> void: doc.select_clip(c))
	top.add_child(nm)
	var off := Button.new()
	off.flat = true
	off.text = "×"
	off.focus_mode = Control.FOCUS_NONE
	off.tooltip_text = "Take %s off this chain (it plays dry)" % c.name
	off.pressed.connect(func() -> void: _detach_one(c))
	top.add_child(off)
	box.add_child(top)
	var knob_row := HBoxContainer.new()
	knob_row.alignment = BoxContainer.ALIGNMENT_CENTER
	knob_row.add_theme_constant_override("separation", 10)
	var src: AWEffect = c.chain.effects[0]
	var knobs: Array[AWKnob] = []
	for key in ["gain_db", "pitch_semitones", "pan"]:
		var b := AWParamBinding.new(doc, c.chain, src, key)
		b.spread = false
		var k := AWKnob.new()
		k.setup(b, AWEffectLibrary.effect_color(AWEffectLibrary.CLIP_SOURCE), KNOB)
		k.bipolar = key != "gain_db"
		k.name = "%s_%s" % [key, c.name.validate_node_name()]
		knobs.append(k)
		knob_row.add_child(k)
	box.add_child(knob_row)
	box.add_child(HSeparator.new())
	rows.append({"clip": c, "knobs": knobs, "name": nm, "row": box})
	return box


## Detaches just this clip, even when it is part of a larger selection.
func _detach_one(c: AWClip) -> void:
	doc.set_selection([c] as Array[AWClip])
	doc.set_clip_chain(c, null)


func refresh() -> void:
	for r: Dictionary in rows:
		var c: AWClip = r.clip
		(r.name as Button).text = c.name + ("  (muted)" if c.muted else "")
		(r.name as Button).modulate = Color(1, 1, 1, 1.0 if doc.project.is_clip_audible(c) else 0.5)
		var focused: bool = c == doc.focus_clip
		(r.name as Button).add_theme_color_override("font_color", AWTheme.accent(self) if focused else AWTheme.text(self))
		for k: AWKnob in r.knobs:
			k.refresh()
