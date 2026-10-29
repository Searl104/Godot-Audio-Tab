@tool
class_name AWProject
extends Resource
## The saved sound-effect document. All times are in seconds.

const FORMAT_VERSION := 2
const CLIP_COLORS := [
	Color("#4f7fd9"), Color("#d9b63f"), Color("#6fae4f"), Color("#e07a3f"),
	Color("#a77fd9"), Color("#d95f7a"), Color("#3fb8b0"),
]

@export var format_version: int = FORMAT_VERSION
@export var title: String = "Untitled Sound"
@export var length_sec: float = 4.0
@export var loop_enabled: bool = false
@export var loop_start_sec: float = 0.0
@export var loop_end_sec: float = 2.0
@export var clips: Array[AWClip] = []
@export var master_chain: AWChain

@export_group("Export")
## 16 or 32 (32 = float).
@export_enum("16-bit:16", "32-bit float:32") var export_bit_depth: int = 16
## Where the exported sound ends (seconds): the marker on the timeline. The part after the last
## clip is the tail, where effects ring out. Negative = automatic (see export_end_resolved).
@export var export_end_sec: float = -1.0
## Relative to res:// (or an absolute path).
@export var export_path: String = "assets/sfx/jump.wav"


const AUTO_TAIL_SEC := 2.5
const MAX_END_SEC := 600.0


## End of the last unmuted clip, pitch included.
func last_clip_end_sec() -> float:
	var end := 0.0
	for c in clips:
		if not c.muted:
			end = maxf(end, c.start_sec + c.play_length())
	return end


func export_end_is_auto() -> bool:
	return export_end_sec < 0.0


## The export end in use. A manual marker is used as it is. Automatic: the last clip's end, plus
## AUTO_TAIL_SEC when a chain has a card that rings on (and again for the master chain).
func export_end_resolved() -> float:
	if export_end_sec >= 0.0:
		return minf(export_end_sec, MAX_END_SEC)
	var end := 0.0
	for c in clips:
		if not c.muted:
			end = maxf(end, c.start_sec + c.play_length() + (AUTO_TAIL_SEC if AWEngine.chain_rings(c.chain) else 0.0))
	if AWEngine.chain_rings(master_chain):
		end += AUTO_TAIL_SEC
	return end


func content_end_sec() -> float:
	var end := length_sec
	for c in clips:
		end = maxf(end, c.end_sec())
	return end


func max_row() -> int:
	var r := 0
	for c in clips:
		r = maxi(r, c.row)
	return r


## Placeholder content laid out like the sketch, so the UI has something to show.
static func create_default() -> AWProject:
	var p := AWProject.new()
	p.title = "Demo Impact"
	p.master_chain = AWChain.create(AWEffectLibrary.MASTER_OUTPUT)
	var mlim := AWEffect.create("Limiter", p.master_chain.new_effect_id())
	p.master_chain.effects.append(mlim)

	p.clips.append(AWClip.create("Clip 1", 0.15, 1.2, 0, CLIP_COLORS[0]))
	p.clips.append(AWClip.create("Clip 2", 0.55, 0.85, 1, CLIP_COLORS[1]))
	p.clips.append(AWClip.create("Clip 3", 1.05, 1.1, 2, CLIP_COLORS[2]))
	var bed := AWClip.create("Clip 4", 0.0, 2.8, 4, CLIP_COLORS[3])
	p.clips.append(bed)

	# Clip 4's chain and curves mirror the sketch.
	var ch := bed.chain
	var lim := AWEffect.create("Limiter", ch.new_effect_id())
	var rev := AWEffect.create("Reverb", ch.new_effect_id())
	var cho := AWEffect.create("Chorus", ch.new_effect_id())
	ch.effects.append_array([lim, rev, cho])
	var src := ch.effects[0]
	var L := bed.length_sec
	var B := AWCurve.HandleMode.BALANCED
	# Pitch falls 5 semitones, so the bed slows down and lasts longer than its 2.8 s of audio.
	_curve(ch, src.id, "pitch_semitones", AWEffectLibrary.CURVE_COLORS[0], [
		_k(0.0, 0.0, AWCurve.HandleMode.LINEAR), _k(L, -5.0, AWCurve.HandleMode.LINEAR)])
	_curve(ch, lim.id, "ceiling_db", AWEffectLibrary.CURVE_COLORS[1], [
		_k(0.0, -2.0, AWCurve.HandleMode.LINEAR), _k(L, -2.0, AWCurve.HandleMode.LINEAR)])
	_curve(ch, rev.id, "wet", AWEffectLibrary.CURVE_COLORS[2], [
		_k(0.0, 0.62, B, Vector2(0.15, 0)), _k(0.35, 0.62, B, Vector2(0.2, 0)),
		_k(1.3, 0.04, B, Vector2(0.28, 0)), _k(L, 0.04, B, Vector2(0.2, 0))])
	_curve(ch, cho.id, "wet", AWEffectLibrary.CURVE_COLORS[3], [
		_k(0.0, 0.03, B, Vector2(0.2, 0)), _k(1.0, 0.48, B, Vector2(0.22, 0)),
		_k(1.7, 0.48, B, Vector2(0.18, 0)), _k(2.25, 0.03, B, Vector2(0.09, 0)),
		_k(2.42, 0.09, B, Vector2(0.05, 0)), _k(2.56, 0.03, B, Vector2(0.05, 0)),
		_k(L, 0.03, B, Vector2(0.08, 0))])
	return p


static func _k(t: float, v: float, mode: int, handle := Vector2(0.1, 0.0)) -> Dictionary:
	return {"t": t, "v": v, "in": -handle, "out": handle, "mode": mode}


## `keys` use real parameter values; they're converted to the curve's 0..1 scale here.
## Handle values are given in 0..1 units already.
static func _curve(ch: AWChain, effect_id: int, param: String, color: Color, keys: Array) -> void:
	var c := AWCurve.new()
	c.effect_id = effect_id
	c.param = param
	c.color = color
	c.scale = AWEffectLibrary.default_scale(ch.find_effect(effect_id).effect_type, param) as AWCurve.Scale
	ch.curves.append(c)
	for k: Dictionary in keys:
		k["v"] = ch.to_norm(c, k.v)
	ch.set_keys(c, keys)
