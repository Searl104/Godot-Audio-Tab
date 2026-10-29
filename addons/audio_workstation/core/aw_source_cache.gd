@tool
class_name AWSourceCache
extends RefCounted
## Decodes audio files once and hands them to the native core.
##
## Decoding uses Godot's own stream classes (WAV, Ogg, MP3, anything imported), through
## AudioStreamPlayback.mix_audio(), which also resamples to the audio server's mix rate. The
## core then only ever sees stereo float frames at one sample rate.

const CHUNK := 4096
const MAX_CHUNKS := 200000 # ~ 5 hours at 44.1 kHz; stops a stream that never ends

var _core: Object
## path -> {"id": int, "frames": int, "length": float}; id -1 means the file couldn't be read.
var _entries := {}
var _peaks := {}


func _init(core: Object) -> void:
	_core = core


## Loads an AudioStream from any path: imported resources (res://) or raw files (user://,
## absolute paths) by extension.
static func load_stream(path: String) -> AudioStream:
	if path == "":
		return null
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path)
		if res is AudioStream:
			return res
	if not FileAccess.file_exists(path):
		return null
	match path.get_extension().to_lower():
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null


## Source length in seconds, or 0 if unknown.
static func stream_length(path: String) -> float:
	var s := load_stream(path)
	return s.get_length() if s else 0.0


## Godot's decoder resamples with a 2-source-frame lookahead, so its output lags the file by
## about 2 * mix_rate / file_rate frames and ends a few frames early. decode() removes that lag
## and pads the tail so a source sample lands exactly where the file says it is.
const DECODER_LAG_SOURCE_FRAMES := 2.0

## Decodes a whole stream to stereo frames at the mix rate.
static func decode(stream: AudioStream) -> PackedVector2Array:
	var out := PackedVector2Array()
	var pb := stream.instantiate_playback()
	if pb == null:
		return out
	pb.start(0.0)
	for i in MAX_CHUNKS:
		out.append_array(pb.mix_audio(1.0, CHUNK))
		if not pb.is_playing():
			break
	pb.stop()
	var mix_rate := AudioServer.get_mix_rate()
	var file_rate: float = float(stream.get("mix_rate")) if stream is AudioStreamWAV else mix_rate
	var lag := int(round(DECODER_LAG_SOURCE_FRAMES * mix_rate / maxf(file_rate, 1.0)))
	var want := int(round(stream.get_length() * mix_rate))
	if lag > 0 and out.size() > lag:
		out = out.slice(lag)
	if out.size() < want:
		var pad := PackedVector2Array()
		pad.resize(want - out.size())
		out.append_array(pad)
	return out


## Source id for a path (decoding it on first use), or -1.
func get_id(path: String) -> int:
	if _core == null or path == "":
		return -1
	if _entries.has(path):
		return _entries[path].id
	var entry := {"id": -1, "frames": 0, "length": 0.0}
	var stream := load_stream(path)
	if stream:
		var frames := decode(stream)
		if frames.size() > 0:
			entry.id = _core.call("add_source", frames)
			entry.frames = frames.size()
			entry.length = float(frames.size()) / float(_core.call("get_sample_rate"))
	_entries[path] = entry
	return entry.id


## Drops what was decoded for a path so the next use re-reads the file.
## Note: the core keeps the old audio until it is cleared (clear() below).
func forget(path: String) -> void:
	_entries.erase(path)
	for key: String in _peaks.keys():
		if key.begins_with(path + "|"):
			_peaks.erase(key)


func clear() -> void:
	_entries.clear()
	_peaks.clear()
	if _core:
		_core.call("clear_sources")


## Peak amplitude (0..1), `per_second` buckets per second of the source. Empty if unavailable.
func get_peaks(path: String, per_second: float) -> PackedFloat32Array:
	var key := "%s|%s" % [path, per_second]
	if _peaks.has(key):
		return _peaks[key]
	var id := get_id(path)
	var peaks := PackedFloat32Array()
	if id >= 0:
		peaks = _core.call("get_peaks", id, per_second)
	_peaks[key] = peaks
	return peaks
