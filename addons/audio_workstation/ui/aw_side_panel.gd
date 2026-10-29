@tool
class_name AWSidePanel
extends PanelContainer
## Right-hand tabbed panel for the plugin's own controls (like Godot's Inspector, but ours).
## Tabs are added with add_tab(); each tab is a Control whose `name` is the tab title.

var tabs: TabContainer


func _init() -> void:
	custom_minimum_size.x = 290
	tabs = TabContainer.new()
	tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	add_child(tabs)


func add_tab(page: Control) -> void:
	tabs.add_child(page)
