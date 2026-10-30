@tool
class_name AWSoundBrowser
extends ConfirmationDialog
## "Import Sound" popup: browse anywhere on disk, hear a sound before adding it.
##
##   [Back][Up] [path..........................] [Search...]
##   Places      | Name                 Length   Format
##   ☆ Favorites | ▸ folder
##   Project     |   boom.wav           0.84 s   WAV 48k st 24
##   Home ...    |   ...
##   [waveform of the selection.....................................]
##   [▶ Play] [x] Play on select   info          [x] Copy into project
##
## Up/Down step through files (auto-play hears each one), Space plays/stops, Enter or a double-click
## imports. Multi-select with Ctrl/Shift. Folder, favorites and the two checkboxes are remembered.

signal import_chosen(paths: PackedStringArray, copy: bool)

const WAVE_MAX_SEC := 120.0

var dir := ""
var entries: Array[Dictionary] = [] # {"name", "path", "is_dir"} in the order shown
var preview: AudioStreamPlayer
var wave_peaks := PackedFloat32Array()

var _history: PackedStringArray = []
var _path_edit: LineEdit
var _search: LineEdit
var _places: ItemList
var _list: Tree
var _wave: Control
var _play: Button
var _autoplay: CheckBox
var _copy: CheckBox
var _info: Label
var _fav_btn: Button
var _selected_file := ""


func _init() -> void:
	title = "Import Sound"
	ok_button_text = "Import"
	min_size = Vector2i(760, 520)
	dialog_hide_on_ok = true
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var bar := HBoxContainer.new()
	var back := Button.new()
	back.text = "<"
	back.tooltip_text = "Back"
	back.pressed.connect(go_back)
	var up := Button.new()
	up.text = "Up"
	up.tooltip_text = "Parent folder"
	up.pressed.connect(func() -> void: open_dir(dir.get_base_dir() if dir.get_base_dir() != "" else dir))
	_path_edit = LineEdit.new()
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.text_submitted.connect(func(t: String) -> void: open_dir(t.strip_edges()))
	_fav_btn = Button.new()
	_fav_btn.tooltip_text = "Add this folder to Favorites (or remove it)"
	_fav_btn.pressed.connect(toggle_favorite)
	_search = LineEdit.new()
	_search.placeholder_text = "Search this folder"
	_search.custom_minimum_size.x = 170
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _fill_list())
	for c in [back, up, _path_edit, _fav_btn, _search]:
		bar.add_child(c)
	root.add_child(bar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_places = ItemList.new()
	_places.custom_minimum_size.x = 160
	_places.item_selected.connect(func(i: int) -> void:
		var p: String = _places.get_item_metadata(i)
		if p != "":
			open_dir(p))
	split.add_child(_places)
	_list = Tree.new()
	_list.columns = 3
	_list.hide_root = true
	_list.select_mode = Tree.SELECT_MULTI
	_list.column_titles_visible = true
	_list.set_column_title(0, "Name")
	_list.set_column_title(1, "Length")
	_list.set_column_title(2, "Format")
	_list.set_column_expand(0, true)
	_list.set_column_expand(1, false)
	_list.set_column_expand(2, false)
	_list.set_column_custom_minimum_width(1, 80)
	_list.set_column_custom_minimum_width(2, 160)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.multi_selected.connect(func(_item: TreeItem, _col: int, _sel: bool) -> void: _on_selection_changed.call_deferred())
	_list.item_activated.connect(_on_activated)
	split.add_child(_list)
	root.add_child(split)

	_wave = Control.new()
	_wave.custom_minimum_size.y = 64
	_wave.draw.connect(_draw_wave)
	_wave.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _selected_file != "":
			play(clampf(mb.position.x / maxf(_wave.size.x, 1.0), 0.0, 1.0)))
	root.add_child(_wave)

	var foot := HBoxContainer.new()
	_play = Button.new()
	_play.text = "Play"
	_play.tooltip_text = "Play / stop the selected sound (Space). Click the waveform to play from there."
	_play.custom_minimum_size.x = 70
	_play.pressed.connect(func() -> void:
		if preview.playing:
			stop()
		else:
			play())
	_autoplay = CheckBox.new()
	_autoplay.text = "Play on select"
	_autoplay.button_pressed = bool(AWImporter.get_pref(AWImporter.PREF_AUTOPLAY, true))
	_autoplay.toggled.connect(func(on: bool) -> void: AWImporter.set_pref(AWImporter.PREF_AUTOPLAY, on))
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.clip_text = true
	_info.modulate = Color(1, 1, 1, 0.7)
	_copy = CheckBox.new()
	_copy.text = "Copy into project"
	_copy.tooltip_text = "Copy sounds from outside the project into res://audio_workstation_imports/<sound name>/, so the sound works on other machines. Off: use them where they are (marked on the clip). Remembered."
	_copy.button_pressed = AWImporter.copy_by_default()
	_copy.toggled.connect(func(on: bool) -> void: AWImporter.set_pref(AWImporter.PREF_COPY, on))
	for c in [_play, _autoplay, _info, _copy]:
		foot.add_child(c)
	root.add_child(foot)

	preview = AudioStreamPlayer.new()
	preview.finished.connect(func() -> void:
		_play.text = "Play"
		_wave.queue_redraw())
	add_child(preview)
	confirmed.connect(_import_selection)
	canceled.connect(stop)
	visibility_changed.connect(func() -> void:
		if not visible:
			stop())


