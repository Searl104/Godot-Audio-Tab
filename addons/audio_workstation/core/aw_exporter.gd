@tool
class_name AWExporter
extends RefCounted
## Bakes the whole sound (every clip, both chains, up to the end marker) to a WAV or Ogg Vorbis file.
##
## It renders on its own AWEngine (own plan and effect state), so playback and editing carry on, and
## it uses the same native render code as the preview: what you hear is what is written. The render
## runs in one-second chunks with a frame between them, so the editor stays responsive and the
## export can be cancelled; the file is written to "<name>.part" and renamed when it is complete.
##
## run() is a coroutine; await it. Its result: {ok, error, path, frames, seconds, bytes, peak_db,
## clipped, cancelled}. peak_db is -INF for silence; clipped counts samples beyond full scale
## (16-bit files clip them, 32-bit float files keep them).

signal progress(fraction: float)

const CHUNK_SEC := 1.0

var cancelled := false


func cancel() -> void:
	cancelled = true


## `format` is "wav" (with `bits` 16 or 32) or "ogg" (Ogg Vorbis, lossy; `quality` 0 to 10).
func run(project: AWProject, path: String, bits: int, format := "wav", quality := 5.0) -> Dictionary:
	var res := {"ok": false, "error": "", "path": path, "frames": 0, "seconds": 0.0, "bytes": 0,
		"peak_db": -INF, "clipped": 0, "cancelled": false}
	if format == "wav" and bits != 16 and bits != 32:
		res.error = "Unsupported bit depth: %d." % bits
		return res
	if not AWProject.FORMATS.has(format):
		res.error = "Unknown format: %s." % format
		return res
	var e := AWEngine.new()
	if not e.is_available():
		res.error = "The native engine isn't available (%s), so there is nothing to render with." % e.status_text()
		return res
	e.set_project(project)
	var total := e.export_begin(0.0)
	if total <= 0:
		e.export_end()
		res.error = "Nothing to export: the sound has no length."
		return res
	var rate := int(AudioServer.get_mix_rate())
	if format != "wav" and not e.export_configure(1, clampf(quality, 0.0, 10.0) / 10.0, total):
		e.export_end()
		res.error = "The %s encoder couldn't be set up for %d Hz." % [AWProject.FORMAT_NAMES[format], rate]
		return res
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var mk := DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			e.export_end()
			res.error = "Couldn't create the folder %s (%s)." % [dir, error_string(mk)]
			return res
	var part := path + ".part"
	var f := FileAccess.open(part, FileAccess.WRITE)
	if f == null:
		e.export_end()
		res.error = "Couldn't write %s (%s)." % [part, error_string(FileAccess.get_open_error())]
		return res
	var trailer := cue_chunks(project, rate, total) if format == "wav" else PackedByteArray()
	var header := _header(rate, bits, total, total * 2 * (bits / 8), trailer.size()) if format == "wav" else PackedByteArray()
	f.store_buffer(header)
	var tree := Engine.get_main_loop() as SceneTree
	var chunk := maxi(1, int(CHUNK_SEC * rate))
	var done := 0
	var peak := 0.0
	var clipped := 0
	while done < total:
		if cancelled:
			break
		var n := mini(chunk, total - done)
		var r := e.export_next(n, bits if format == "wav" else 0)
		f.store_buffer(r.data as PackedByteArray)
		peak = maxf(peak, float(r.peak))
		clipped += int(r.clipped)
		done += n
		progress.emit(float(done) / float(total))
		if tree != null and done < total:
			await tree.process_frame
	if not cancelled and format != "wav":
		f.store_buffer(e.export_finish())
	if not cancelled and not trailer.is_empty():
		f.store_buffer(trailer)
	e.export_end()
	var write_err := f.get_error()
	var file_bytes := f.get_position()
	f.close()
	if cancelled:
		DirAccess.remove_absolute(part)
		res.cancelled = true
		res.error = "Export cancelled."
		return res
	if write_err != OK:
		DirAccess.remove_absolute(part)
		res.error = "Writing failed (%s). Is the disk full?" % error_string(write_err)
		return res
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var mv := DirAccess.rename_absolute(part, path)
	if mv != OK:
		DirAccess.remove_absolute(part)
		res.error = "Couldn't move the finished file into place (%s)." % error_string(mv)
		return res
	if Engine.is_editor_hint():
		tell_editor(path) # not awaited: the result is ready, the import follows
	res.ok = true
	res.frames = total
	res.seconds = float(total) / float(rate)
	res.bytes = int(file_bytes)
	res.peak_db = 20.0 * log(peak) / log(10.0) if peak > 0.0 else -INF
	res.clipped = clipped
	return res


## Makes the editor import the written file now (runs on in the background; don't await it).
## A plain scan() isn't enough: it does nothing while another scan is running, and it compares
## file times at one-second resolution, so a new file could stay unimported, or a file written
## over an imported one could keep playing the old import until the editor restarts.
static func tell_editor(path: String, reimport := true) -> void:
	var local := ProjectSettings.localize_path(path)
	if not local.begins_with("res://"):
		return
	var fs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	var known := fs.get_file_type(local) != ""
	if not known:
		for i in 2: # a scan already running may have passed this folder: wait for it, scan again
			while fs.is_scanning():
				await tree.process_frame
			if fs.get_file_type(local) != "":
				return # the scan imported it
			fs.scan()
			await tree.process_frame
		return
	fs.update_file(local)
	if not reimport:
		return
	while fs.is_scanning():
		await tree.process_frame
	fs.reimport_files(PackedStringArray([local]))


