@tool
class_name AWCurve
extends Resource
## Metadata for one automated parameter. The keys themselves live in the chain's
## Animation resource as a Bezier track (same data the AnimationPlayer Bezier editor
## edits), found by track_path().

## Visual mode, cycled by clicking the curve's dot.
enum Display { ON, DIM, OFF }
## Mirrors Godot's Bezier editor handle modes (not exposed to scripts, so stored here).
enum HandleMode { FREE, LINEAR, BALANCED, MIRRORED }
## How the parameter's range maps onto the graph's 0..1 height.
## LINEAR: even steps. LOG: frequencies (equal space per octave). FADER: dB with a mixing-fader
## taper (more room near 0 dB). Keys are stored in this 0..1 space, so the shape drawn
## between keys is the change you hear.
enum Scale { LINEAR, LOG, FADER }

@export var effect_id: int = 0
@export var param: String = ""
@export var color: Color = Color.WHITE
@export var display: Display = Display.ON
## Fixed when the curve is made. Changing it later must convert the keys (see AWChain.set_curve_scale).
@export var scale: Scale = Scale.LINEAR
## One entry per key, parallel to the Animation track's keys (sorted by time).
@export var key_modes: PackedInt32Array = []
## Optional oscillator on top of the drawn curve (null = none).
@export var lfo: AWLfo


func track_path() -> NodePath:
	return NodePath("fx%d:%s" % [effect_id, param.replace("/", "_")])