## Opens at the remembered folder (the project folder the first time).
func open() -> void:
	var start: String = AWImporter.get_pref(AWImporter.PREF_LAST_DIR, "")
	if start == "" or not DirAccess.dir_exists_absolute(start):
		start = ProjectSettings.globalize_path("res://")
	_fill_places()
	open_dir(start, false)
	popup_centered_ratio(0.6)
	_list.grab_focus.call_deferred()


func open_dir(path: String, remember_history := true) -> void:
	path = path.replace("\\", "/")
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	if path.length() > 1 and path.ends_with("/") and not path.ends_with(":/"):
		path = path.trim_suffix("/")
	if not DirAccess.dir_exists_absolute(path):
		_info.text = "Folder not found: " + path
		_path_edit.text = dir
		return
	if remember_history and dir != "" and dir != path:
		_history.append(dir)
	dir = path
	_path_edit.text = dir
	AWImporter.set_pref(AWImporter.PREF_LAST_DIR, dir)
	_sync_fav_button()
	_fill_list()


func go_back() -> void:
	if not _history.is_empty():
		var p := _history[_history.size() - 1]
		_history.remove_at(_history.size() - 1)
		open_dir(p, false)


# --- Places -----------------------------------------------------------------------------

func favorites() -> PackedStringArray:
	return PackedStringArray(AWImporter.get_pref(AWImporter.PREF_FAVORITES, PackedStringArray()))


func toggle_favorite() -> void:
	var favs := favorites()
	var i := favs.find(dir)
	if i >= 0:
		favs.remove_at(i)
	else:
		favs.append(dir)
	AWImporter.set_pref(AWImporter.PREF_FAVORITES, favs)
	_fill_places()
	_sync_fav_button()


func _sync_fav_button() -> void:
	var fav := favorites().has(dir)
	_fav_btn.text = "★" if fav else "☆"
	_fav_btn.tooltip_text = "Remove this folder from Favorites" if fav else "Add this folder to Favorites"


