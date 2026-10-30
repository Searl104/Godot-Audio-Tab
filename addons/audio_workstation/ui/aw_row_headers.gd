@tool
class_name AWRowHeaders
extends Control
## Strip left of the clip grid: one header per row (layer), aligned with the grid's rows.
##
##   ▌Footsteps            [M][S][🔒]
##
## Colour bar, name (double-click to rename), Mute, Solo (Ctrl+click: solo only this row) and Lock.
## Mute and Solo also decide what is exported. Right-click: Rename, Colour.

const WIDTH := 130.0
const COLLAPSED_WIDTH := 72.0
const BTN := 18.0
const PREF_COLLAPSED := "audio_workstation/grid/row_headers_collapsed"

## Narrow mode: colour bar and M / S / L only (the name shows in the tooltip).
var collapsed := false

var doc: AWDocument
var grid: AWClipGrid

var _menu: PopupMenu
var _color_menu: PopupMenu
var _menu_row := -1
var _edit: LineEdit
var _edit_row := -1


func setup(p_doc: AWDocument, p_grid: AWClipGrid) -> void:
	doc = p_doc
	grid = p_grid


func _ready() -> void:
	collapsed = bool(AWImporter.get_pref(PREF_COLLAPSED, false))
	custom_minimum_size.x = COLLAPSED_WIDTH if collapsed else WIDTH
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	_color_menu = PopupMenu.new()
	_color_menu.add_item("None", 100)
	for i in AWProject.CLIP_COLORS.size():
		var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
		img.fill(AWProject.CLIP_COLORS[i])
		_color_menu.add_icon_item(ImageTexture.create_from_image(img), "", i)
	_color_menu.id_pressed.connect(func(i: int) -> void:
		doc.set_row_prop(_menu_row, "color", Color(0, 0, 0, 0) if i == 100 else AWProject.CLIP_COLORS[i]))
	_menu.add_child(_color_menu)
	_edit = LineEdit.new()
	_edit.visible = false
	_edit.text_submitted.connect(func(_t: String) -> void: _finish_rename(true))
	_edit.focus_exited.connect(func() -> void: _finish_rename(true))
	_edit.gui_input.connect(func(e: InputEvent) -> void:
		var k := e as InputEventKey
		if k and k.pressed and k.keycode == KEY_ESCAPE:
			_finish_rename(false)
			_edit.accept_event())
	add_child(_edit)
	doc.project_changed.connect(func(_s: bool) -> void: _sync_size(); queue_redraw())
	doc.selection_changed.connect(queue_redraw)
	grid.resized.connect(_sync_size)
	grid.row_height_changed.connect(func() -> void: _sync_size(); queue_redraw())
	doc.groups_changed.connect(queue_redraw)
	_sync_size()


signal collapsed_changed


func set_collapsed(on: bool) -> void:
	collapsed = on
	AWImporter.set_pref(PREF_COLLAPSED, on)
	custom_minimum_size.x = COLLAPSED_WIDTH if collapsed else WIDTH
	collapsed_changed.emit()
	queue_redraw()


func _sync_size() -> void:
	custom_minimum_size.y = grid.custom_minimum_size.y


func row_count() -> int:
	return grid.row_count()


## Button rectangles of a row: {"mute", "solo", "lock"}.
func buttons(i: int) -> Dictionary:
	var h := grid.row_height(i)
	var y := grid.row_top(i) + (h - BTN) * 0.5
	var x := size.x - 6.0 - BTN * 3.0 - 4.0
	return {"mute": Rect2(x, y, BTN, BTN), "solo": Rect2(x + BTN + 2.0, y, BTN, BTN), "lock": Rect2(x + (BTN + 2.0) * 2.0, y, BTN, BTN)}


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var i := grid.row_at(mb.position.y)
	if mb.button_index == MOUSE_BUTTON_LEFT:
		var b := buttons(i)
		if (b.mute as Rect2).has_point(mb.position):
			doc.set_row_prop(i, "muted", not doc.project.row(i).muted if doc.project.row(i) else true)
		elif (b.solo as Rect2).has_point(mb.position):
			if mb.ctrl_pressed or mb.meta_pressed:
				doc.solo_only_row(i)
			else:
				doc.set_row_prop(i, "solo", not doc.project.row(i).solo if doc.project.row(i) else true)
		elif (b.lock as Rect2).has_point(mb.position):
			doc.set_row_prop(i, "locked", not doc.project.row_locked(i))
		elif mb.double_click and not collapsed:
			start_rename(i)
		else:
			# Click the header: select the row's clips.
			var picked: Array[AWClip] = []
			if not doc.project.row_locked(i):
				for c in doc.project.clips:
					if c.row == i:
						picked.append(c)
			doc.set_selection(picked)
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		_menu_row = i
		_menu.clear()
		_menu.add_item("Rename Row", 1)
		_menu.add_submenu_node_item("Row Colour", _color_menu)
		_menu.add_separator()
		_menu.add_item("Unmute All Rows", 2)
		_menu.add_item("Clear All Solos", 3)
		AWTheme.popup_at(_menu, self, mb.position)
		accept_event()


