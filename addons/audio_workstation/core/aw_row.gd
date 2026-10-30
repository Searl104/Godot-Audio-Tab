@tool
class_name AWRow
extends Resource
## Settings of one grid row (layer). Rows without settings have no AWRow (defaults apply).

@export var name: String = ""
## Muted rows are silent in playback and left out of the export.
@export var muted: bool = false
## When any row is soloed, only soloed rows play and export.
@export var solo: bool = false
## Clips on a locked row can't be selected or edited on the grid.
@export var locked: bool = false
## Alpha 0 = no colour.
@export var color: Color = Color(0, 0, 0, 0)


func is_default() -> bool:
	return name == "" and not muted and not solo and not locked and color.a == 0.0