func _fill_places() -> void:
	_places.clear()
	var add := func(label: String, path: String, header := false) -> void:
		var i := _places.add_item(label)
		_places.set_item_metadata(i, path)
		if header:
			_places.set_item_selectable(i, false)
			_places.set_item_custom_fg_color(i, Color(1, 1, 1, 0.5))
	var favs := favorites()
	if not favs.is_empty():
		add.call("FAVORITES", "", true)
		for f in favs:
			add.call("  " + f.get_file() if f.get_file() != "" else "  " + f, f)
	add.call("PLACES", "", true)
	add.call("  Project", ProjectSettings.globalize_path("res://"))
	var home := OS.get_environment("USERPROFILE") if OS.has_feature("windows") else OS.get_environment("HOME")
	if home != "":
		add.call("  Home", home.replace("\\", "/"))
	for sd: Array in [["Desktop", OS.SYSTEM_DIR_DESKTOP], ["Documents", OS.SYSTEM_DIR_DOCUMENTS], ["Downloads", OS.SYSTEM_DIR_DOWNLOADS], ["Music", OS.SYSTEM_DIR_MUSIC]]:
		var p := OS.get_system_dir(sd[1])
		if p != "" and DirAccess.dir_exists_absolute(p):
			add.call("  " + sd[0], p.replace("\\", "/"))
	var drives := DirAccess.get_drive_count()
	if drives > 0:
		add.call("DRIVES", "", true)
		for i in drives:
			var dn := DirAccess.get_drive_name(i)
			add.call("  " + dn, dn + ("/" if not dn.ends_with("/") else ""))


# --- File list ----------------------------------------------------------------------------

func _fill_list() -> void:
	_list.clear()
	entries.clear()
	var root := _list.create_item()
	var q := _search.text.strip_edges().to_lower()
	var dirs := DirAccess.get_directories_at(dir)
	var files := DirAccess.get_files_at(dir)
	for d in dirs:
		if d.begins_with(".") or (q != "" and not d.to_lower().contains(q)):
			continue
		entries.append({"name": d, "path": dir.path_join(d), "is_dir": true})
	for f in files:
		var ext := f.get_extension().to_lower()
		if ext not in AWDocument.AUDIO_EXTENSIONS or (q != "" and not f.to_lower().contains(q)):
			continue
		entries.append({"name": f, "path": dir.path_join(f), "is_dir": false})
	for e in entries:
		var it := _list.create_item(root)
		it.set_metadata(0, e)
		if e.is_dir:
			it.set_text(0, "▸ " + e.name)
			it.set_custom_color(0, Color(1, 1, 1, 0.75))
		else:
			it.set_text(0, e.name)
			var ext: String = (e.name as String).get_extension().to_lower()
			var fmt := ext.to_upper()
			if ext == "wav":
				var wi := AWImporter.wav_info(e.path)
				if not wi.is_empty():
					it.set_text(1, _fmt_len(wi.length))
					fmt = "WAV %s %s %d" % [_fmt_rate(wi.rate), "st" if wi.channels == 2 else ("mono" if wi.channels == 1 else "%dch" % wi.channels), wi.bits]
			it.set_text(2, fmt)
	var nfiles := entries.filter(func(e: Dictionary) -> bool: return not e.is_dir).size()
	_info.text = "%d sound%s here" % [nfiles, "" if nfiles == 1 else "s"] if nfiles > 0 else "No sounds in this folder"
	_select_file("")


static func _fmt_len(s: float) -> String:
	return "%.2f s" % s if s < 60.0 else "%d:%04.1f" % [int(s / 60.0), fmod(s, 60.0)]


static func _fmt_rate(r: int) -> String:
	return "%sk" % String.num(r / 1000.0, 1).trim_suffix(".0")


func selected_paths() -> PackedStringArray:
	var out := PackedStringArray()
	var it := _list.get_next_selected(null)
	while it:
		var e: Dictionary = it.get_metadata(0)
		if not e.is_dir:
			out.append(e.path)
		it = _list.get_next_selected(it)
	return out


## Selects files by path (tests, and keeping the selection after a refresh).
func select_paths(paths: PackedStringArray) -> void:
	_list.deselect_all()
	var root := _list.get_root()
	if root == null:
		return
	for it in root.get_children():
		var e: Dictionary = it.get_metadata(0)
		if paths.has(e.path):
			it.select(0)
	_on_selection_changed()