func _on_menu(id: int) -> void:
	match id:
		1: start_rename(_menu_row)
		2:
			for k in doc.project.rows.size():
				if doc.project.rows[k] and doc.project.rows[k].muted:
					doc.set_row_prop(k, "muted", false)
		3:
			for k in doc.project.rows.size():
				if doc.project.rows[k] and doc.project.rows[k].solo:
					doc.set_row_prop(k, "solo", false)


func start_rename(i: int) -> void:
	_edit_row = i
	_edit.text = doc.project.row_name(i)
	_edit.position = Vector2(8, grid.row_top(i) + (grid.row_height(i) - 26.0) * 0.5)
	_edit.size = Vector2(size.x - 16.0 - BTN * 3.0 - 6.0, 26)
	_edit.visible = true
	_edit.grab_focus()
	_edit.select_all()


func _finish_rename(apply: bool) -> void:
	if _edit_row < 0:
		return
	var i := _edit_row
	_edit_row = -1
	_edit.visible = false
	if apply:
		var t := _edit.text.strip_edges()
		doc.set_row_prop(i, "name", "" if t == "Row %d" % (i + 1) else t)


func _draw() -> void:
	var c_text := AWTheme.text(self)
	var acc := AWTheme.accent(self)
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size() - 2
	var bfs := fs - 2
	draw_rect(Rect2(Vector2.ZERO, size), AWTheme.bg(self).darkened(0.12))
	var solo_on := doc.project.any_solo()
	for i in row_count():
		var y := grid.row_top(i)
		var h := grid.row_height(i)
		if h < 20.0:
			# Inside a collapsed group: a thin row, no controls.
			draw_rect(Rect2(0, y, size.x, h), Color(0, 0, 0, 0.12))
			draw_line(Vector2(0, y + h - 0.5), Vector2(size.x, y + h - 0.5), Color(0, 0, 0, 0.25))
			continue
		var r := doc.project.row(i)
		if i % 2 == 1:
			draw_rect(Rect2(0, y, size.x, h), Color(1, 1, 1, 0.015))
		draw_line(Vector2(0, y + h - 0.5), Vector2(size.x, y + h - 0.5), Color(0, 0, 0, 0.25))
		var has_sel := doc.selection.any(func(c: AWClip) -> bool: return c.row == i)
		if has_sel:
			draw_rect(Rect2(0, y, size.x, h), Color(acc, 0.08))
		var col: Color = r.color if r and r.color.a > 0.0 else Color(c_text, 0.15)
		draw_rect(Rect2(0, y + 3.0, 4.0, h - 6.0), col)
		var audible := doc.project.row_audible(i)
		var name_col := Color(c_text, 0.9 if audible else 0.4)
		var named := r != null and r.name != ""
		if not named:
			name_col.a *= 0.6
		var b := buttons(i)
		var name_w := (b.mute as Rect2).position.x - 14.0
		if _edit_row != i and not collapsed:
			draw_string(font, Vector2(10, y + h * 0.5 + fs * 0.35), AWTheme.middle_truncate(font, fs, doc.project.row_name(i), name_w), HORIZONTAL_ALIGNMENT_LEFT, name_w, fs, name_col)
		_draw_toggle(b.mute, "M", r != null and r.muted, Color("#e0a33f"), font, bfs, c_text)
		_draw_toggle(b.solo, "S", r != null and r.solo, Color("#e5d84d"), font, bfs, c_text)
		_draw_toggle(b.lock, "L", r != null and r.locked, Color("#8fa3bf"), font, bfs, c_text)
		if solo_on and not collapsed and not (r != null and r.solo) and not (r != null and r.muted):
			draw_string(font, Vector2(10, y + h - 4.0), "silent", HORIZONTAL_ALIGNMENT_LEFT, name_w, bfs, Color(c_text, 0.35))
	draw_line(Vector2(size.x - 0.5, 0), Vector2(size.x - 0.5, size.y), Color(0, 0, 0, 0.4))


func _draw_toggle(rect: Rect2, label: String, on: bool, on_col: Color, font: Font, fs: int, c_text: Color) -> void:
	draw_rect(rect, on_col if on else Color(1, 1, 1, 0.06))
	draw_rect(rect, Color(0, 0, 0, 0.35) if on else Color(c_text, 0.2), false, 1.0)
	draw_string(font, Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5 + fs * 0.36), label, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs, Color(0.08, 0.08, 0.1) if on else Color(c_text, 0.7))


func _get_tooltip(at: Vector2) -> String:
	var i := grid.row_at(at.y)
	var b := buttons(i)
	if (b.mute as Rect2).has_point(at):
		return "Mute this row (also in the export)"
	if (b.solo as Rect2).has_point(at):
		return "Solo this row (also in the export). Ctrl+click: solo only this row"
	if (b.lock as Rect2).has_point(at):
		return "Lock this row: its clips can't be selected or edited"
	return "%s. Click: select its clips. Double-click: rename. Right-click: colour." % doc.project.row_name(i)
