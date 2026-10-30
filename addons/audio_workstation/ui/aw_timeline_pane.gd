@tool
class_name AWTimelinePane
extends VBoxContainer
## Left pane: "Timeline" header, seconds ruler with loop strip, the clip grid and a scrollbar.

var doc: AWDocument
var grid: AWClipGrid
var headers: AWRowHeaders

var _ruler: AWTimeRuler
var _hbar: HScrollBar


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "  Timeline"
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var fit := AWTheme.button(self, "Fit", &"DistractionFree", "Fit all clips (F with the mouse over the grid)")
	fit.text = "Fit"
	fit.pressed.connect(fit_all)
	header.add_child(fit)
	add_child(header)

	var ruler_row := HBoxContainer.new()
	ruler_row.add_theme_constant_override("separation", 0)
	var corner := Button.new()
	corner.flat = true
	corner.focus_mode = Control.FOCUS_NONE
	corner.name = "HeadersToggle"
	corner.tooltip_text = "Narrow or widen the row headers"
	ruler_row.add_child(corner)
	_ruler = AWTimeRuler.new()
	_ruler.setup(doc, doc.timeline_view, true)
	_ruler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ruler_row.add_child(_ruler)
	add_child(ruler_row)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid = AWClipGrid.new()
	grid.setup(doc)
	headers = AWRowHeaders.new()
	headers.setup(doc, grid)
	headers.tooltip_text = " "
	body.add_child(headers)
	body.add_child(grid)
	scroll.add_child(body)
	add_child(scroll)
	var sync_corner := func() -> void:
		corner.custom_minimum_size.x = AWRowHeaders.COLLAPSED_WIDTH if headers.collapsed else AWRowHeaders.WIDTH
		corner.text = "▸ Rows" if headers.collapsed else "◂ Rows"
	corner.pressed.connect(func() -> void: headers.set_collapsed(not headers.collapsed))
	headers.collapsed_changed.connect(sync_corner)
	sync_corner.call()

	_hbar = HScrollBar.new()
	_hbar.value_changed.connect(doc.timeline_view.scroll_to)
	add_child(_hbar)
	doc.timeline_view.changed.connect(_sync_bar)
	doc.project_changed.connect(func(_s: bool) -> void: _sync_bar())


func fit_all() -> void:
	doc.timeline_view.frame(0.0, doc.project.content_end_sec())


func _sync_bar() -> void:
	var v := doc.timeline_view
	_hbar.max_value = v.scroll_range()
	_hbar.page = v.view_width
	_hbar.set_value_no_signal(v.scroll_x)