func _on_selection_changed() -> void:
	var it := _list.get_selected()
	var e: Dictionary = it.get_metadata(0) if it else {}
	_select_file(e.path if not e.is_empty() and not e.is_dir else "")


func _on_activated() -> void:
	var it := _list.get_selected()
	if it == null:
		return
	var e: Dictionary = it.get_metadata(0)
	if e.is_dir:
		open_dir(e.path)
	else:
		_import_selection()
		hide()


func _import_selection() -> void:
	stop()
	var paths := selected_paths()
	if not paths.is_empty():
		import_chosen.emit(paths, _copy.button_pressed)


# --- Preview ------------------------------------------------------------------------------

func _select_file(path: String) -> void:
	if path == _selected_file:
		return
	_selected_file = path
	stop()
	wave_peaks = PackedFloat32Array()
	get_ok_button().disabled = path == "" and selected_paths().is_empty()
	if path == "":
		_wave.queue_redraw()
		return
	var st := AWSourceCache.load_stream(path)
	preview.stream = st
	if st == null:
		_info.text = "Can't read %s" % path.get_file()
		_wave.queue_redraw()
		return
	var length := st.get_length()
	var n := selected_paths().size()
	_info.text = "%s · %s%s" % [path.get_file(), _fmt_len(length), ("   (%d selected)" % n) if n > 1 else ""]
	if length > 0.0 and length <= WAVE_MAX_SEC:
		wave_peaks = _peaks(st, 400)
	_wave.queue_redraw()
	if _autoplay.button_pressed:
		play()


func play(from_fraction := 0.0) -> void:
	if preview.stream == null:
		return
	preview.play(from_fraction * preview.stream.get_length())
	_play.text = "Stop"


func stop() -> void:
	if preview and preview.playing:
		preview.stop()
	if _play:
		_play.text = "Play"
	if _wave:
		_wave.queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if visible and k and k.pressed and not k.echo and k.keycode == KEY_SPACE and not _search.has_focus() and not _path_edit.has_focus():
		_play.pressed.emit()
		get_viewport().set_input_as_handled()


static func _peaks(st: AudioStream, buckets: int) -> PackedFloat32Array:
	var frames := AWSourceCache.decode(st)
	var out := PackedFloat32Array()
	out.resize(buckets)
	if frames.is_empty():
		return out
	var per := float(frames.size()) / buckets
	for b in buckets:
		var a := int(b * per)
		var e := mini(int((b + 1) * per), frames.size())
		var m := 0.0
		var step := maxi(1, (e - a) / 256)
		for i in range(a, e, step):
			m = maxf(m, maxf(absf(frames[i].x), absf(frames[i].y)))
		out[b] = m
	return out


func _draw_wave() -> void:
	var s := _wave.size
	_wave.draw_rect(Rect2(Vector2.ZERO, s), Color(0, 0, 0, 0.3))
	if wave_peaks.is_empty():
		var font := _wave.get_theme_default_font()
		var msg := "Select a sound to see and hear it" if _selected_file == "" else "No waveform for long files"
		_wave.draw_string(font, Vector2(0, s.y * 0.5 + 5), msg, HORIZONTAL_ALIGNMENT_CENTER, s.x, _wave.get_theme_default_font_size(), Color(1, 1, 1, 0.4))
		return
	var col := AWTheme.accent(_wave)
	var mid := s.y * 0.5
	var w := s.x / wave_peaks.size()
	for i in wave_peaks.size():
		var h := maxf(1.0, wave_peaks[i] * (s.y * 0.5 - 3.0))
		_wave.draw_rect(Rect2(i * w, mid - h, maxf(w - 0.5, 0.5), h * 2.0), Color(col, 0.85))
	if preview.playing and preview.stream:
		var x := s.x * preview.get_playback_position() / maxf(preview.stream.get_length(), 0.001)
		_wave.draw_line(Vector2(x, 0), Vector2(x, s.y), Color(1, 1, 1, 0.9), 1.0)


func _process(_delta: float) -> void:
	if visible and preview and preview.playing:
		_wave.queue_redraw()