## Chunks after the audio: markers as cue points with names ("cue " + LIST/adtl/labl), and the
## loop region (when on and inside the export) as a sampler loop ("smpl"), which Godot's WAV import
## picks up with Loop Mode "Detect From WAV". Empty when there is nothing to write.
static func cue_chunks(project: AWProject, rate: int, total: int) -> PackedByteArray:
	var out := PackedByteArray()
	var cues: Array = []
	for m in project.markers:
		var fr := int(round(m.time_sec * rate))
		if fr >= 0 and fr < total:
			cues.append([cues.size() + 1, fr, m.name])
	if not cues.is_empty():
		var cue := PackedByteArray()
		cue.resize(4 + 24 * cues.size())
		cue.encode_u32(0, cues.size())
		for i in cues.size():
			var o := 4 + 24 * i
			cue.encode_u32(o, cues[i][0])
			cue.encode_u32(o + 4, cues[i][1])
			cue.encode_u32(o + 8, 0x61746164) # "data"
			cue.encode_u32(o + 12, 0)
			cue.encode_u32(o + 16, 0)
			cue.encode_u32(o + 20, cues[i][1])
		out.append_array(_chunk("cue ", cue))
		var adtl := "adtl".to_ascii_buffer()
		for cp: Array in cues:
			var labl := PackedByteArray()
			labl.resize(4)
			labl.encode_u32(0, cp[0])
			labl.append_array((cp[2] as String).to_utf8_buffer())
			labl.append(0)
			adtl.append_array(_chunk("labl", labl))
		out.append_array(_chunk("LIST", adtl))
	var ls := int(round(project.loop_start_sec * rate))
	var le := int(round(project.loop_end_sec * rate))
	if project.loop_enabled and ls >= 0 and le > ls and le <= total:
		var smpl := PackedByteArray()
		smpl.resize(36 + 24)
		smpl.encode_u32(8, int(1e9 / rate)) # sample period (ns)
		smpl.encode_u32(12, 60) # MIDI unity note
		smpl.encode_u32(28, 1) # one loop
		smpl.encode_u32(36, 0) # cue id
		smpl.encode_u32(40, 0) # forward
		smpl.encode_u32(44, ls)
		smpl.encode_u32(48, le - 1) # last frame of the loop (inclusive)
		out.append_array(_chunk("smpl", smpl))
	return out


static func _chunk(id: String, body: PackedByteArray) -> PackedByteArray:
	var c := id.to_ascii_buffer()
	c.resize(8)
	c.encode_u32(4, body.size())
	c.append_array(body)
	if body.size() % 2 == 1:
		c.append(0)
	return c


## RIFF/WAVE header: PCM for 16-bit, IEEE float (with the fact chunk the format asks for) for 32.
static func _header(rate: int, bits: int, frames: int, data_bytes: int, trailer_bytes := 0) -> PackedByteArray:
	var b := PackedByteArray()
	var float_fmt := bits == 32
	var header_size := 56 if float_fmt else 44
	b.append_array("RIFF".to_ascii_buffer())
	b.resize(b.size() + 4)
	b.encode_u32(4, header_size - 8 + data_bytes + trailer_bytes)
	b.append_array("WAVE".to_ascii_buffer())
	b.append_array("fmt ".to_ascii_buffer())
	var o := b.size()
	b.resize(o + 20)
	b.encode_u32(o, 16)
	b.encode_u16(o + 4, 3 if float_fmt else 1)
	b.encode_u16(o + 6, 2)
	b.encode_u32(o + 8, rate)
	b.encode_u32(o + 12, rate * 2 * (bits / 8))
	b.encode_u16(o + 16, 2 * (bits / 8))
	b.encode_u16(o + 18, bits)
	if float_fmt:
		b.append_array("fact".to_ascii_buffer())
		o = b.size()
		b.resize(o + 8)
		b.encode_u32(o, 4)
		b.encode_u32(o + 4, frames)
	b.append_array("data".to_ascii_buffer())
	o = b.size()
	b.resize(o + 4)
	b.encode_u32(o, data_bytes)
	return b


## One line for the status bar.
static func summary(r: Dictionary) -> String:
	if not r.ok:
		return "Export failed: %s" % r.error if not r.cancelled else "Export cancelled."
	var peak: String = "silent" if is_inf(float(r.peak_db)) else "peak %.1f dBFS" % float(r.peak_db)
	var s := "Exported %s: %.2f s, %s, %s." % [str(r.path).get_file(), float(r.seconds), AWExportPanel._size_text(int(r.bytes)), peak]
	if str(r.path).get_extension().to_lower() != "wav":
		s += " Lossy."
	if int(r.clipped) > 0:
		s += " %d samples are over full scale and will clip. Lower the Output volume or add a Limiter." % int(r.clipped)
	elif is_inf(float(r.peak_db)):
		s += " Nothing audible was rendered. Check muted clips and the end marker."
	return s
