@tool
class_name AWExportPanel
extends MarginContainer
## The Export dock: format, bit depth, sample rate (read-only), the End time (the timeline marker),
## output file name (red when it would overwrite a file) and the Export button.

signal browse_requested

const RED := Color("#e5484d")
const RED_TEXT := Color("#ff8a8d")

var doc: AWDocument

var _depth_16: Button
var _depth_32: Button
var _end: SpinBox
var _auto: Button
var _path: LineEdit
var _warn: Label
var solo_note: Label
var _format: OptionButton
var _depth_row: Control
var _quality_row: Control
var _quality: SpinBox
var _export_btn: Button
var _progress: ProgressBar
var _result: Label
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

	_format = OptionButton.new()
	for f: String in AWProject.FORMATS:
		_format.add_item(AWProject.FORMAT_NAMES[f])
	_format.focus_mode = Control.FOCUS_NONE
	_format.tooltip_text = "WAV is lossless. Ogg Vorbis is lossy and much smaller. (For a compressed WAV, use Godot's QOA option when importing it.)"
	_format.item_selected.connect(func(i: int) -> void:
		if not _updating:
			doc.set_export_format(AWProject.FORMATS[i]))
	box.add_child(_row("Format", _format))

	var group := ButtonGroup.new()
	var depth := HBoxContainer.new()
	depth.add_theme_constant_override("separation", 0)
	_depth_16 = _toggle("16-bit", group)
	_depth_32 = _toggle("32-bit float", group)
	depth.add_child(_depth_16)
	depth.add_child(_depth_32)
	_depth_16.pressed.connect(func() -> void: _on_depth(16))
	_depth_32.pressed.connect(func() -> void: _on_depth(32))
	_depth_row = _row("Bit depth", depth)
	box.add_child(_depth_row)
	_quality = SpinBox.new()
	_quality.min_value = 0.0
	_quality.max_value = 10.0
	_quality.step = 0.1
	_quality.tooltip_text = "Ogg Vorbis quality, 0 to 10 (5 is about 160 kbit/s, 8 about 256)."
	_quality.value_changed.connect(func(v: float) -> void:
		if not _updating:
			doc.set_export_ogg_quality(v))
	_quality_row = _row("Quality", _quality)
	box.add_child(_quality_row)

	var rate := AWTheme.dim_label("%d Hz, project mix rate" % int(AudioServer.get_mix_rate()), 0.7)
	box.add_child(_row("Sample rate", rate))

	var end_box := HBoxContainer.new()
	_end = SpinBox.new()
	_end.min_value = 0.0
	_end.max_value = AWProject.MAX_END_SEC
	_end.step = 0.01
	_end.suffix = "s"
	_end.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_end.tooltip_text = "Where the exported sound ends. Same as the orange marker on the timeline."
	_end.value_changed.connect(func(v: float) -> void:
		if not _updating:
			doc.set_export_end(v))
	_auto = Button.new()
	_auto.text = "Auto"
	_auto.toggle_mode = true
	_auto.focus_mode = Control.FOCUS_NONE
	_auto.tooltip_text = "Follow the clips: the last clip's end, plus a tail when an effect rings on."
	_auto.toggled.connect(func(on: bool) -> void:
		if not _updating:
			doc.set_export_end(-1.0 if on else doc.export_end_sec()))
	end_box.add_child(_end)
	end_box.add_child(_auto)
	box.add_child(_row("End", end_box))
	var hint := AWTheme.dim_label("Drag the orange marker on the timeline, or type a time. Everything after the last clip is the tail, where delays and reverbs ring out.", 0.6)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 200 # wrapping labels need a width or they report a huge height
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
	_warn.custom_minimum_size.x = 200
	box.add_child(_warn)
	solo_note = Label.new()
	solo_note.name = "SoloNote"
	solo_note.text = "Solo is on: only soloed rows are exported (muted rows never are)."
	solo_note.add_theme_color_override("font_color", Color("#e5d84d"))
	solo_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	solo_note.custom_minimum_size.x = 200
	box.add_child(solo_note)

	box.add_child(HSeparator.new())
	var foot := HBoxContainer.new()
	_info = AWTheme.dim_label("", 0.7)
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_info)
	_export_btn = Button.new()
	_export_btn.text = "Export"
	_export_btn.icon = AWTheme.icon(self, &"Save")
	_export_btn.focus_mode = Control.FOCUS_NONE
	_export_btn.pressed.connect(func() -> void:
		if doc.exporting:
			doc.cancel_export()
		else:
			doc.export_now())
	foot.add_child(_export_btn)
	box.add_child(foot)
	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.show_percentage = true
	_progress.visible = false
	box.add_child(_progress)
	_result = Label.new()
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result.custom_minimum_size.x = 200
	_result.visible = false
	box.add_child(_result)
	doc.export_progress.connect(func(f: float) -> void: _progress.value = f)
	doc.export_finished.connect(func(r: Dictionary) -> void:
		_result.text = AWExporter.summary(r)
		_result.add_theme_color_override("font_color", RED_TEXT if (not r.ok and not r.cancelled) or int(r.get("clipped", 0)) > 0 else AWTheme.text(self))
		_result.visible = true
		_sync())

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
	_format.select(maxi(0, AWProject.FORMATS.find(p.export_format)))
	_depth_row.visible = p.export_format == "wav"
	_quality_row.visible = p.export_format == "ogg"
	_quality.value = p.export_ogg_quality
	_path.placeholder_text = "assets/sfx/sound." + p.export_format
	_depth_16.button_pressed = p.export_bit_depth == 16
	_depth_32.button_pressed = p.export_bit_depth == 32
	_end.value = doc.export_end_sec()
	_auto.button_pressed = p.export_end_is_auto()
	if _path.text != p.export_path:
		_path.text = p.export_path
	var over := doc.export_will_overwrite()
	_warn.visible = over
	solo_note.visible = p.any_solo()
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
	var tail := maxf(0.0, doc.export_end_sec() - p.last_clip_end_sec())
	_info.text = "Length %.2f s, tail %.2f s\nAbout %s" % [doc.export_end_sec(), tail, _size_text(doc.export_size_bytes())]
	_export_btn.text = "Cancel" if doc.exporting else "Export"
	_progress.visible = doc.exporting
	if doc.exporting:
		_result.visible = false
	_updating = false


static func _size_text(bytes: int) -> String:
	return "%.1f MB" % (bytes / 1048576.0) if bytes >= 1048576 else "%d KB" % maxi(1, int(round(bytes / 1024.0)))
