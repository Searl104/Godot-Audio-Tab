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
	var header := _header(rate, bits, total, total * 2 * (bits / 8)) if format == "wav" else PackedByteArray()
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
		EditorInterface.get_resource_filesystem().scan()
	res.ok = true
	res.frames = total
	res.seconds = float(total) / float(rate)
	res.bytes = int(file_bytes)
	res.peak_db = 20.0 * log(peak) / log(10.0) if peak > 0.0 else -INF
	res.clipped = clipped
	return res


## RIFF/WAVE header: PCM for 16-bit, IEEE float (with the fact chunk the format asks for) for 32.
static func _header(rate: int, bits: int, frames: int, data_bytes: int) -> PackedByteArray:
	var b := PackedByteArray()
	var float_fmt := bits == 32
	var header_size := 56 if float_fmt else 44
	b.append_array("RIFF".to_ascii_buffer())
	b.resize(b.size() + 4)
	b.encode_u32(4, header_size - 8 + data_bytes)
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
