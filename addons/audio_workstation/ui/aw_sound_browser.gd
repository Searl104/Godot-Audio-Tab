@tool
class_name AWSoundBrowser
extends ConfirmationDialog
## "Import Sound" popup: browse anywhere on disk, hear a sound before adding it.
##
##   [<][^][⟳] [📁 path.........................] [★] [🔍 Search...]
##   FAVORITES   | Name                    Length    Format
##   PLACES      | 📁 folder
##   DRIVES      | 🔊 boom.wav             0.84 s    WAV · 48 kHz · Stereo · 24-bit
##   ┌ boom.wav                         WAV · 48 kHz · Stereo · 24-bit · 0.84 s ┐
##   │ ruler                                                                     │
##   │ waveform (click to play from there)                                       │
##   └───────────────────────────────────────────────────────────────────────────┘
##   [▶] Play on select (switch)                 Copy into project (switch) → dest
##
## Styled from the editor theme (icons, panels, accent), like the rest of the Audio tab.
## Up/Down step through files (Play on select hears each one), Space plays/stops, Enter or a
## double-click imports. Ctrl/Shift select several. Folder, favorites and switches are remembered.

signal import_chosen(paths: PackedStringArray, copy: bool)

const WAVE_MAX_SEC := 120.0

var dir := ""
var entries: Array[Dictionary] = [] # {"name", "path", "is_dir"} in the order shown
var preview: AudioStreamPlayer
var wave_peaks := PackedFloat32Array()
## Shown under the Copy switch: where copies go (the main screen sets it before opening).
var dest_hint := ""

var _history: PackedStringArray = []
var _back: Button
var _up: Button
var _reload: Button
var _path_edit: LineEdit
var _search: LineEdit
var _places: Tree
var _list: Tree
var _wave: Control
var _sel_name: Label
var _sel_meta: Label
var _play: Button
var _autoplay: CheckButton
var _copy: CheckButton
var _dest: Label
var _count: Label
var _fav_btn: Button
var _selected_file := ""
var _selected_length := 0.0
var _hover_x := -1.0
var _built := false
var _ctx: Control # for editor theme lookups (the dialog itself is a Window, not a Control)


