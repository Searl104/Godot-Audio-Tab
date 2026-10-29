@tool
class_name AWExportPanel
extends MarginContainer
## The "Export" tab of the side panel: format, bit depth, sample rate (read-only), tail,
## output file name (red when it would overwrite a file) and the Export button.

signal browse_requested

const RED := Color("#e5484d")
const RED_TEXT := Color("#ff8a8d")

var doc: AWDocument

var _depth_16: Button
var _depth_32: Button
var _tail: HSlider
var _tail_label: Label
var _path: LineEdit
var _warn: Label
var _info: Label
var _updating := false


func setup(p_doc: AWDocument) -> void:
	doc = p_doc


func _ready() -> void:
	name = "Export"
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 8)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var fmt := OptionButton.new()
	fmt.add_item("WAV")
	fmt.focus_mode = Control.FOCUS_NONE
	box.add_child(_row("Format", fmt))

	var group := ButtonGroup.new()
	var depth := HBoxContainer.new()
	depth.add_theme_constant_override("separation", 0)
	_depth_16 = _toggle("16-bit", group)
	_depth_32 = _toggle("32-bit float", group)
	depth.add_child(_depth_16)
	depth.add_child(_depth_32)
	_depth_16.pressed.connect(func() -> void: _on_depth(16))
	_depth_32.pressed.connect(func() -> void: _on_depth(32))
	box.add_child(_row("Bit depth", depth))

	var rate := AWTheme.dim_label("%d Hz, project mix rate" % int(AudioServer.get_mix_rate()), 0.7)
	box.add_child(_row("Sample rate", rate))

	var tail_box := HBoxContainer.new()
	_tail = HSlider.new()
	_tail.min_value = 0.0
	_tail.max_value = 5.0
	_tail.step = 0.1
	_tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tail.value_changed.connect(func(v: float) -> void:
		if not _updating:
			doc.set_export_tail(v))
	_tail_label = Label.new()
	_tail_label.custom_minimum_size.x = 44
	_tail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tail_box.add_child(_tail)
	tail_box.add_child(_tail_label)
	box.add_child(_row("Tail", tail_box))
	var hint := AWTheme.dim_label("Silence added after the last clip so delays and reverbs can ring out.", 0.6)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	var file_box := HBoxContainer.new()
	_path = LineEdit.new()
	_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path.placeholder_text = "assets/sfx/sound.wav"
	_path.text_changed.connect(func(t: String) -> void:
		if not _updating:
			doc.set_export_path(t))
	var browse := Button.new()
	browse.icon = AWTheme.icon(self, &"Folder")
	if browse.icon == null:
		browse.text = "..."
	browse.tooltip_text = "Browse for a folder"
	browse.focus_mode = Control.FOCUS_NONE
	browse.pressed.connect(func() -> void: browse_requested.emit())
	file_box.add_child(_path)
	file_box.add_child(browse)
	box.add_child(_row("File name", file_box))
	_warn = Label.new()
	_warn.text = "File exists. Exporting will overwrite it."
	_warn.add_theme_color_override("font_color", RED_TEXT)
	_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_warn)

	box.add_child(HSeparator.new())
	var foot := HBoxContainer.new()
	_info = AWTheme.dim_label("", 0.7)
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_info)
	var export := Button.new()
	export.text = "Export..."
	export.icon = AWTheme.icon(self, &"Save")
	export.focus_mode = Control.FOCUS_NONE
	export.pressed.connect(doc.export_now)
	foot.add_child(export)
	box.add_child(foot)

	doc.export_settings_changed.connect(_sync)
	doc.project_changed.connect(func(_s: bool) -> void: _sync())
	_sync()


func _row(label_text: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.modulate = Color(1, 1, 1, 0.7)
	l.custom_minimum_size.x = 76
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _toggle(text: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


func _on_depth(bits: int) -> void:
	if not _updating:
		doc.set_export_bit_depth(bits)


func _sync() -> void:
	_updating = true
	var p := doc.project
	_depth_16.button_pressed = p.export_bit_depth == 16
	_depth_32.button_pressed = p.export_bit_depth == 32
	_tail.value = p.export_tail_sec
	_tail_label.text = "%.1f s" % p.export_tail_sec
	if _path.text != p.export_path:
		_path.text = p.export_path
	var over := doc.export_will_overwrite()
	_warn.visible = over
	_path.tooltip_text = doc.export_target()
	if over:
		var s := StyleBoxFlat.new()
		s.bg_color = Color("#3a1d22")
		s.border_color = RED
		s.set_border_width_all(1)
		s.set_corner_radius_all(3)
		s.content_margin_left = 6
		s.content_margin_right = 6
		_path.add_theme_stylebox_override("normal", s)
		_path.add_theme_color_override("font_color", Color("#ffb3b6"))
	else:
		_path.remove_theme_stylebox_override("normal")
		_path.remove_theme_color_override("font_color")
	_info.text = "Length %.1f s\nAbout %s" % [doc.export_length_sec(), _size_text(doc.export_size_bytes())]
	_updating = false


static func _size_text(bytes: int) -> String:
	return "%.1f MB" % (bytes / 1048576.0) if bytes >= 1048576 else "%d KB" % maxi(1, int(round(bytes / 1024.0)))
