@tool
class_name AWGroup
extends Resource
## A group: a frame on the grid. Every clip that starts inside [start_sec, end_sec) on rows
## row .. row + row_count - 1 belongs to it (membership follows position). Frames never overlap.
## A group may carry an effect chain: its clips are mixed together and the chain runs once on
## that mix (a bus), with curves on the group's own clock (0 = the group's start).

@export var name: String = "Group"
@export var start_sec: float = 0.0
@export var end_sec: float = 1.0
@export var row: int = 0
@export var row_count: int = 1
@export var color: Color = Color("#8f9bb3")
@export var muted: bool = false
@export var solo: bool = false
## Folded to its strip: its rows are drawn thin (the clips still play).
@export var collapsed: bool = false
@export var chain: AWChain = null


func last_row() -> int:
	return row + row_count - 1


func has_row(r: int) -> bool:
	return r >= row and r <= last_row()


## True when a clip starting at `t` on row `r` belongs to the group.
func contains(t: float, r: int) -> bool:
	return has_row(r) and t >= start_sec - 1e-6 and t < end_sec - 1e-6


func span() -> float:
	return end_sec - start_sec


## True when this frame and [s, e) x rows [r0, r1] overlap.
func overlaps(s: float, e: float, r0: int, r1: int) -> bool:
	return s < end_sec - 1e-6 and e > start_sec + 1e-6 and r0 <= last_row() and r1 >= row
