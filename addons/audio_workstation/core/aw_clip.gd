@tool
class_name AWClip
extends Resource
## A layer block on the free grid: a reference to (part of) an audio file, placed at a
## time and a row. Non-destructive: the source file is never modified.
## Each clip owns its own effect chain and automation.
##
## Two clocks:
##   clip time (audio time)  0..length_sec, the part of the audio that plays. Curves, fades
##                           and length live here, so they stay on the same moment of sound.
##   project time            where it lands on the timeline. Pitch is playback rate, so a
##                           pitched-down clip lasts longer (see AWClipWarp).

@export var name: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var source_path: String = ""
## The file's Godot UID (uid://...), so the clip still finds its sound after the file is moved or
## renamed in the editor. Empty for files outside the project.
@export var source_uid: String = ""
## Project time where the clip starts.
@export var start_sec: float = 0.0
## Clip (audio) time covered by the clip. Its length on the timeline is play_length().
@export var length_sec: float = 1.0
## Grid row. Purely for layout: rows have no settings of their own.
@export var row: int = 0
## Where in the source file playback starts (seconds). Changes when the left edge is trimmed.
@export var source_offset_sec: float = 0.0
## Fades are in clip (audio) time.
@export var fade_in_sec: float = 0.0
@export var fade_out_sec: float = 0.0
enum FadeShape { LINEAR, FAST, SLOW, S_CURVE, EQUAL_POWER }
const FADE_SHAPE_NAMES := ["Linear", "Fast", "Slow", "S-Curve", "Equal Power"]
@export var fade_in_shape: FadeShape = FadeShape.LINEAR
@export var fade_out_shape: FadeShape = FadeShape.LINEAR
@export var color: Color = Color("#4f9edb")
@export var muted: bool = false
## Plays the covered part of the source backwards (source_offset_sec + length_sec down to source_offset_sec).
@export var reversed: bool = false
## Clips sharing a non-zero group id are selected (and so moved, trimmed, muted) together.
@export var group_id: int = 0
@export var chain: AWChain


var _warp: AWClipWarp = null
var _warp_rev := -1
var _warp_sig: Array = []
var _warp_stale := true


## The cached clip-time <-> project-time mapping. It is rebuilt only when what it depends on
## (the Pitch curve's keys and LFO, or the static Pitch) actually changed.
func warp() -> AWClipWarp:
	var rev := chain.revision if chain else 0
	if _warp == null:
		_warp = AWClipWarp.build(self)
		_warp_rev = rev
		_warp_sig = AWClipWarp.signature(self)
		_warp_stale = false
	elif _warp_stale or _warp_rev != rev:
		var sig := AWClipWarp.signature(self)
		if sig != _warp_sig:
			_warp = AWClipWarp.build(self)
			_warp_sig = sig
		_warp_rev = rev
		_warp_stale = false
	return _warp


## Marks the warp for a check on next use (e.g. after any edit; a static Pitch change or an
## LFO edit doesn't move the chain's key revision).
func invalidate_warp() -> void:
	_warp_stale = true


## How long the clip lasts on the timeline.
func play_length() -> float:
	return warp().warp(length_sec)


func end_sec() -> float:
	return start_sec + play_length()


func local_to_project(s: float) -> float:
	return start_sec + warp().warp(s)


func project_to_local(p: float) -> float:
	return warp().unwarp(p - start_sec)


## Gain at fade position u (0 = the silent end, 1 = full), for a fade shape. Same as the engine.
static func fade_gain(shape: int, u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	match shape:
		FadeShape.FAST: return 1.0 - (1.0 - u) * (1.0 - u)
		FadeShape.SLOW: return u * u
		FadeShape.S_CURVE: return u * u * (3.0 - 2.0 * u)
		FadeShape.EQUAL_POWER: return sin(u * PI * 0.5)
	return u


## Fade gain at clip time `local` (both fades).
func fade_at(local: float) -> float:
	var g := 1.0
	if fade_in_sec > 0.0 and local < fade_in_sec:
		g = fade_gain(fade_in_shape, local / fade_in_sec)
	if fade_out_sec > 0.0 and local > length_sec - fade_out_sec:
		g = minf(g, fade_gain(fade_out_shape, (length_sec - local) / fade_out_sec))
	return g


## Source time (seconds in the file) heard at clip time `local`.
func source_time(local: float) -> float:
	return source_offset_sec + length_sec - local if reversed else source_offset_sec + local


func duplicate_clip() -> AWClip:
	return duplicate(true) as AWClip


static func create(p_name: String, start: float, length: float, p_row: int, p_color: Color) -> AWClip:
	var c := AWClip.new()
	c.name = p_name
	c.start_sec = start
	c.length_sec = length
	c.row = p_row
	c.color = p_color
	c.chain = AWChain.create(AWEffectLibrary.CLIP_SOURCE)
	return c
