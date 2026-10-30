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
@export var color: Color = Color("#4f9edb")
@export var muted: bool = false
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
