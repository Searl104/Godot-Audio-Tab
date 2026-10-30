@tool
class_name AWMarker
extends Resource
## A named point on the timeline (project time). Snap target, navigation stop, and a cue point in
## exported WAV files.

@export var time_sec: float = 0.0
@export var name: String = ""


static func create(t: float, p_name: String) -> AWMarker:
	var m := AWMarker.new()
	m.time_sec = t
	m.name = p_name
	return m