func _init() -> void:
	title = "Import Sound"
	ok_button_text = "Import"
	min_size = Vector2i(820, 560)
	dialog_hide_on_ok = true
	preview = AudioStreamPlayer.new()
	add_child(preview)


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	_ctx = root

	# Toolbar, like the FileSystem dock: flat icon buttons, path with a folder icon, search.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	_back = _icon_button("Back", "<", "Back")
	_back.pressed.connect(go_back)
	_up = _icon_button("MoveUp", "Up", "Parent folder")
	_up.pressed.connect(func() -> void: open_dir(dir.get_base_dir() if dir.get_base_dir() != "" else dir))
	_reload = _icon_button("Reload", "⟳", "Refresh")
	_reload.pressed.connect(func() -> void: _fill_list())
	_path_edit = LineEdit.new()
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.right_icon = AWTheme.icon(_ctx, &"Folder")
	_path_edit.text_submitted.connect(func(t: String) -> void: open_dir(t.strip_edges()))
	_fav_btn = _icon_button("Favorites", "☆", "Add this folder to Favorites")
	_fav_btn.toggle_mode = true
	_fav_btn.pressed.connect(toggle_favorite)
	_search = LineEdit.new()
	_search.placeholder_text = "Search this folder"
	_search.custom_minimum_size.x = 190
	_search.clear_button_enabled = true
	_search.right_icon = AWTheme.icon(_ctx, &"Search")
	_search.text_changed.connect(func(_t: String) -> void: _fill_list())
	for c: Control in [_back, _up, _reload, _path_edit, _fav_btn, _search]:
		bar.add_child(c)
	root.add_child(bar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 0
	_places = Tree.new()
	_places.hide_root = true
	_places.custom_minimum_size.x = 180
	_places.item_selected.connect(func() -> void:
		var it := _places.get_selected()
		var p: String = it.get_metadata(0) if it else ""
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
	_list.set_column_title_alignment(0, HORIZONTAL_ALIGNMENT_LEFT)
	_list.set_column_title_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
	_list.set_column_title_alignment(2, HORIZONTAL_ALIGNMENT_LEFT)
	_list.set_column_expand(0, true)
	_list.set_column_expand(1, false)
	_list.set_column_expand(2, false)
	_list.set_column_custom_minimum_width(1, 80)
	_list.set_column_custom_minimum_width(2, 200)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.multi_selected.connect(func(_item: TreeItem, _col: int, _sel: bool) -> void: _on_selection_changed.call_deferred())
	_list.item_activated.connect(_on_activated)
	split.add_child(_list)
	root.add_child(split)

	# Preview card: name and facts, then the waveform with a time ruler.
	var card := PanelContainer.new()
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = AWTheme.color(_ctx, &"dark_color_3", Color(0.09, 0.1, 0.12))
	card_style.border_color = AWTheme.color(_ctx, &"contrast_color_1", Color(1, 1, 1, 0.08))
	card_style.set_border_width_all(1)
	card_style.set_corner_radius_all(4)
	card_style.set_content_margin_all(8)
	card.add_theme_stylebox_override("panel", card_style)
	var card_col := VBoxContainer.new()
	card_col.add_theme_constant_override("separation", 4)
	var head := HBoxContainer.new()
	_sel_name = Label.new()
	_sel_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_name.clip_text = true
	_sel_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_sel_meta = Label.new()
	_sel_meta.modulate = Color(1, 1, 1, 0.6)
	head.add_child(_sel_name)
	head.add_child(_sel_meta)
	card_col.add_child(head)
	_wave = Control.new()
	_wave.custom_minimum_size.y = 92
	_wave.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_wave.tooltip_text = "Click to play from here"
	_wave.draw.connect(_draw_wave)
	_wave.gui_input.connect(_wave_input)
	_wave.mouse_exited.connect(func() -> void:
		_hover_x = -1.0
		_wave.queue_redraw())
	card_col.add_child(_wave)
	card.add_child(card_col)
	root.add_child(card)

	# Transport and import options.
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	_play = Button.new()
	_play.tooltip_text = "Play / stop the selected sound (Space)"
	_play.custom_minimum_size = Vector2(40, 32)
	_play.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_play.pressed.connect(func() -> void:
		if preview.playing:
			stop()
		else:
			play())
	_autoplay = CheckButton.new()
	_autoplay.text = "Play on select"
	_autoplay.focus_mode = Control.FOCUS_NONE
	_autoplay.button_pressed = bool(AWImporter.get_pref(AWImporter.PREF_AUTOPLAY, true))
	_autoplay.toggled.connect(func(on: bool) -> void: AWImporter.set_pref(AWImporter.PREF_AUTOPLAY, on))
	_count = Label.new()
	_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count.modulate = Color(1, 1, 1, 0.5)
	var copy_col := VBoxContainer.new()
	copy_col.add_theme_constant_override("separation", 0)
	_copy = CheckButton.new()
	_copy.text = "Copy into project"
	_copy.focus_mode = Control.FOCUS_NONE
	_copy.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_copy.tooltip_text = "Copy sounds from outside the project into it, so the sound works on other machines and in version control. Off: use them where they are (the clip is marked). Remembered."
	_copy.button_pressed = AWImporter.copy_by_default()
	_copy.toggled.connect(func(on: bool) -> void:
		AWImporter.set_pref(AWImporter.PREF_COPY, on)
		_sync_dest())
	_dest = Label.new()
	_dest.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_dest.modulate = Color(1, 1, 1, 0.45)
	_dest.add_theme_font_size_override("font_size", get_theme_default_font_size() - 2)
	copy_col.add_child(_copy)
	copy_col.add_child(_dest)
	for c: Control in [_play, _autoplay, _count, copy_col]:
		foot.add_child(c)
	root.add_child(foot)

	preview.finished.connect(func() -> void:
		_sync_play()
		_wave.queue_redraw())
	confirmed.connect(_import_selection)
	canceled.connect(stop)
	visibility_changed.connect(func() -> void:
		if not visible:
			stop())
	_sync_play()


func _icon_button(icon_name: StringName, fallback: String, tip: String) -> Button:
	var b := Button.new()
	b.flat = true
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	var tex := AWTheme.icon(_ctx, icon_name)
	if tex:
		b.icon = tex
	else:
		b.text = fallback
	return b


## Opens at the remembered folder (the project folder the first time).
func open() -> void:
	_build()
	var start: String = AWImporter.get_pref(AWImporter.PREF_LAST_DIR, "")
	if start == "" or not DirAccess.dir_exists_absolute(start):
		start = ProjectSettings.globalize_path("res://")
	_fill_places()
	_sync_dest()
	open_dir(start, false)
	popup_centered_ratio(0.62)
	_list.grab_focus.call_deferred()


func open_dir(path: String, remember_history := true) -> void:
	_build()
	path = path.replace("\\", "/")
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	if path.length() > 1 and path.ends_with("/") and not path.ends_with(":/"):
		path = path.trim_suffix("/")
	if not DirAccess.dir_exists_absolute(path):
		_count.text = "Folder not found: " + path
		_path_edit.text = dir
		return
	if remember_history and dir != "" and dir != path:
		_history.append(dir)
	dir = path
	_path_edit.text = dir
	_back.disabled = _history.is_empty()
	AWImporter.set_pref(AWImporter.PREF_LAST_DIR, dir)
	_sync_fav_button()
	_sync_places_selection()
	_fill_list()


func go_back() -> void:
	if not _history.is_empty():
		var p := _history[_history.size() - 1]
		_history.remove_at(_history.size() - 1)
		open_dir(p, false)
		_back.disabled = _history.is_empty()


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
	_fav_btn.set_pressed_no_signal(fav)
	_fav_btn.modulate = Color(1, 0.85, 0.35) if fav else Color(1, 1, 1, 0.7)
	if _fav_btn.icon == null:
		_fav_btn.text = "★" if fav else "☆"
	_fav_btn.tooltip_text = "Remove this folder from Favorites" if fav else "Add this folder to Favorites"


func _fill_places() -> void:
	_places.clear()
	var root := _places.create_item()
	var folder_col := AWTheme.color(_ctx, &"folder_icon_color", Color(0.65, 0.8, 1.0))
	var section := func(label: String) -> void:
		var h := _places.create_item(root)
		h.set_text(0, label)
		h.set_selectable(0, false)
		h.set_custom_color(0, Color(1, 1, 1, 0.45))
		h.set_custom_font_size(0, get_theme_default_font_size() - 3)
	var add := func(label: String, path: String, icon_name: StringName) -> void:
		var it := _places.create_item(root)
		it.set_text(0, label)
		it.set_metadata(0, path)
		it.set_tooltip_text(0, path)
		var tex := AWTheme.icon(_ctx, icon_name)
		if tex:
			it.set_icon(0, tex)
			if icon_name == &"Folder":
				it.set_icon_modulate(0, folder_col)
	var favs := favorites()
	if not favs.is_empty():
		section.call("FAVORITES")
		for f in favs:
			add.call(f.get_file() if f.get_file() != "" else f, f, &"Favorites")
	section.call("PLACES")
	add.call("Project (res://)", ProjectSettings.globalize_path("res://").trim_suffix("/"), &"Godot")
	var home := OS.get_environment("USERPROFILE") if OS.has_feature("windows") else OS.get_environment("HOME")
	if home != "":
		add.call("Home", home.replace("\\", "/"), &"Folder")
	for sd: Array in [["Desktop", OS.SYSTEM_DIR_DESKTOP], ["Documents", OS.SYSTEM_DIR_DOCUMENTS], ["Downloads", OS.SYSTEM_DIR_DOWNLOADS], ["Music", OS.SYSTEM_DIR_MUSIC]]:
		var p := OS.get_system_dir(sd[1])
		if p != "" and DirAccess.dir_exists_absolute(p):
			add.call(sd[0], p.replace("\\", "/").trim_suffix("/"), &"Folder")
	var drives := DirAccess.get_drive_count()
	if drives > 0:
		section.call("DRIVES")
		for i in drives:
			var dn := DirAccess.get_drive_name(i)
			add.call(dn, dn + ("/" if not dn.ends_with("/") else ""), &"Filesystem")
	_sync_places_selection()


func _sync_places_selection() -> void:
	var root := _places.get_root()
	if root == null:
		return
	for it in root.get_children():
		var p: String = it.get_metadata(0) if it.get_metadata(0) != null else ""
		if p != "" and p == dir:
			it.select(0)
			return
	_places.deselect_all()


# --- File list ----------------------------------------------------------------------------

func _fill_list() -> void:
	_list.clear()
	entries.clear()
	var root := _list.create_item()
	var q := _search.text.strip_edges().to_lower()
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with(".") or (q != "" and not d.to_lower().contains(q)):
			continue
		entries.append({"name": d, "path": dir.path_join(d), "is_dir": true})
	for f in DirAccess.get_files_at(dir):
		var ext := f.get_extension().to_lower()
		if ext not in AWDocument.AUDIO_EXTENSIONS or (q != "" and not f.to_lower().contains(q)):
			continue
		entries.append({"name": f, "path": dir.path_join(f), "is_dir": false})
	var folder_tex := AWTheme.icon(_ctx, &"Folder")
	var folder_col := AWTheme.color(_ctx, &"folder_icon_color", Color(0.65, 0.8, 1.0))
	for e in entries:
		var it := _list.create_item(root)
		it.set_metadata(0, e)
		it.set_text(0, e.name)
		it.set_tooltip_text(0, e.path)
		it.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		if e.is_dir:
			if folder_tex:
				it.set_icon(0, folder_tex)
				it.set_icon_modulate(0, folder_col)
			continue
		var ext: String = (e.name as String).get_extension().to_lower()
		var tex := AWTheme.icon(_ctx, {"wav": &"AudioStreamWAV", "ogg": &"AudioStreamOggVorbis", "mp3": &"AudioStreamMP3"}.get(ext, &"AudioStreamPlayer"))
		if tex:
			it.set_icon(0, tex)
		var fmt := ext.to_upper()
		if ext == "wav":
			var wi := AWImporter.wav_info(e.path)
			if not wi.is_empty():
				it.set_text(1, _fmt_len(wi.length))
				fmt = _fmt_wav(wi).trim_prefix("WAV · ") # the icon already says WAV
		it.set_text(2, fmt)
		it.set_custom_color(1, Color(1, 1, 1, 0.75))
		it.set_custom_color(2, Color(1, 1, 1, 0.55))
	var nfiles := entries.filter(func(e: Dictionary) -> bool: return not e.is_dir).size()
	_count.text = ("%d sound%s" % [nfiles, "" if nfiles == 1 else "s"]) if nfiles > 0 else "No sounds in this folder"
	_select_file("")


static func _fmt_len(s: float) -> String:
	return "%.2f s" % s if s < 60.0 else "%d:%04.1f" % [int(s / 60.0), fmod(s, 60.0)]


static func _fmt_wav(wi: Dictionary) -> String:
	var ch: int = wi.channels
	var chs := "Stereo" if ch == 2 else ("Mono" if ch == 1 else "%d ch" % ch)
	return "WAV · %s kHz · %s · %d-bit" % [String.num(wi.rate / 1000.0, 1).trim_suffix(".0"), chs, wi.bits]


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
	_sync_count()


func _sync_count() -> void:
	var n := selected_paths().size()
	get_ok_button().disabled = n == 0
	get_ok_button().text = "Import" if n <= 1 else "Import %d" % n
	if n > 1:
		_count.text = "%d selected" % n


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


func _sync_dest() -> void:
	if _dest:
		_dest.text = ("→ " + dest_hint) if _copy.button_pressed and dest_hint != "" else "Sounds from outside the project are used where they are"


# --- Preview ------------------------------------------------------------------------------

func _select_file(path: String) -> void:
	if path == _selected_file:
		return
	_selected_file = path
	stop()
	wave_peaks = PackedFloat32Array()
	_selected_length = 0.0
	get_ok_button().disabled = selected_paths().is_empty()
	if path == "":
		_sel_name.text = "No sound selected"
		_sel_meta.text = ""
		_wave.queue_redraw()
		return
	_sel_name.text = path.get_file()
	var st := AWSourceCache.load_stream(path)
	preview.stream = st
	if st == null:
		_sel_meta.text = "Can't read this file"
		_wave.queue_redraw()
		return
	_selected_length = st.get_length()
	var wi := AWImporter.wav_info(path) if path.get_extension().to_lower() == "wav" else {}
	_sel_meta.text = (_fmt_wav(wi) + " · " if not wi.is_empty() else path.get_extension().to_upper() + " · ") + _fmt_len(_selected_length)
	if _selected_length > 0.0 and _selected_length <= WAVE_MAX_SEC:
		wave_peaks = _peaks(st, 600)
	_wave.queue_redraw()
	if _autoplay.button_pressed:
		play()


func play(from_fraction := 0.0) -> void:
	if preview.stream == null:
		return
	preview.play(from_fraction * preview.stream.get_length())
	_sync_play()


func stop() -> void:
	if preview and preview.playing:
		preview.stop()
	_sync_play()
	if _wave:
		_wave.queue_redraw()


func _sync_play() -> void:
	if _play == null:
		return
	var tex := AWTheme.icon(_ctx, &"Stop" if preview.playing else &"Play")
	if tex:
		_play.icon = tex
		_play.text = ""
	else:
		_play.text = "Stop" if preview.playing else "Play"


func _wave_input(e: InputEvent) -> void:
	var mm := e as InputEventMouseMotion
	if mm:
		_hover_x = mm.position.x
		_wave.queue_redraw()
	var mb := e as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _selected_file != "":
		play(clampf((mb.position.x - 1.0) / maxf(_wave.size.x - 2.0, 1.0), 0.0, 1.0))


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


## Mirrored waveform like the clips on the grid: played part in the accent colour, the rest dimmer,
## a time ruler along the top, a hover line and the playhead.
func _draw_wave() -> void:
	var s := _wave.size
	var font := _wave.get_theme_default_font()
	var fs := _wave.get_theme_default_font_size() - 3
	var c_text := AWTheme.text(_wave)
	var acc := AWTheme.accent(_wave)
	var ruler_h := float(fs + 6)
	_wave.draw_rect(Rect2(Vector2.ZERO, s), AWTheme.bg(_wave))
	if wave_peaks.is_empty():
		var msg := "Select a sound to see and hear it" if _selected_file == "" else ("No waveform for sounds over %d s" % int(WAVE_MAX_SEC) if _selected_length > WAVE_MAX_SEC else "")
		_wave.draw_string(font, Vector2(0, s.y * 0.5 + 5), msg, HORIZONTAL_ALIGNMENT_CENTER, s.x, fs + 3, Color(c_text, 0.4))
		return
	# Ruler
	var step := 0.01
	var min_px := 64.0 # room for a label
	for cand: float in [0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]:
		step = cand
		if s.x * cand / maxf(_selected_length, 1e-6) >= min_px:
			break
	var t := 0.0
	while t <= _selected_length + 1e-6:
		var x := s.x * t / maxf(_selected_length, 1e-6)
		_wave.draw_line(Vector2(x, ruler_h - 4), Vector2(x, s.y), Color(c_text, 0.06))
		_wave.draw_line(Vector2(x, ruler_h - 4), Vector2(x, ruler_h), Color(c_text, 0.4))
		if x > s.x - 30.0:
			break
		var label := ("%ds" % int(round(t))) if step >= 1.0 else (String.num(t, 2 if step < 0.1 else 1) + "s")
		_wave.draw_string(font, Vector2(x + 3, fs + 1), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(c_text, 0.5))
		t += step
	_wave.draw_line(Vector2(0, ruler_h), Vector2(s.x, ruler_h), Color(c_text, 0.12))
	# Waveform
	var top := ruler_h + 4.0
	var mid := (top + s.y - 4.0) * 0.5
	var amp := (s.y - 4.0 - top) * 0.5
	var played_x := -1.0
	if preview.playing and preview.stream:
		played_x = s.x * preview.get_playback_position() / maxf(_selected_length, 0.001)
	var n := wave_peaks.size()
	var upper := PackedVector2Array()
	for i in n:
		upper.append(Vector2(s.x * float(i) / (n - 1), mid - maxf(wave_peaks[i] * amp, 0.5)))
	var poly := upper.duplicate()
	for i in range(n - 1, -1, -1):
		poly.append(Vector2(upper[i].x, mid + (mid - upper[i].y)))
	_wave.draw_colored_polygon(poly, Color(acc, 0.55))
	if played_x > 0.0:
		var played := PackedVector2Array()
		var k := clampi(int(float(n - 1) * played_x / s.x) + 1, 1, n)
		for i in k:
			played.append(upper[i])
		for i in range(k - 1, -1, -1):
			played.append(Vector2(upper[i].x, mid + (mid - upper[i].y)))
		if played.size() >= 3:
			_wave.draw_colored_polygon(played, acc.lightened(0.15))
	_wave.draw_line(Vector2(0, mid), Vector2(s.x, mid), Color(acc, 0.35))
	if _hover_x >= 0.0:
		_wave.draw_line(Vector2(_hover_x, ruler_h), Vector2(_hover_x, s.y), Color(c_text, 0.3))
	if played_x >= 0.0:
		_wave.draw_line(Vector2(played_x, 0), Vector2(played_x, s.y), c_text, 1.5)
		_wave.draw_colored_polygon(PackedVector2Array([Vector2(played_x - 5, 0), Vector2(played_x + 5, 0), Vector2(played_x, 6)]), c_text)


func _process(_delta: float) -> void:
	if visible and preview and preview.playing:
		_wave.queue_redraw()
