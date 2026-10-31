@tool
extends RefCounted

static var fails := 0
static var out_dir := ""


static func check(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("PASS  " if cond else "FAIL  ") + what)


static func frames(tree: SceneTree, n: int) -> void:
	for i in n:
		await tree.process_frame


static func click(ctrl: Control, pos: Vector2, button := MOUSE_BUTTON_LEFT, pressed := true, double := false, shift := false, ctrl_key := false, alt := false) -> void:
	var e := InputEventMouseButton.new()
	e.alt_pressed = alt
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = ctrl.get_global_transform() * pos
	e.double_click = double
	e.shift_pressed = shift
	e.ctrl_pressed = ctrl_key
	ctrl._gui_input(e)


static func key(screen: Control, code: Key, ctrl := false, shift := false, echo := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	e.echo = echo
	screen._unhandled_key_input(e)


static func move(ctrl: Control, pos: Vector2, shift := false, mods := {}) -> void:
	var e := InputEventMouseMotion.new()
	e.ctrl_pressed = mods.get("ctrl", false)
	e.alt_pressed = mods.get("alt", false)
	e.position = pos
	e.global_position = ctrl.get_global_transform() * pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	e.shift_pressed = shift
	ctrl._gui_input(e)


static func drag(ctrl: Control, from: Vector2, to: Vector2, steps := 5) -> void:
	click(ctrl, from)
	for i in range(1, steps + 1):
		move(ctrl, from.lerp(to, float(i) / steps))
	click(ctrl, to, MOUSE_BUTTON_LEFT, false)


static func shot(tree: SceneTree, name: String) -> void:
	await frames(tree, 6)
	var img := tree.root.get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name))
	print("SHOT ", name)


static func write_wav(path: String, secs: float, fn: Callable) -> void:
	var sr := int(AudioServer.get_mix_rate())
	var n := int(secs * sr)
	var bytes := PackedByteArray()
	bytes.resize(n * 4)
	for i in n:
		var v: Vector2i = fn.call(i, sr)
		bytes.encode_s16(i * 4, v.x)
		bytes.encode_s16(i * 4 + 2, v.y)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = true
	w.mix_rate = sr
	w.data = bytes
	w.save_to_wav(path)


static func nonzero_range(buf: PackedVector2Array, thresh := 0.001) -> Vector2i:
	var first := -1
	var last := -1
	for i in buf.size():
		if absf(buf[i].x) > thresh or absf(buf[i].y) > thresh:
			if first < 0:
				first = i
			last = i
	return Vector2i(first, last)


static func argmax(buf: PackedVector2Array) -> int:
	var best := -1
	var bv := 0.0
	for i in buf.size():
		var a := maxf(absf(buf[i].x), absf(buf[i].y))
		if a > bv:
			bv = a
			best = i
	return best


static func dry_playback_tests(screen: AWMainScreen) -> void:
	var tree := screen.get_tree()
	var sr := int(AudioServer.get_mix_rate())
	var click := "/tmp/aw_click.wav"
	var dc := "/tmp/aw_dc.wav"
	write_wav(click, 2.0, func(i: int, rate: int) -> Vector2i:
		if i == int(0.5 * rate) or i == int(1.5 * rate):
			return Vector2i(16000, 8000)
		return Vector2i.ZERO)
	write_wav(dc, 4.0, func(_i: int, _rate: int) -> Vector2i: return Vector2i(16384, 16384))
	var e := AWEngine.new()
	var proj := AWProject.new()
	e.set_project(proj)
	check(e.core != null, "dry: private engine created")

	var id: int = e._sources.get_id(click)
	var n_src: int = e.core.call("get_source_frames", id)
	check(id >= 0 and absi(n_src - 2 * sr) <= 32, "decode: click.wav -> %d frames (expect %d)" % [n_src, 2 * sr])
	check(e._sources.get_id("/tmp/does_not_exist.wav") == -1, "decode: missing file gives id -1")

	# 1. A known source sample lands at the expected frame.
	var clip := AWClip.create("click", 1.0, 1.0, 0, Color.RED)
	clip.source_path = click
	clip.source_offset_sec = 0.25
	proj.clips.append(clip)
	e.project_edited(true)
	var buf := e.render_preview_range(0.0, 3.0)
	var hit := argmax(buf)
	var want := int(round(1.0 * sr)) + int(0.5 * sr) - int(round(0.25 * sr))
	check(buf.size() == 3 * sr and absi(hit - want) <= 1, "click lands at frame %d (wanted %d)" % [hit, want])
	check(absf(buf[hit].x - 16000.0 / 32768.0) < 0.002 and absf(buf[hit].y - 8000.0 / 32768.0) < 0.002, "click keeps its channel levels (L %.3f R %.3f)" % [buf[hit].x, buf[hit].y])
	var nz := nonzero_range(buf)
	var clicks := 0
	for i in buf.size():
		if absf(buf[i].x) > 0.01:
			clicks += 1
	check(clicks == 1, "the second click (past the clip length) and the trimmed one before the offset are silent")

	# 2. Muted clip makes no sound.
	clip.muted = true
	e.project_edited(true)
	check(nonzero_range(e.render_preview_range(0.0, 3.0)).x == -1, "muted clip is silent")
	clip.muted = false

	# 3. Rendered length equals play_length() (constant rate and pitch ramp).
	proj.clips.clear()
	for case in [["plain", 0.0], ["octave down", -12.0], ["octave up", 12.0]]:
		var cl := AWClip.create("dc", 0.5, 1.0, 0, Color.BLUE)
		cl.source_path = dc
		proj.clips.assign([cl])
		cl.chain.effects[0].params["pitch_semitones"] = case[1]
		cl.invalidate_warp()
		e.project_edited(true)
		var b := e.render_preview_range(0.0, 4.0)
		var r := nonzero_range(b)
		var got := r.y + 1 - r.x
		var expect_len := int(round(cl.play_length() * sr))
		check(absi(r.x - int(round(0.5 * sr))) <= 1 and absi(got - expect_len) <= 3,
			"%s: rendered %d frames, play_length() says %d, starts at %d" % [case[0], got, expect_len, r.x])
	var ramp_clip: AWClip = AWProject.create_demo().clips[3]
	ramp_clip.source_path = dc
	ramp_clip.start_sec = 0.0
	ramp_clip.fade_in_sec = 0.0
	ramp_clip.fade_out_sec = 0.0
	ramp_clip.source_offset_sec = 0.0
	ramp_clip.length_sec = minf(ramp_clip.length_sec, 3.0)
	for ri in range(1, ramp_clip.chain.effects.size()):
		ramp_clip.chain.effects[ri].bypass = true # its Reverb would add a tail to the measured length
	proj.clips.assign([ramp_clip])
	e.project_edited(true)
	var rb := e.render_preview_range(0.0, 6.0)
	var rr := nonzero_range(rb)
	var rgot := rr.y + 1 - rr.x
	var rexp := int(round(ramp_clip.play_length() * sr))
	check(absi(rgot - rexp) <= 4 and ramp_clip.play_length() > ramp_clip.length_sec,
		"pitch ramp 0 to -5 st: rendered %d frames, play_length() %.4f s = %d (clip %.2f s)" % [rgot, ramp_clip.play_length(), rexp, ramp_clip.length_sec])

	# 4. Fades, gain, pan.
	var f := AWClip.create("fade", 0.0, 2.0, 0, Color.GREEN)
	f.source_path = dc
	f.fade_in_sec = 1.0
	f.fade_out_sec = 1.0
	proj.clips.assign([f])
	e.project_edited(true)
	var fb := e.render_preview_range(0.0, 2.5)
	check(absf(fb[int(0.5 * sr)].x - 0.25) < 0.01 and absf(fb[int(1.0 * sr) - 10].x - 0.5) < 0.01 and absf(fb[int(1.5 * sr)].x - 0.25) < 0.01 and absf(fb[int(1.99 * sr)].x) < 0.01,
		"fades: %.3f @0.5 s, %.3f @1.0 s, %.3f @1.5 s, %.3f @1.99 s" % [fb[int(0.5 * sr)].x, fb[int(1.0 * sr) - 10].x, fb[int(1.5 * sr)].x, fb[int(1.99 * sr)].x])
	f.fade_in_sec = 0.0
	f.fade_out_sec = 0.0
	f.chain.effects[0].params["gain_db"] = -6.0
	e.project_edited(true)
	var gb := e.render_preview_range(0.0, 1.0)
	check(absf(gb[1000].x - 0.5 * db_to_linear(-6.0)) < 0.003, "gain -6 dB: %.4f" % gb[1000].x)
	f.chain.effects[0].params["pan"] = -1.0
	e.project_edited(true)
	var pb := e.render_preview_range(0.0, 1.0)
	check(pb[1000].y == 0.0 and pb[1000].x > 0.2, "pan hard left: L %.3f R %.3f" % [pb[1000].x, pb[1000].y])

	# 5. Peaks.
	var peaks := e.get_peaks(click, 120.0)
	var pk := 0.0
	var pk_i := -1
	for i in peaks.size():
		if peaks[i] > pk:
			pk = peaks[i]
			pk_i = i
	check(peaks.size() == 240 and absf(pk - 16000.0 / 32768.0) < 0.002 and pk_i == 60, "peaks: %d buckets, max %.3f at bucket %d (click at 0.5 s = 60)" % [peaks.size(), pk, pk_i])

	# 6. Transport on an isolated core: loop, seek, end of content, audio-thread path.
	var core: Object = ClassDB.instantiate(&"AWCore")
	core.call("set_sample_rate", float(sr))
	var sid: int = core.call("add_source", e.core.call("render_range", 0, 0)) if false else -1
	var frames_dc := PackedVector2Array()
	frames_dc.resize(sr * 2)
	for i in frames_dc.size():
		frames_dc[i] = Vector2(0.5, 0.5)
	sid = core.call("add_source", frames_dc)
	var voice := {"source": sid, "start_frame": 0, "offset": 0.0, "length": float(sr * 2), "rates": PackedFloat32Array([1.0])}
	var end_f: int = core.call("set_plan", [voice])
	check(end_f == sr * 2, "plan end is %d frames" % end_f)
	core.call("set_loop", true, 0, sr)
	core.call("play", 0)
	var lb: PackedVector2Array = core.call("render", int(sr * 1.5))
	check(core.call("is_playing") and absi(int(core.call("get_position")) - sr / 2) <= 1 and nonzero_range(lb).y == lb.size() - 1,
		"loop: after 1.5 s the position is %.3f s, still playing, no gap" % (float(core.call("get_position")) / sr))
	core.call("set_loop", false, 0, 0)
	core.call("seek", sr * 2 - 100)
	var eb: PackedVector2Array = core.call("render", 500)
	check(not core.call("is_playing") and int(core.call("get_position")) == sr * 2 and nonzero_range(eb).y == 99,
		"end of content: stops at frame %d, 100 frames of sound then silence" % int(core.call("get_position")))
	core.call("play", 1000)
	core.call("seek", 5000)
	core.call("render", 100)
	check(int(core.call("get_position")) == 5100, "seek moves the playhead")
	# The same mix through the audio-thread path (AWPreviewStream).
	var stream: AudioStream = ClassDB.instantiate(&"AWPreviewStream")
	stream.call("set_core", core)
	var playback := stream.instantiate_playback()
	core.call("play", 0)
	var via: PackedVector2Array = playback.mix_audio(1.0, 2048)
	check(via.size() == 2048 and absf(via[10].x - 0.5) < 0.001 and int(core.call("get_position")) == 2048,
		"audio-thread path: stream pulled %d frames, position %d" % [via.size(), int(core.call("get_position"))])

	# 7. Engine-level playback: playhead follows, stops by itself at the end.
	var e2 := AWEngine.new()
	var p2 := AWProject.new()
	var short := AWClip.create("short", 0.0, 0.4, 0, Color.RED)
	short.source_path = dc
	p2.clips.append(short)
	e2.set_project(p2)
	e2.attach(screen)
	var seen := {"pos": 0.0, "n": 0, "ended": false}
	e2.position_changed.connect(func(t: float) -> void:
		seen.pos = t
		seen.n += 1)
	e2.playback_state_changed.connect(func(on: bool) -> void:
		if not on:
			seen.ended = true)
	e2.play(0.0)
	var waited := 0.0
	while not seen.ended and waited < 3.0:
		await tree.process_frame
		e2.process(get_process_delta(tree))
		waited += get_process_delta(tree)
	check(seen.ended and seen.n > 2 and absf(seen.pos - 0.4) < 0.02,
		"engine plays a 0.4 s clip to the end: %d position updates, last %.3f s, ended=%s" % [seen.n, seen.pos, seen.ended])
	e2.stop()
	if e2._player:
		e2._player.queue_free()


# --- Effects (milestone 4a: filters, EQ, Amplify, tails) -----------------------------

static func _sine_source(core: Object, hz: float, secs: float) -> int:
	var sr: float = core.call("get_sample_rate")
	var a := PackedVector2Array()
	a.resize(int(secs * sr))
	for i in a.size():
		var v := 0.5 * sin(TAU * hz * i / sr)
		a[i] = Vector2(v, v)
	return core.call("add_source", a)


static func _fx(type: int, params: Array) -> Dictionary:
	var tables: Array = []
	for p: float in params:
		tables.append(PackedFloat32Array([p]))
	return {"type": type, "params": tables, "step": 64}


static func _fx_voice(src_id: int, secs: float, sr: float, effects: Array, tail_frames := 0) -> Dictionary:
	return {"source": src_id, "start_frame": 0, "offset": 0.0, "length": secs * sr, "rates": PackedFloat32Array([1.0]),
		"rate_step": 64, "effects": effects, "tail_frames": tail_frames}


static func _peak(buf: PackedVector2Array, from: int, to: int) -> float:
	var m := 0.0
	for i in range(from, mini(to, buf.size())):
		m = maxf(m, absf(buf[i].x))
	return m


## Peak of a steady sine of `hz` after the given effect, measured away from the start-up.
static func _through(core: Object, hz: float, effects: Array) -> float:
	var sr: float = core.call("get_sample_rate")
	core.call("clear_sources")
	var id := _sine_source(core, hz, 1.5)
	core.call("set_plan", [_fx_voice(id, 1.5, sr, effects)])
	var b: PackedVector2Array = core.call("render_range", 0, int(1.5 * sr))
	return _peak(b, int(0.8 * sr), int(1.4 * sr))


static func effects_tests(screen: AWMainScreen) -> void:
	var sr := int(AudioServer.get_mix_rate())
	var e := AWEngine.new()
	e.set_project(AWProject.new())
	if e.core == null:
		return
	var core: Object = e.core
	core.call("set_sample_rate", float(sr))

	# Filters: -3 dB at the cutoff, flat in the pass band, steep stop band.
	var lp := [_fx(1, [1000.0, 0.5])]
	var p1 := _through(core, 1000.0, lp)
	check(absf(p1 - 0.5 * 0.7071) < 0.01, "low pass: -3 dB at the cutoff (%.3f, want 0.354)" % p1)
	check(absf(_through(core, 100.0, lp) - 0.5) < 0.01, "low pass: 100 Hz passes untouched")
	check(_through(core, 10000.0, lp) < 0.02, "low pass: 10 kHz is cut by 28 dB or more")
	var hp := [_fx(2, [1000.0, 0.5])]
	check(absf(_through(core, 1000.0, hp) - 0.5 * 0.7071) < 0.01, "high pass: -3 dB at the cutoff")
	check(absf(_through(core, 10000.0, hp) - 0.5) < 0.01, "high pass: 10 kHz passes untouched")
	check(_through(core, 100.0, hp) < 0.02, "high pass: 100 Hz is cut by 28 dB or more")
	var bp := [_fx(3, [1000.0, 0.5])]
	check(absf(_through(core, 1000.0, bp) - 0.5) < 0.01, "band pass: centre frequency passes at full level")
	check(_through(core, 100.0, bp) < 0.1 and _through(core, 10000.0, bp) < 0.1, "band pass: both sides are attenuated")
	var res_hi := _through(core, 1000.0, [_fx(1, [1000.0, 1.0])])
	check(res_hi > 3.0, "low pass: full resonance rings up at the cutoff (%.2f)" % res_hi)

	# EQ: gain at a band centre equals the setting.
	var eq_up := [_fx(4, [0.0, 0.0, 0.0, 12.0, 0.0, 0.0])]
	var pu := _through(core, 1000.0, eq_up)
	check(absf(pu - 0.5 * db_to_linear(12.0)) < 0.03, "EQ: +12 dB at 1 kHz (%.3f, want %.3f)" % [pu, 0.5 * db_to_linear(12.0)])
	var pd := _through(core, 1000.0, [_fx(4, [0.0, 0.0, 0.0, -12.0, 0.0, 0.0])])
	check(absf(pd - 0.5 * db_to_linear(-12.0)) < 0.01, "EQ: -12 dB at 1 kHz (%.3f)" % pd)
	check(absf(_through(core, 1000.0, [_fx(4, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])]) - 0.5) < 0.0001, "EQ: flat settings leave the signal alone")
	check(absf(_through(core, 100.0, eq_up) - 0.5) < 0.1, "EQ: a 1 kHz boost barely touches 100 Hz")

	# Amplify.
	check(absf(_through(core, 440.0, [_fx(5, [-6.0206])]) - 0.25) < 0.002, "amplify -6 dB halves the level")

	# Distortion: tanh(k x) / k with k = 1 + 19 drive; keep_hf lets highs bypass it.
	var d0 := _through(core, 440.0, [_fx(6, [0.0, 0.0, 0.0, 20000.0])])
	check(absf(d0 - tanh(0.5) / 1.0) < 0.003, "distortion drive 0 is a gentle tanh (%.3f, want %.3f)" % [d0, tanh(0.5)])
	var d1 := _through(core, 440.0, [_fx(6, [1.0, 0.0, 0.0, 20000.0])])
	check(absf(d1 - tanh(10.0) / 20.0) < 0.002, "distortion drive 1 squashes the peak to 1/20 (%.3f)" % d1)
	check(absf(_through(core, 440.0, [_fx(6, [1.0, 0.0, -6.0206, 20000.0])]) - d1 * 0.5) < 0.002, "distortion post gain scales the output")
	check(_through(core, 10000.0, [_fx(6, [1.0, 0.0, 0.0, 1000.0])]) > 0.4, "distortion keep HF: a 10 kHz tone passes a 1 kHz split almost untouched")
	check(_through(core, 10000.0, [_fx(6, [1.0, 0.0, 0.0, 20000.0])]) < 0.06, "distortion without the split squashes the same tone")

	# Delay: a 0.3 s burst, a 250 ms tap and feedback.
	core.call("clear_sources")
	var dsrc := _sine_source(core, 1000.0, 0.3)
	core.call("set_plan", [_fx_voice(dsrc, 0.3, float(sr), [_fx(7, [250.0, 0.0, -6.0206, 0.0])], int(0.5 * sr))])
	var dbuf: PackedVector2Array = core.call("render_range", 0, int(0.8 * sr))
	check(_peak(dbuf, int(0.01 * sr), int(0.24 * sr)) < 0.01, "delay: nothing before the first tap (dry 0)")
	check(absf(_peak(dbuf, int(0.27 * sr), int(0.49 * sr)) - 0.5) < 0.02, "delay: first echo at full level, 250 ms late")
	check(absf(_peak(dbuf, int(0.57 * sr), int(0.74 * sr)) - 0.25) < 0.02, "delay: feedback -6 dB makes the second echo half as loud (%.3f, echo1 %.3f)" % [_peak(dbuf, int(0.57 * sr), int(0.74 * sr)), _peak(dbuf, int(0.27 * sr), int(0.49 * sr))])
	core.call("set_plan", [_fx_voice(dsrc, 0.3, float(sr), [_fx(7, [250.0, -60.0, -60.0, 1.0])], int(0.5 * sr))])
	dbuf = core.call("render_range", 0, int(0.8 * sr))
	check(absf(_peak(dbuf, int(0.02 * sr), int(0.28 * sr)) - 0.5) < 0.01 and _peak(dbuf, int(0.35 * sr), int(0.79 * sr)) < 0.01, "delay: dry 1 and a silent tap leave just the original")

	# Compressor: -6 dB sine, threshold -12, ratio 4 -> about 4.5 dB of reduction.
	var cmp := [_fx(8, [-12.0, 4.0, 0.0, 20.0, 250.0, 1.0])]
	var cp := _through(core, 440.0, cmp)
	var want_c := 0.5 * db_to_linear(-(20.0 * log(0.5) / log(10.0) + 12.0) * 0.75)
	check(absf(cp - want_c) < 0.03, "compressor: 4:1 above -12 dB (%.3f, want about %.3f)" % [cp, want_c])
	check(absf(_through(core, 440.0, [_fx(8, [0.0, 4.0, 0.0, 20.0, 250.0, 1.0])]) - 0.5) < 0.005, "compressor: below the threshold nothing changes")
	check(absf(_through(core, 440.0, [_fx(8, [-12.0, 1.0, 0.0, 20.0, 250.0, 1.0])]) - 0.5) < 0.005, "compressor: ratio 1:1 does nothing")
	check(absf(_through(core, 440.0, [_fx(8, [-12.0, 4.0, 0.0, 20.0, 250.0, 0.0])]) - 0.5) < 0.005, "compressor: mix 0 is the dry signal")
	check(absf(_through(core, 440.0, [_fx(8, [-12.0, 4.0, 6.0206, 20.0, 250.0, 1.0])]) - cp * 2.0) < 0.05, "compressor: +6 dB makeup doubles the output")

	check(absf(AWFxCurves.distortion(0.5, 1.0, 0.0, 0.0) - d1) < 0.002 and absf(AWFxCurves.distortion(0.5, 0.0, 0.0, 0.0) - d0) < 0.003, "plot curve equals the engine: distortion")
	var cp_db := 20.0 * log(cp / 0.5) / log(10.0)
	check(absf(AWFxCurves.compressor_db(-6.0206, -12.0, 4.0, 0.0, 1.0) - (-6.0206 + cp_db)) < 0.3, "plot curve equals the engine: compressor (%.2f dB vs %.2f dB)" % [AWFxCurves.compressor_db(-6.0206, -12.0, 4.0, 0.0, 1.0), -6.0206 + cp_db])

	# Limiter: nothing passes the ceiling.
	var lm := _through(core, 440.0, [_fx(9, [12.0, -6.0206, 0.1])])
	check(lm <= 0.2502 * 2.0 + 0.002 and lm > 0.45, "limiter: +12 dB into a -6 dB ceiling holds at %.4f" % lm)
	check(absf(_through(core, 440.0, [_fx(9, [0.0, 0.0, 0.1])]) - 0.5) < 0.002, "limiter: below the ceiling the signal is untouched")

	# Reverb (10): room size sets the length of the tail; wet 0 leaves the signal alone.
	core.call("clear_sources")
	var rsrc := _sine_source(core, 300.0, 0.2)
	var rtail := int(4.0 * sr)
	core.call("set_plan", [_fx_voice(rsrc, 0.2, float(sr), [_fx(10, [1.0, 0.5, 1.0, 1.0, 0.0])], rtail)])
	var rbig: PackedVector2Array = core.call("render_range", 0, int(1.4 * sr))
	core.call("set_plan", [_fx_voice(rsrc, 0.2, float(sr), [_fx(10, [0.0, 0.5, 1.0, 1.0, 0.0])], rtail)])
	var rsmall: PackedVector2Array = core.call("render_range", 0, int(1.4 * sr))
	var big_tail := _peak(rbig, int(0.8 * sr), int(1.3 * sr))
	var small_tail := _peak(rsmall, int(0.8 * sr), int(1.3 * sr))
	check(big_tail > 0.01 and big_tail > small_tail * 4.0, "reverb: a big room still rings at 0.8 s (%.4f), a small one has died (%.4f)" % [big_tail, small_tail])
	check(_peak(rbig, 0, int(1.4 * sr)) < 2.0, "reverb: stays bounded at room size 1")
	check(absf(_through(core, 440.0, [_fx(10, [1.0, 0.5, 1.0, 0.0, 1.0])]) - 0.5) < 0.002, "reverb: wet 0 / dry 1 passes the signal untouched")
	core.call("set_plan", [_fx_voice(rsrc, 0.2, float(sr), [_fx(10, [0.5, 0.5, 1.0, 1.0, 0.0])], rtail)])
	var rmid: PackedVector2Array = core.call("render_range", 0, int(0.5 * sr))
	check(_peak(rmid, 0, int(0.015 * sr)) < 0.0005 and _peak(rmid, int(0.2 * sr), int(0.4 * sr)) > 0.0005, "reverb: dry 0 starts silent, the tail builds after")

	# Chorus (11): the delay modulation moves the sound's level around; no depth, no movement.
	var wob := func(depth: float) -> float:
		core.call("clear_sources")
		var cid := _sine_source(core, 1000.0, 2.0)
		core.call("set_plan", [_fx_voice(cid, 2.0, float(sr), [_fx(11, [2.0, depth, 1.0, 0.0])])])
		var cb: PackedVector2Array = core.call("render_range", 0, int(1.9 * sr))
		var lo := INF
		var hi := 0.0
		for w in 16:
			var pk := _peak(cb, int((0.3 + w * 0.05) * sr), int((0.3 + w * 0.05 + 0.05) * sr))
			lo = minf(lo, pk)
			hi = maxf(hi, pk)
		return hi - lo
	var wob0: float = wob.call(0.0)
	var wob5: float = wob.call(6.0)
	check(wob0 < 0.01 and wob5 > 0.02, "chorus: depth 0 holds a steady level (%.3f), depth 6 ms moves it (%.3f)" % [wob0, wob5])
	check(absf(_through(core, 440.0, [_fx(11, [1.0, 5.0, 0.0, 1.0])]) - 0.5) < 0.002, "chorus: wet 0 / dry 1 passes the signal untouched")

	# Phaser (12): six allpass stages put a notch at the sweep centre (840 Hz), and leave lows alone.
	var ph := [_fx(12, [0.01, 0.1, 0.1])]
	check(_through(core, 840.0, ph) < 0.12, "phaser: the notch at 840 Hz (%.3f)" % _through(core, 840.0, ph))
	check(absf(_through(core, 20.0, ph) - 0.5) < 0.02, "phaser: 20 Hz passes at about full level (%.3f)" % _through(core, 20.0, ph))

	# Stereo Enhance (13): width scales the side (L - R); a centred signal never changes.
	var lsrc := PackedVector2Array()
	lsrc.resize(int(1.5 * sr))
	for i in lsrc.size():
		lsrc[i] = Vector2(0.5 * sin(TAU * 1000.0 * i / sr), 0.0)
	core.call("clear_sources")
	var lid: int = core.call("add_source", lsrc)
	var se_render := func(params: Array) -> PackedVector2Array:
		core.call("set_plan", [_fx_voice(lid, 1.5, float(sr), [_fx(13, params)])])
		return core.call("render_range", 0, int(1.5 * sr))
	var se1: PackedVector2Array = se_render.call([1.0, 0.0, 0.0])
	check(absf(_peak(se1, int(0.8 * sr), int(1.4 * sr)) - 0.5) < 0.01, "stereo enhance: width 1 is transparent (left only stays left)")
	var se1_r := 0.0
	for i in range(int(0.8 * sr), int(1.4 * sr)):
		se1_r = maxf(se1_r, absf(se1[i].y))
	check(se1_r < 0.002, "stereo enhance: width 1 keeps the right channel silent (%.4f)" % se1_r)
	var se0: PackedVector2Array = se_render.call([0.0, 0.0, 0.0])
	var se0_l := 0.0
	var se0_r := 0.0
	for i in range(int(0.8 * sr), int(1.4 * sr)):
		se0_l = maxf(se0_l, absf(se0[i].x))
		se0_r = maxf(se0_r, absf(se0[i].y))
	check(absf(se0_l - 0.25) < 0.01 and absf(se0_r - 0.25) < 0.01, "stereo enhance: width 0 folds it to mono, half level each side (%.3f / %.3f)" % [se0_l, se0_r])
	check(absf(_through(core, 440.0, [_fx(13, [4.0, 0.0, 0.0])]) - 0.5) < 0.002, "stereo enhance: a centred signal is unchanged at any width")
	check(absf(_through(core, 1000.0, [_fx(13, [1.0, 0.0, 1.0])]) - 0.25) < 0.01, "stereo enhance: surround 1 takes a centred signal down by half (%.3f)" % _through(core, 1000.0, [_fx(13, [1.0, 0.0, 1.0])]))

	# Gate (14): above the threshold it opens, below it the range turns the sound down.
	var g_open := _through(core, 440.0, [_fx(14, [-20.0, -40.0, 1.0, 50.0, 150.0, 3.0])])
	var g_shut := _through(core, 440.0, [_fx(14, [-3.0, -40.0, 1.0, 50.0, 150.0, 3.0])])
	check(absf(g_open - 0.5) < 0.005, "gate: a -6 dB signal over a -20 dB threshold passes (%.3f)" % g_open)
	check(absf(g_shut - 0.5 * db_to_linear(-40.0)) < 0.002, "gate: under the threshold the range pulls it down 40 dB (%.4f)" % g_shut)
	check(_through(core, 440.0, [_fx(14, [-3.0, -80.0, 1.0, 50.0, 150.0, 3.0])]) < 0.0001, "gate: range -80 dB is as good as silent")
	check(absf(_through(core, 440.0, [_fx(14, [-3.0, 0.0, 1.0, 50.0, 150.0, 3.0])]) - 0.5) < 0.002, "gate: range 0 dB does nothing")
	check(absf(AWFxCurves.gate_db(-6.0206, -3.0, -40.0) - (-6.0206 - 40.0)) < 1e-3 and absf(AWFxCurves.gate_db(-6.0206, -20.0, -40.0) + 6.0206) < 1e-3, "plot curve equals the engine: gate")
	# A burst after silence: the gate opens within a few ms of the attack.
	var gsrc := PackedVector2Array()
	gsrc.resize(int(1.0 * sr))
	for i in range(int(0.5 * sr), gsrc.size()):
		var gv := 0.5 * sin(TAU * 440.0 * i / sr)
		gsrc[i] = Vector2(gv, gv)
	core.call("clear_sources")
	var gid: int = core.call("add_source", gsrc)
	core.call("set_plan", [_fx_voice(gid, 1.0, float(sr), [_fx(14, [-20.0, -80.0, 1.0, 50.0, 150.0, 3.0])])])
	var gb: PackedVector2Array = core.call("render_range", 0, sr)
	check(_peak(gb, int(0.5 * sr) + int(0.01 * sr), int(0.5 * sr) + int(0.05 * sr)) > 0.45, "gate: opens within 10 ms of a burst")

	# Automation: a cutoff table sweeping 18 kHz down to 200 Hz closes the filter over time.
	var sweep := PackedFloat32Array()
	for i in int(0.8 * sr / 64.0) + 2:
		sweep.append(lerpf(18000.0, 200.0, minf(1.0, i * 64.0 / sr / 0.8))) # closes over 0.8 s, then holds
	core.call("clear_sources")
	var sid := _sine_source(core, 3000.0, 1.0)
	var sw := {"type": 1, "params": [sweep, PackedFloat32Array([0.5])], "step": 64}
	core.call("set_plan", [_fx_voice(sid, 1.0, sr, [sw])])
	var sb: PackedVector2Array = core.call("render_range", 0, sr)
	var early := _peak(sb, int(0.05 * sr), int(0.15 * sr))
	var late := _peak(sb, int(0.9 * sr), sr)
	check(early > 0.45 and late < 0.05, "cutoff sweep: open at the start (%.3f), closed at the end (%.4f)" % [early, late])

	# State is continuous across blocks and resets on a seek.
	core.call("clear_sources")
	sid = _sine_source(core, 700.0, 2.0)
	core.call("set_plan", [_fx_voice(sid, 2.0, sr, [_fx(1, [900.0, 0.8]), _fx(4, [3.0, 0.0, -4.0, 6.0, 0.0, 0.0])])])
	var whole: PackedVector2Array = core.call("render_range", 0, 6000)
	core.call("play", 0)
	var worst := 0.0
	var at := 0
	for n: int in [777, 1500, 53, 1024, 2646]:
		var blk: PackedVector2Array = core.call("render", n)
		for i in n:
			worst = maxf(worst, absf(blk[i].x - whole[at + i].x))
		at += n
	check(worst < 0.00001, "chain state carries across blocks (worst difference %.7f)" % worst)
	core.call("seek", 3000)
	var after: PackedVector2Array = core.call("render", 512)
	var fresh: PackedVector2Array = core.call("render_range", 3000, 512)
	worst = 0.0
	for i in 512:
		worst = maxf(worst, absf(after[i].x - fresh[i].x))
	check(worst < 0.00001, "seeking clears the filters (worst difference %.7f)" % worst)
	core.call("stop")

	# Tails: effects keep ringing after the clip, and the plan end includes them.
	core.call("clear_sources")
	var click := PackedVector2Array()
	click.resize(sr / 2)
	click[int(0.195 * sr)] = Vector2(1, 1) # just before the clip ends
	var cid: int = core.call("add_source", click)
	var tail := sr / 2
	var clen := 0.2
	var end_no: int = core.call("set_plan", [_fx_voice(cid, clen, sr, [_fx(3, [1000.0, 1.0])])])
	var tb0: PackedVector2Array = core.call("render_range", 0, sr)
	end_no += 0
	check(_peak(tb0, int(clen * sr) + 100, sr) == 0.0 and int(core.call("get_plan_end")) == int(round(clen * sr)), "no tail: silent after the clip, plan ends with it")
	var end_tail: int = core.call("set_plan", [_fx_voice(cid, clen, sr, [_fx(3, [1000.0, 1.0])], tail)])
	var tb: PackedVector2Array = core.call("render_range", 0, sr)
	check(end_tail == int(round(clen * sr)) + tail, "tail: plan end grows by the tail (%d)" % end_tail)
	check(_peak(tb, int(clen * sr) + 5, int(clen * sr) + 400) > 0.0005 and _peak(tb, end_tail + 10, sr) == 0.0, "tail: ringing continues past the clip, then stops")

	# Master chain.
	core.call("clear_sources")
	sid = _sine_source(core, 440.0, 1.0)
	var plain := {"source": sid, "start_frame": 0, "offset": 0.0, "length": float(sr), "rates": PackedFloat32Array([1.0]), "rate_step": 64}
	var mend: int = core.call("set_plan", [plain], {"gains": PackedFloat32Array([1.0]), "step": 64, "effects": [_fx(5, [-6.0206])], "tail_frames": 1000})
	var mb: PackedVector2Array = core.call("render_range", 0, sr)
	check(absf(_peak(mb, 1000, sr - 1000) - 0.25) < 0.002 and mend == sr + 1000, "master chain: amplify -6 dB on the mix, tail extends the end (%d)" % mend)

	# Plugin path: effect cards in a clip's chain reach the engine.
	var tone := "/tmp/aw_tone5k.wav"
	write_wav(tone, 2.0, func(i: int, rate: int) -> Vector2i:
		var v := int(16384.0 * sin(TAU * 5000.0 * i / rate))
		return Vector2i(v, v))
	var proj := AWProject.new()
	proj.master_chain = AWChain.create(AWEffectLibrary.MASTER_OUTPUT)
	proj.export_end_sec = 1.5 # the marker: 1 s clip + 0.5 s tail
	var ge := AWEngine.new()
	ge.set_project(proj)
	var clip := AWClip.create("fx", 0.0, 1.0, 0, Color.RED)
	clip.source_path = tone
	proj.clips.assign([clip])
	ge.project_edited(true)
	var dry := ge.render_preview_range(0.0, 1.0)
	var d_peak := _peak(dry, int(0.3 * sr), int(0.9 * sr))
	var card := AWEffect.create("Low Pass", clip.chain.new_effect_id())
	card.params["cutoff_hz"] = 500.0
	clip.chain.effects.append(card)
	ge.project_edited(true)
	var wet := ge.render_preview_range(0.0, 1.0)
	check(d_peak > 0.45 and _peak(wet, int(0.3 * sr), int(0.9 * sr)) < 0.01, "Low Pass card at 500 Hz removes a 5 kHz tone (dry %.2f, wet %.4f)" % [d_peak, _peak(wet, int(0.3 * sr), int(0.9 * sr))])
	check(int(ge.core.call("get_plan_end")) == int(round(1.5 * sr)), "the export marker sets the plan end (%d frames)" % int(ge.core.call("get_plan_end")))
	card.bypass = true
	ge.project_edited(true)
	check(_peak(ge.render_preview_range(0.0, 1.0), int(0.3 * sr), int(0.9 * sr)) > 0.45 and int(ge.core.call("get_plan_end")) == int(round(1.5 * sr)), "bypassed card: signal passes, the marker still decides the end")
	proj.export_end_sec = -1.0
	ge.project_edited(true)
	ge.render_preview_range(0.0, 0.01)
	check(int(ge.core.call("get_plan_end")) == sr, "automatic end with only a bypassed card: no tail (%d)" % int(ge.core.call("get_plan_end")))
	card.bypass = false
	ge.project_edited(true)
	ge.render_preview_range(0.0, 0.01)
	check(int(ge.core.call("get_plan_end")) == int(round((1.0 + AWProject.AUTO_TAIL_SEC) * sr)), "automatic end with a ringing card adds the automatic tail (%d)" % int(ge.core.call("get_plan_end")))
	proj.export_end_sec = 1.5
	ge.project_edited(true)
	var rev := AWEffect.create("Reverb", clip.chain.new_effect_id())
	clip.chain.effects.append(rev)
	ge.project_edited(true)
	check(_peak(ge.render_preview_range(0.0, 1.0), int(0.3 * sr), int(0.9 * sr)) < 0.01, "effects not ported yet (Reverb) are skipped without error")
	# A cutoff curve opens the filter over time.
	var cut := clip.chain.effects[1]
	AWProject._curve(clip.chain, cut.id, "cutoff_hz", Color.WHITE, [AWProject._k(0.0, 200.0, AWCurve.HandleMode.LINEAR), AWProject._k(1.0, 12000.0, AWCurve.HandleMode.LINEAR)])
	ge.project_edited(true)
	var cb := ge.render_preview_range(0.0, 1.0)
	check(_peak(cb, int(0.05 * sr), int(0.15 * sr)) < 0.05 and _peak(cb, int(0.9 * sr), int(0.98 * sr)) > 0.3, "cutoff curve 200 Hz to 12 kHz opens the filter over the clip")
	var ref_curve := clip.chain.get_curve(cut.id, "cutoff_hz")
	check(ref_curve != null, "cutoff curve exists on the card")


static func automation_tests(_screen: AWMainScreen) -> void:
	var sr := int(AudioServer.get_mix_rate())
	var dc := "/tmp/aw_dc.wav" # 4 s of constant 0.5, written by dry_playback_tests
	var e := AWEngine.new()
	var proj := AWProject.new()
	proj.master_chain = AWChain.create(AWEffectLibrary.MASTER_OUTPUT)
	e.set_project(proj)
	var K := AWProject._k
	var LIN := AWCurve.HandleMode.LINEAR

	# 1. Gain curve: the rendered envelope follows AWChain.sample (dB converted to amplitude).
	var clip := AWClip.create("auto", 0.0, 2.0, 0, Color.RED)
	clip.source_path = dc
	proj.clips.assign([clip])
	var src := clip.chain.effects[0]
	AWProject._curve(clip.chain, src.id, "gain_db", Color.WHITE, [K.call(0.0, -24.0, LIN), K.call(2.0, 0.0, LIN)])
	var gcurve := clip.chain.get_curve(src.id, "gain_db")
	e.project_edited(true)
	var b := e.render_preview_range(0.0, 2.0)
	var worst := 0.0
	for t: float in [0.05, 0.4, 0.8, 1.2, 1.6, 1.95]:
		var want := 0.5 * db_to_linear(clip.chain.sample(gcurve, t))
		worst = maxf(worst, absf(b[int(t * sr)].x - want))
	check(worst < 0.004, "gain curve -24 to 0 dB: envelope matches AWChain.sample (worst error %.5f)" % worst)
	check(b[int(0.05 * sr)].x < b[int(1.9 * sr)].x * 0.2, "gain curve rises: %.3f -> %.3f" % [b[int(0.05 * sr)].x, b[int(1.9 * sr)].x])

	# 2. Pan curve left to right.
	clip.chain.curves.clear()
	AWProject._curve(clip.chain, src.id, "pan", Color.WHITE, [K.call(0.0, -1.0, LIN), K.call(2.0, 1.0, LIN)])
	var pcurve := clip.chain.get_curve(src.id, "pan")
	e.project_edited(true)
	b = e.render_preview_range(0.0, 2.0)
	var pw := 0.0
	for t: float in [0.25, 0.5, 1.0, 1.5, 1.75]:
		var pan: float = clip.chain.sample(pcurve, t)
		var f := b[int(t * sr)]
		pw = maxf(pw, maxf(absf(f.x - 0.5 * (1.0 - maxf(pan, 0.0))), absf(f.y - 0.5 * (1.0 + minf(pan, 0.0)))))
	check(pw < 0.004, "pan curve -1 to +1: balance matches AWChain.sample (worst error %.5f)" % pw)

	# 3. Curves run on the clip's own clock: with Pitch falling, gain follows clip time, not project time.
	clip.chain.curves.clear()
	clip.length_sec = 2.0
	AWProject._curve(clip.chain, src.id, "pitch_semitones", Color.WHITE, [K.call(0.0, 0.0, LIN), K.call(2.0, -12.0, LIN)])
	AWProject._curve(clip.chain, src.id, "gain_db", Color.WHITE, [K.call(0.0, -30.0, LIN), K.call(2.0, 0.0, LIN)])
	gcurve = clip.chain.get_curve(src.id, "gain_db")
	clip.invalidate_warp()
	e.project_edited(true)
	var plen := clip.play_length()
	b = e.render_preview_range(0.0, plen + 0.2)
	var cw := 0.0
	for frac: float in [0.15, 0.4, 0.65, 0.9]:
		var p := plen * frac
		var s_clip := clip.project_to_local(p)
		var want2 := 0.5 * db_to_linear(clip.chain.sample(gcurve, s_clip))
		cw = maxf(cw, absf(b[int(p * sr)].x - want2))
	check(plen > 2.0 and cw < 0.005, "pitched clip (%.3f s long): gain follows clip time, worst error %.5f" % [plen, cw])

	# 4. LFO on gain, and plan refresh when only the LFO changes.
	clip.chain.curves.clear()
	clip.chain.effects[0].params["pitch_semitones"] = 0.0
	clip.invalidate_warp()
	AWProject._curve(clip.chain, src.id, "gain_db", Color.WHITE, [K.call(0.0, -6.0, LIN), K.call(2.0, -6.0, LIN)])
	gcurve = clip.chain.get_curve(src.id, "gain_db")
	var lfo := AWLfo.new()
	lfo.shape = AWLfo.Shape.SINE
	lfo.min_value = -18.0
	lfo.max_value = -3.0
	lfo.freq_hz = 5.0
	lfo.fade_in_sec = 0.0
	lfo.fade_out_sec = 0.0
	lfo.start_sec = 0.0
	lfo.end_sec = 2.0
	gcurve.lfo = lfo
	e.project_edited(true)
	b = e.render_preview_range(0.0, 2.0)
	var lw := 0.0
	var lo := 9.0
	var hi := 0.0
	for i in range(0, 2 * sr, 97):
		var t := float(i) / sr
		lw = maxf(lw, absf(b[i].x - 0.5 * db_to_linear(clip.chain.sample(gcurve, t))))
		lo = minf(lo, b[i].x)
		hi = maxf(hi, b[i].x)
	check(lw < 0.006 and hi > lo * 2.5, "gain LFO (5 Hz, -18..-3 dB): follows AWChain.sample (worst %.5f), swing %.3f..%.3f" % [lw, lo, hi])
	lfo.freq_hz = 9.0 # no key change, so the chain revision does not move: the plan must still refresh
	e.project_edited(false)
	b = e.render_preview_range(0.0, 2.0)
	var lw2 := 0.0
	for i in range(0, 2 * sr, 97):
		lw2 = maxf(lw2, absf(b[i].x - 0.5 * db_to_linear(clip.chain.sample(gcurve, float(i) / sr))))
	check(lw2 < 0.006, "LFO edit alone refreshes the plan (worst error %.5f)" % lw2)

	# 5. Editing keys refreshes the plan.
	gcurve.lfo = null
	var keys := clip.chain.get_keys(gcurve)
	for k in keys:
		k["v"] = clip.chain.to_norm(gcurve, -20.0)
	clip.chain.set_keys(gcurve, keys)
	e.project_edited(false)
	b = e.render_preview_range(0.0, 1.0)
	check(absf(b[1000].x - 0.5 * db_to_linear(-20.0)) < 0.003, "key edit: level %.4f (want %.4f)" % [b[1000].x, 0.5 * db_to_linear(-20.0)])

	# 6. Output volume: static, then a curve over project time.
	clip.chain.curves.clear()
	proj.master_chain.effects[0].params["volume_db"] = -6.0
	e.project_edited(false)
	b = e.render_preview_range(0.0, 1.0)
	check(absf(b[1000].x - 0.5 * db_to_linear(-6.0)) < 0.002, "Output volume -6 dB: %.4f" % b[1000].x)
	var mout := proj.master_chain.effects[0]
	AWProject._curve(proj.master_chain, mout.id, "volume_db", Color.WHITE, [K.call(0.0, 0.0, LIN), K.call(2.0, -24.0, LIN)])
	var mcurve := proj.master_chain.get_curve(mout.id, "volume_db")
	e.project_edited(true)
	b = e.render_preview_range(0.0, 2.0)
	var mw := 0.0
	for t: float in [0.1, 0.5, 1.0, 1.5, 1.9]:
		mw = maxf(mw, absf(b[int(t * sr)].x - 0.5 * db_to_linear(proj.master_chain.sample(mcurve, t))))
	check(mw < 0.004, "Output volume curve 0 to -24 dB over project time: worst error %.5f" % mw)

	# 7. A fade to -60 dB is true silence.
	proj.master_chain.curves.clear()
	mout.params["volume_db"] = -60.0
	e.project_edited(false)
	b = e.render_preview_range(0.0, 0.5)
	check(nonzero_range(b, 0.00001).x == -1, "Output volume at -60 dB is silent")
	mout.params["volume_db"] = 0.0

	# 8. Rebuild cost with the demo's curves (4 curves incl. pitch), first build and cached rebuild.
	var demo := AWProject.create_demo()
	for c in demo.clips:
		c.source_path = dc
	var e3 := AWEngine.new()
	e3.set_project(demo)
	var t0 := Time.get_ticks_usec()
	e3._rebuild_plan()
	var first_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	e3._rebuild_plan()
	var cached_ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(first_ms < 250.0 and cached_ms < 25.0, "demo plan rebuild: %.1f ms first (decode + curve tables), %.1f ms cached" % [first_ms, cached_ms])


static func sampler_tests(_screen: AWMainScreen) -> void:
	var K := AWProject._k
	var LIN := AWCurve.HandleMode.LINEAR
	var BAL := AWCurve.HandleMode.BALANCED
	var native := AWSampler.native()
	check(native != null, "native curve sampler available")
	if native == null:
		return

	# 1. Native sampling equals the GDScript reference for every scale, LFO shape and unit.
	var ch := AWChain.create(AWEffectLibrary.CLIP_SOURCE)
	var lp := AWEffect.create("Low Pass", ch.new_effect_id())
	var rv := AWEffect.create("Reverb", ch.new_effect_id())
	ch.effects.append_array([lp, rv])
	var src := ch.effects[0]
	AWProject._curve(ch, src.id, "gain_db", Color.WHITE, [K.call(0.0, -20.0, BAL), K.call(1.0, 3.0, BAL), K.call(3.0, -45.0, BAL)]) # FADER
	AWProject._curve(ch, lp.id, "cutoff_hz", Color.WHITE, [K.call(0.0, 200.0, BAL), K.call(2.0, 9000.0, BAL), K.call(3.0, 400.0, BAL)]) # LOG
	AWProject._curve(ch, rv.id, "wet", Color.WHITE, [K.call(0.5, 0.2, LIN), K.call(2.5, 0.9, LIN)]) # LINEAR, starts after t=0
	AWProject._curve(ch, src.id, "pitch_semitones", Color.WHITE, [K.call(0.0, 0.0, LIN), K.call(3.0, -7.0, LIN)])
	var worst := 0.0
	var cases := 0
	for curve in ch.curves:
		var lfo_options: Array = [null]
		for shape in 5:
			var l := AWLfo.new()
			l.shape = shape
			l.freq_hz = [0.7, 3.0, 11.0, 20.0, 5.0][shape]
			l.start_sec = 0.4
			l.end_sec = 2.7
			l.fade_in_sec = 0.3
			l.fade_out_sec = 0.6
			l.random_seed = shape * 7 + 1
			l.freq_accel = [0.0, 2.5, -1.2, 4.0, -6.0][shape]
			l.fade_smoothing = [0.0, 0.5, 1.0, 0.3, 0.8][shape]
			var r := ch.curve_range(curve)
			l.min_value = lerpf(r.x, r.y, 0.15)
			l.max_value = lerpf(r.x, r.y, 0.85)
			lfo_options.append(l)
		# The newer parameters: Relative mode, Phase, Jitter, Glide, Decay (with Accel too).
		for shape in 5:
			for variant in 2:
				var l2 := AWLfo.new()
				l2.shape = shape
				l2.freq_hz = [1.3, 6.0, 9.0, 2.5, 7.0][shape]
				l2.start_sec = 0.2
				l2.end_sec = 2.9
				l2.fade_in_sec = 0.2
				l2.fade_out_sec = 0.3
				l2.random_seed = shape * 3 + 5 + variant
				l2.freq_accel = [0.0, 1.5, -0.8, 0.0, 2.0][shape] * variant
				l2.mode = (shape + variant) % 2
				l2.depth = [0.25, 0.1, 0.4, 0.05, 0.3][shape]
				l2.phase_deg = [0.0, 90.0, 180.0, 270.0, 45.0][shape]
				l2.jitter_rate = [0.5, 1.0, 0.3, 0.8, 1.0][shape]
				l2.jitter_depth = [0.4, 0.0, 1.0, 0.6, 0.9][shape]
				l2.glide = [0.5, 0.3, 0.7, 1.0, 0.6][shape] * variant
				l2.decay_sec = [0.0, 0.8, 0.0, 1.5, 0.5][shape]
				l2.sustain = [1.0, 0.3, 0.6, 0.0, 0.5][shape]
				var r2 := ch.curve_range(curve)
				l2.min_value = lerpf(r2.x, r2.y, 0.2)
				l2.max_value = lerpf(r2.x, r2.y, 0.7)
				lfo_options.append(l2)
		for l in lfo_options:
			curve.lfo = l
			for unit in [AWSampler.VALUE, AWSampler.NORM, AWSampler.BASE_NORM]:
				var got := AWSampler.values(ch, curve, -0.2, 0.0137, 260, unit)
				for i in got.size():
					var want := AWSampler._one(ch, curve, -0.2 + i * 0.0137, unit)
					var tol := 1e-5 * maxf(1.0, absf(want))
					worst = maxf(worst, absf(got[i] - want) / maxf(1.0, absf(want)))
					if absf(got[i] - want) > tol * 5.0:
						check(false, "native != reference: %s unit %d lfo %s t=%.3f got %f want %f" % [curve.param, unit, str(l.shape) if l else "none", -0.2 + i * 0.0137, got[i], want])
						return
				cases += 1
	check(true, "native sampler equals the GDScript reference: %d curve/LFO/unit combinations, worst relative error %.8f" % [cases, worst])
	lfo_param_tests(ch)
	# Gain / rate units, and sampling at arbitrary times.
	var gcurve := ch.get_curve(src.id, "gain_db")
	gcurve.lfo = null
	var gg := AWSampler.values(ch, gcurve, 0.0, 0.01, 300, AWSampler.GAIN)
	var gok := true
	for i in gg.size():
		var db := ch.sample(gcurve, i * 0.01)
		gok = gok and absf(gg[i] - (0.0 if db <= -59.9 else db_to_linear(db))) < 1e-5
	check(gok, "gain unit: dB converted to linear (silence at the bottom of the range)")
	var times := PackedFloat64Array([0.0, 0.3, 1.1, 2.9, 5.0, -1.0])
	var at := AWSampler.values_at(ch, gcurve, times, AWSampler.VALUE)
	var aok := true
	for i in times.size():
		aok = aok and absf(at[i] - ch.sample(gcurve, times[i])) < 1e-4
	check(aok, "sampling at arbitrary times (also before the first and after the last key)")

	# 2. Pitch warp: an LFO edit alone changes the timing (no key edit); the cache must notice.
	var clip := AWClip.create("w", 0.0, 3.0, 0, Color.RED)
	AWProject._curve(clip.chain, clip.chain.effects[0].id, "pitch_semitones", Color.WHITE, [K.call(0.0, 0.0, LIN), K.call(3.0, 0.0, LIN)])
	var pcurve := clip.chain.get_curve(clip.chain.effects[0].id, "pitch_semitones")
	var len0 := clip.play_length()
	var lf := AWLfo.new()
	lf.min_value = -12.0
	lf.max_value = 0.0
	lf.freq_hz = 2.0
	lf.fade_in_sec = 0.0
	lf.fade_out_sec = 0.0
	lf.start_sec = 0.0
	lf.end_sec = 3.0
	pcurve.lfo = lf
	clip.invalidate_warp()
	var len1 := clip.play_length()
	lf.min_value = -24.0
	clip.invalidate_warp()
	var len2 := clip.play_length()
	var calls0 := AWSampler.calls
	clip.invalidate_warp()
	var len3 := clip.play_length()
	check(absf(len0 - 3.0) < 0.001 and len1 > len0 + 0.2 and len2 > len1 + 0.1 and len3 == len2 and AWSampler.calls == calls0,
		"pitch LFO changes the clip length with no key edit (%.3f -> %.3f -> %.3f s); an unchanged warp is not rebuilt" % [len0, len1, len2])

	# 3. Plan rebuild cost: 8 layered 20 s clips, 3 curves each, all with a 20 Hz LFO.
	var e := AWEngine.new()
	var proj := AWProject.new()
	proj.master_chain = AWChain.create(AWEffectLibrary.MASTER_OUTPUT)
	var clips: Array[AWClip] = []
	for r in 8:
		var c := AWClip.create("c%d" % r, 0.0, 20.0, r, Color.RED)
		var s0 := c.chain.effects[0]
		AWProject._curve(c.chain, s0.id, "pitch_semitones", Color.WHITE, [K.call(0.0, 0.0, LIN), K.call(20.0, 0.0, LIN)])
		AWProject._curve(c.chain, s0.id, "gain_db", Color.WHITE, [K.call(0.0, -6.0, LIN), K.call(20.0, -6.0, LIN)])
		AWProject._curve(c.chain, s0.id, "pan", Color.WHITE, [K.call(0.0, 0.0, LIN), K.call(20.0, 0.0, LIN)])
		for curve in c.chain.curves:
			var l2 := AWLfo.new()
			l2.freq_hz = 20.0
			l2.fade_in_sec = 0.0
			l2.fade_out_sec = 0.0
			l2.start_sec = 0.0
			l2.end_sec = 20.0
			var rg := c.chain.curve_range(curve)
			l2.min_value = lerpf(rg.x, rg.y, 0.4)
			l2.max_value = lerpf(rg.x, rg.y, 0.6)
			curve.lfo = l2
		clips.append(c)
	proj.clips.assign(clips)
	e.set_project(proj)
	var t0 := Time.get_ticks_usec()
	for c in clips:
		c.play_length()
	var warp_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	e._rebuild_plan()
	var full_ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(full_ms < 400.0 and warp_ms < 400.0, "8 clips x 20 s x 3 curves with 20 Hz LFOs: warps %.0f ms, full plan %.0f ms (was seconds in GDScript)" % [warp_ms, full_ms])

	# 4. Editing one curve re-samples only that curve.
	var edit_curve := clips[3].chain.curves[1]
	var calls1 := AWSampler.calls
	t0 = Time.get_ticks_usec()
	e._rebuild_plan()
	var idle_ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(AWSampler.calls == calls1, "unchanged project: no curve is re-sampled (%.1f ms)" % idle_ms)
	edit_curve.lfo.freq_hz = 17.0
	calls1 = AWSampler.calls
	t0 = Time.get_ticks_usec()
	e._rebuild_plan()
	var edit_ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(AWSampler.calls == calls1 + 1 and edit_ms < 60.0, "LFO frequency edit re-samples only that curve: %d sampling call, %.1f ms" % [AWSampler.calls - calls1, edit_ms])
	var ek := clips[5].chain.get_keys(clips[5].chain.curves[2])
	ek[0]["v"] = 0.9
	calls1 = AWSampler.calls
	clips[5].chain.set_keys(clips[5].chain.curves[2], ek)
	e._rebuild_plan()
	check(AWSampler.calls == calls1 + 1, "key edit re-samples only that curve, not the clip's other curves (%d call)" % [AWSampler.calls - calls1])


static func _measured_db(core: Object, hz: float, effects: Array) -> float:
	return 20.0 * log(maxf(_through(core, hz, effects), 1e-9) / 0.5) / log(10.0)


## Screenshot with the Audio Effect dock showing the panel.
static func _panel_shot(tree: SceneTree, _d: AWDocument, _ch: AWChain, _e: AWEffect, name: String) -> void:
	await frames(tree, 3)
	await shot(tree, name)


static func panel_tests(screen: AWMainScreen) -> void:
	var tree := screen.get_tree()
	var d := screen.doc
	var ch := d.project.clips[3].chain
	var sr := AudioServer.get_mix_rate()

	# The drawn response is the engine's response.
	check(absf(AWFilterResponse.lowpass_db(1000.0, 1000.0, 0.5, sr) + 3.01) < 0.05, "response: low pass is -3 dB at the cutoff")
	check(AWFilterResponse.lowpass_db(10000.0, 1000.0, 0.5, sr) < -35.0, "response: 12 dB/oct, 10x the cutoff is below -35 dB")
	check(absf(AWFilterResponse.q_to_resonance(AWFilterResponse.resonance_to_q(0.8)) - 0.8) < 0.001, "response: resonance <-> Q round trip")
	var gains := PackedFloat32Array([0, 0, 0, 6, 0, 0])
	check(absf(AWFilterResponse.eq_db(1000.0, gains, sr) - 6.0) < 0.01, "response: EQ +6 dB reads +6 dB at its band")
	var e := AWEngine.new()
	e.set_project(AWProject.new())
	if e.core != null:
		var core: Object = e.core
		core.call("set_sample_rate", float(sr))
		var worst := 0.0
		for hz: float in [300.0, 800.0, 1500.0, 3000.0]:
			var want := AWFilterResponse.lowpass_db(hz, 1000.0, 0.8, sr)
			worst = maxf(worst, absf(_measured_db(core, hz, [_fx(1, [1000.0, 0.8])]) - want))
		check(worst < 0.5, "response vs engine: low pass within %.2f dB" % worst)
		for kind: Array in [["High Pass", 2, [300.0, 800.0, 1500.0, 3000.0]], ["Band Pass", 3, [300.0, 800.0, 1500.0, 3000.0]]]:
			worst = 0.0
			for hz: float in kind[2]:
				worst = maxf(worst, absf(_measured_db(core, hz, [_fx(kind[1], [1000.0, 0.8])]) - AWFilterResponse.filter_db(kind[0], hz, 1000.0, 0.8, sr)))
			check(worst < 0.5, "response vs engine: %s within %.2f dB" % [kind[0], worst])
		var g2 := [3.0, -4.0, 5.0, 8.0, -6.0, 2.0]
		var g2p := PackedFloat32Array(g2)
		worst = 0.0
		for hz: float in [60.0, 200.0, 640.0, 2000.0, 6000.0]:
			worst = maxf(worst, absf(_measured_db(core, hz, [_fx(4, g2)]) - AWFilterResponse.eq_db(hz, g2p, sr)))
		check(worst < 0.5, "response vs engine: EQ within %.2f dB" % worst)

	if e.core != null:
		var ids: PackedInt32Array = e.core.call("get_effect_types")
		var lib_ids := PackedInt32Array()
		for t: String in AWEffectLibrary.EFFECTS:
			if AWEffectLibrary.engine_id(t) != 0:
				lib_ids.append(AWEffectLibrary.engine_id(t))
		var a := Array(ids)
		var b := Array(lib_ids)
		a.sort()
		b.sort()
		check(a == b, "library engine ids match the engine's effect types %s" % str(a))
		check(AWEffectLibrary.engine_keys("EQ").size() == 6 and AWEffectLibrary.engine_keys("Low Pass") == ["cutoff_hz", "resonance"], "engine parameter order comes from the schema")
	check(AWPanelRegistry.has_panel("Low Pass") and AWPanelRegistry.has_panel("EQ") and AWPanelRegistry.has_panel("High Pass") and AWPanelRegistry.has_panel("Band Pass") and AWPanelRegistry.has_panel("Amplify") and AWPanelRegistry.has_panel("Reverb") and AWPanelRegistry.has_panel("Gate"), "registry: a panel for every engine-capable effect")
	AWPanelRegistry.suppressed = PackedStringArray(["Reverb"])
	check(AWPanelRegistry.create("Reverb") == null, "registry: no panel falls back to the generic rows")
	AWPanelRegistry.suppressed = PackedStringArray()

	# --- Low Pass ---
	var undo_base := 0
	var lp := d.add_effect(ch, "Low Pass")
	undo_base += 1
	await frames(tree, 4)
	var card: AWEffectCard = screen.chain_panel._cards.back()
	check(card.effect == lp and card.panel is AWFilterPanel and card.panel.compact and card.panel.plot.mini, "Low Pass card uses the compact panel")
	check(card.rows.is_empty() and card.panel.cutoff_knob != null and card.panel.plot.response.size() > 0, "compact card: plot and knobs, no generic rows")
	d.open_detail(ch, lp)
	await frames(tree, 2)
	if OS.get_environment("AW_SHOTS") != "":
		d.set_param(lp, "resonance", 0.72)
		await _panel_shot(tree, d, ch, lp, "aw_panel_lowpass.png")
		d.undo()
	var host := screen.detail_panel
	var lpp := host.panel as AWFilterPanel
	check(lpp != null and lpp.effect == lp and host._title.text == "Low Pass", "detail dock shows the Low Pass panel")
	lpp.plot.size = Vector2(420, 260)
	lpp.refresh()
	check(lpp.plot.handles.size() == 1 and absf(lpp.plot.handles[0].f - 2000.0) < 0.5, "handle sits at the 2 kHz cutoff")
	var h0: Dictionary = lpp.plot.handles[0]
	var from := Vector2(lpp.plot.x_of(h0.f), lpp.plot.y_of(h0.db))
	var to := Vector2(lpp.plot.x_of(4000.0), lpp.plot.y_of(12.0))
	drag(lpp.plot, from, to)
	check(absf(lp.get_param("cutoff_hz") - 4000.0) < 120.0, "dragging the handle sets the cutoff (%.0f Hz)" % lp.get_param("cutoff_hz"))
	check(lp.get_param("resonance") > 0.7, "dragging the handle up raises resonance (%.2f)" % lp.get_param("resonance"))
	d.undo()
	check(lp.get_param("cutoff_hz") == 2000.0 and lp.get_param("resonance") == 0.5, "one undo restores cutoff and resonance together")
	var k := lpp.cutoff_knob
	k.size = k.custom_minimum_size
	var c0 := lp.get_param("cutoff_hz")
	click(k, Vector2(40, 40))
	move(k, Vector2(40, -20))
	click(k, Vector2(40, -20), MOUSE_BUTTON_LEFT, false)
	var up := lp.get_param("cutoff_hz")
	check(up > c0 * 2.0, "knob drag up raises the cutoff on a log scale (%.0f Hz)" % up)
	d.undo()
	click(k, Vector2(40, 40))
	move(k, Vector2(40, -20), true)
	click(k, Vector2(40, -20), MOUSE_BUTTON_LEFT, false)
	var fine := lp.get_param("cutoff_hz")
	check(fine > c0 and fine < up, "Shift drags finely (%.0f Hz vs %.0f Hz)" % [fine, up])
	d.undo()
	d.set_param(lp, "cutoff_hz", 6000.0)
	click(k, Vector2(40, 40), MOUSE_BUTTON_LEFT, true, false, false, true)
	click(k, Vector2(40, 40), MOUSE_BUTTON_LEFT, false)
	check(lp.get_param("cutoff_hz") == 2000.0, "Ctrl+click resets to the default")
	d.undo(); d.undo()
	# Typed entry: double-click opens a field; "3k" sets 3000 Hz, Esc cancels.
	click(k, Vector2(40, 40), MOUSE_BUTTON_LEFT, true, true)
	click(k, Vector2(40, 40), MOUSE_BUTTON_LEFT, false)
	check(k._entry != null and k._entry.visible and k._entry.text == "2000", "double-click opens the entry field with the current value")
	k._entry.text = "3k"
	k._entry.text_submitted.emit("3k")
	check(lp.get_param("cutoff_hz") == 3000.0 and not k._entry.visible, "typing 3k sets 3000 Hz and closes the field")
	check(is_nan(k.binding.parse_text("abc")) and k.binding.parse_text("-6 dB") == -6.0 and k.binding.parse_text(".5") == 0.5, "entry parsing: numbers, units and junk")
	d.undo()
	check(lp.get_param("cutoff_hz") == 2000.0, "the typed value is one undo step")
	check(lp.get_param("cutoff_hz") == 2000.0, "undo walks back through the knob edits")

	# A curve takes over the knob; the other axis of the handle still works.
	var cc := d.make_curve(ch, lp, "cutoff_hz")
	await frames(tree, 2)
	lpp.refresh()
	check(k.binding.has_curve(), "cutoff knob knows it is driven by a curve")
	var before := lp.get_param("cutoff_hz")
	click(k, Vector2(40, 40))
	move(k, Vector2(40, -20))
	click(k, Vector2(40, -20), MOUSE_BUTTON_LEFT, false)
	check(lp.get_param("cutoff_hz") == before and d.active_curve == cc, "dragging a driven knob selects its curve instead of editing")
	var hd: Dictionary = lpp.plot.handles[0]
	check(hd.driven, "the handle shows it is driven")
	var r0 := lp.get_param("resonance")
	drag(lpp.plot, Vector2(lpp.plot.x_of(hd.f), lpp.plot.y_of(hd.db)), Vector2(lpp.plot.x_of(hd.f), lpp.plot.y_of(hd.db - 10.0)))
	check(lp.get_param("cutoff_hz") == before and lp.get_param("resonance") != r0, "driven cutoff stays put while resonance is dragged")
	d.undo()
	d.remove_curve(ch, cc)
	k.binding.on_menu(1)
	check(k.binding.has_curve(), "menu > Make Curve works from a kit control")
	d.undo()
	d.remove_effect(ch, lp)
	await frames(tree, 2)
	check(d.detail_effect == null and host.panel == null, "removing the effect closes its panel")

	# --- High Pass, Band Pass, Amplify ---
	for t: String in ["High Pass", "Band Pass"]:
		var fe := d.add_effect(ch, t)
		await frames(tree, 3)
		var fcard: AWEffectCard = screen.chain_panel._cards.back()
		check(fcard.panel is AWFilterPanel and fcard.rows.is_empty() and fcard.panel.plot.response.size() > 0, "%s card is compact with a response plot" % t)
		d.open_detail(ch, fe)
		await frames(tree, 2)
		var fp := host.panel as AWFilterPanel
		fp.plot.size = Vector2(420, 260)
		fp.refresh()
		var fh: Dictionary = fp.plot.handles[0]
		var fr0 := fe.get_param("resonance")
		var fc0 := fe.get_param("cutoff_hz")
		drag(fp.plot, Vector2(fp.plot.x_of(fh.f), fp.plot.y_of(fh.db)), Vector2(fp.plot.x_of(500.0), fp.plot.y_of(fh.db + 8.0)))
		check(absf(fe.get_param("cutoff_hz") - 500.0) < 20.0 and fe.get_param("resonance") > fr0, "%s: handle drag sets cutoff and raises resonance" % t)
		d.undo()
		check(fe.get_param("cutoff_hz") == fc0 and fe.get_param("resonance") == fr0, "%s: one undo restores both" % t)
		d.remove_effect(ch, fe)
		await frames(tree, 2)
	var amp := d.add_effect(ch, "Amplify")
	await frames(tree, 3)
	var acard: AWEffectCard = screen.chain_panel._cards.back()
	check(acard.panel is AWAmplifyPanel and acard.rows.is_empty(), "Amplify card is a compact volume knob")
	d.open_detail(ch, amp)
	await frames(tree, 2)
	var ap := host.panel as AWAmplifyPanel
	ap.knob.size = ap.knob.custom_minimum_size
	click(ap.knob, Vector2(60, 60))
	move(ap.knob, Vector2(60, 20))
	click(ap.knob, Vector2(60, 20), MOUSE_BUTTON_LEFT, false)
	check(amp.get_param("volume_db") > 0.0, "Amplify knob raises the volume (%.1f dB)" % amp.get_param("volume_db"))
	d.undo()
	check(amp.get_param("volume_db") == 0.0, "undo restores the volume")
	d.remove_effect(ch, amp)
	await frames(tree, 2)

	# --- Distortion, Delay, Compressor, Limiter ---
	var plot_cases := [["Distortion", 4], ["Delay", 4], ["Compressor", 6], ["Limiter", 3], ["Reverb", 5], ["Chorus", 4], ["Phaser", 3], ["Stereo Enhance", 3], ["Gate", 6]]
	for pc: Array in plot_cases:
		var t: String = pc[0]
		var pe := d.add_effect(ch, t)
		await frames(tree, 3)
		var pcard: AWEffectCard = screen.chain_panel._cards.back()
		check(pcard.panel is AWPlotKnobPanel and pcard.panel.compact and pcard.rows.is_empty() and pcard.panel.knobs.size() == pc[1], "%s card is compact: plot and %d knobs" % [t, pc[1]])
		d.open_detail(ch, pe)
		await frames(tree, 2)
		var pp := host.panel as AWPlotKnobPanel
		check(pp != null and not pp.compact and (pp.plot_control() != null) == (t != "Chorus" and t != "Phaser" and t != "Stereo Enhance"), "%s dock panel %s a plot" % [t, "has no" if (t == "Chorus" or t == "Phaser" or t == "Stereo Enhance") else "has"])
		if OS.get_environment("AW_SHOTS") != "" and (t == "Compressor" or t == "Delay" or t == "Reverb" or t == "Gate"):
			(screen.chain_panel._cards_box.get_parent() as ScrollContainer).scroll_horizontal = 5000
			await _panel_shot(tree, d, ch, pe, "aw_panel_%s.png" % t.to_lower())
		var key: String = AWEffectLibrary.param_schema(t).keys()[0]
		var kbefore := pe.get_param(key)
		var pk := pp.knobs[0]
		pk.size = pk.custom_minimum_size
		click(pk, Vector2(40, 40))
		move(pk, Vector2(40, -30))
		click(pk, Vector2(40, -30), MOUSE_BUTTON_LEFT, false)
		check(pe.get_param(key) != kbefore, "%s: the first knob edits %s (%.2f)" % [t, key, pe.get_param(key)])
		d.undo()
		check(pe.get_param(key) == kbefore, "%s: knob drag is one undo step" % t)
		if t == "Gate":
			var gp := pp.plot_control() as AWTransferPlot
			gp.size = Vector2(400, 260)
			pp.refresh()
			drag(gp, Vector2(gp.px(gp.handle.x), gp.py(gp.handle.y)), Vector2(gp.px(-30.0), gp.py(-30.0)))
			check(absf(pe.get_param("threshold_db") + 30.0) < 1.5, "Gate: dragging the handle sets the threshold (%.1f dB)" % pe.get_param("threshold_db"))
			d.undo()
		if t == "Reverb":
			var dp := pp.plot_control() as AWDecayPlot
			check(AWDecayPlot.rt60(1.0, 0.0) > AWDecayPlot.rt60(0.0, 0.0) * 5.0 and AWDecayPlot.rt60(0.8, 1.0, true) < AWDecayPlot.rt60(0.8, 1.0), "Reverb: bigger room = longer RT60, damping shortens the highs (%.1f s / %.1f s)" % [AWDecayPlot.rt60(1.0, 0.0), AWDecayPlot.rt60(0.0, 0.0)])
			check(dp != null and is_equal_approx(dp.room, pe.get_param("room_size")), "Reverb: the plot follows the Room knob")
		if t == "Compressor" or t == "Limiter":
			var tp := pp.plot_control() as AWTransferPlot
			tp.size = Vector2(400, 260)
			pp.refresh()
			var hx: float = tp.handle.x
			var hy: float = tp.handle.y
			var hfrom := Vector2(tp.px(hx), tp.py(hy))
			if t == "Compressor":
				drag(tp, hfrom, Vector2(tp.px(-30.0), tp.py(hy)))
				check(absf(pe.get_param("threshold") + 30.0) < 1.0, "Compressor: dragging the handle sets the threshold (%.1f dB)" % pe.get_param("threshold"))
			else:
				drag(tp, hfrom, Vector2(hfrom.x, tp.py(-12.0)))
				check(absf(pe.get_param("ceiling_db") + 12.0) < 1.0, "Limiter: dragging the handle sets the ceiling (%.1f dB)" % pe.get_param("ceiling_db"))
			d.undo()
		d.remove_effect(ch, pe)
		await frames(tree, 2)

	# --- EQ ---
	var eq := d.add_effect(ch, "EQ")
	await frames(tree, 4)
	var eq_card: AWEffectCard = screen.chain_panel._cards.back()
	check(eq_card.panel is AWEQPanel and eq_card.panel.knobs.size() == 6 and eq_card.rows.is_empty(), "EQ card is compact: preview plus six knobs")
	d.open_detail(ch, eq)
	await frames(tree, 2)
	if OS.get_environment("AW_SHOTS") != "":
		(screen.chain_panel._cards_box.get_parent() as ScrollContainer).scroll_horizontal = 5000
		await _panel_shot(tree, d, ch, eq, "aw_panel_eq.png")
	var ep := host.panel as AWEQPanel
	check(ep != null and ep.knobs.size() == 6 and ep.plot.handles.size() == 6, "EQ panel has six knobs and six handles")
	check(ep.knobs[0].bipolar and ep.knobs[0].view_min == -18.0, "EQ knobs are bipolar over -18..+18 dB")
	ep.plot.size = Vector2(500, 200)
	ep.refresh()
	var hp := Vector2(ep.plot.x_of(1000.0), ep.plot.y_of(0.0))
	drag(ep.plot, hp, Vector2(hp.x + 80.0, ep.plot.y_of(9.0)))
	var g3 := eq.get_param("band_db/1000_hz")
	check(absf(g3 - 9.0) < 0.6 and ep.selected == 3, "dragging a band handle sets only its gain (%.1f dB)" % g3)
	check(eq.get_param("band_db/320_hz") == 0.0, "other bands are untouched")
	check(absf(ep.plot.response[ep.plot.response.size() - 1] - AWFilterResponse.eq_db(20000.0, ep._gains(), sr)) < 0.01, "plot shows the live response")
	d.undo()
	check(eq.get_param("band_db/1000_hz") == 0.0, "undo restores the band")
	var k1 := ep.knobs[1]
	k1.size = k1.custom_minimum_size
	click(k1, Vector2(40, 40))
	move(k1, Vector2(40, -20))
	click(k1, Vector2(40, -20), MOUSE_BUTTON_LEFT, false)
	var kg := eq.get_param("band_db/100_hz")
	check(kg > 4.0 and kg <= 18.0 and ep.selected == 1, "knob drag raises its band and selects it (%.1f dB)" % kg)
	click(k1, Vector2(40, 40), MOUSE_BUTTON_LEFT, true, false, false, true)
	click(k1, Vector2(40, 40), MOUSE_BUTTON_LEFT, false)
	check(eq.get_param("band_db/100_hz") == 0.0, "Ctrl+click resets a band knob")
	var ec := d.make_curve(ch, eq, "band_db/320_hz")
	await frames(tree, 2)
	ep.refresh()
	check(ep.knobs[2].binding.has_curve() and ep.plot.handles[2].driven, "a band with a curve is shown as driven")
	d.undo()
	d.remove_effect(ch, eq)
	await frames(tree, 2)
	check(not ch.effects.has(eq), "panel tests leave the chain as they found it")
	d.open_detail(null, null)


## Reads back a PCM/float WAV written by the exporter: {rate, bits, channels, frames, samples (interleaved floats)}.
static func _read_wav(path: String) -> Dictionary:
	var b := FileAccess.get_file_as_bytes(path)
	var out := {"ok": false}
	if b.size() < 44 or b.slice(0, 4).get_string_from_ascii() != "RIFF" or b.slice(8, 12).get_string_from_ascii() != "WAVE":
		return out
	var pos := 12
	var fmt_tag := 0
	var data_at := -1
	var data_len := 0
	while pos + 8 <= b.size():
		var id := b.slice(pos, pos + 4).get_string_from_ascii()
		var len := b.decode_u32(pos + 4)
		if id == "fmt ":
			fmt_tag = b.decode_u16(pos + 8)
			out["channels"] = b.decode_u16(pos + 10)
			out["rate"] = b.decode_u32(pos + 12)
			out["bits"] = b.decode_u16(pos + 22)
		elif id == "data":
			data_at = pos + 8
			data_len = len
			break
		pos += 8 + len
	if data_at < 0:
		return out
	var raw := b.slice(data_at, data_at + data_len)
	var samples := PackedFloat32Array()
	if out.bits == 32 and fmt_tag == 3:
		samples = raw.to_float32_array()
	elif out.bits == 16 and fmt_tag == 1:
		samples.resize(raw.size() / 2)
		for i in samples.size():
			samples[i] = float(raw.decode_s16(i * 2)) / 32768.0
	else:
		return out
	out["ok"] = true
	out["format_tag"] = fmt_tag
	out["samples"] = samples
	out["frames"] = samples.size() / 2
	out["file_bytes"] = b.size()
	return out


## Relative error energy between decoded interleaved samples and the render (clamped to full scale).
## Decodes a WAV with Godot's own loader and playback, as interleaved stereo floats.
static func _godot_wav_decode(path: String, total: int, options := {}) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var st := AudioStreamWAV.load_from_file(path, options)
	if st == null:
		return out
	var pb := st.instantiate_playback()
	pb.start(0.0)
	var frames := PackedVector2Array()
	var guard := 0
	while frames.size() < total and guard < 4000:
		var got: PackedVector2Array = pb.mix_audio(1.0, mini(4096, total - frames.size()))
		if got.is_empty():
			break
		frames.append_array(got)
		guard += 1
	out.resize(frames.size() * 2)
	for i in frames.size():
		out[i * 2] = frames[i].x
		out[i * 2 + 1] = frames[i].y
	return out


static func _rel_error(samples: PackedFloat32Array, ref: PackedVector2Array) -> float:
	var err := 0.0
	var energy := 0.0
	for i in mini(ref.size(), samples.size() / 2):
		var rx := clampf(ref[i].x, -1.0, 1.0)
		var ry := clampf(ref[i].y, -1.0, 1.0)
		err += (samples[i * 2] - rx) * (samples[i * 2] - rx) + (samples[i * 2 + 1] - ry) * (samples[i * 2 + 1] - ry)
		energy += rx * rx + ry * ry
	return err / maxf(energy, 1e-12)


static func export_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	if screen.engine.core == null:
		return
	var rate := int(AudioServer.get_mix_rate())
	var path := "user://aw_export_test.wav"
	var abs_path := ProjectSettings.globalize_path(path)
	DirAccess.remove_absolute(abs_path)
	# Its own project with real sound: a 220 Hz sine through a Reverb, so there is a tail to compare.
	var sine := "/tmp/aw_export_sine.wav"
	write_wav(sine, 1.5, func(i: int, rt: int) -> Vector2i:
		var v := int(12000.0 * sin(TAU * 220.0 * i / rt))
		return Vector2i(v, v))
	var ep := AWProject.new()
	var sclip := AWClip.create("sine", 0.0, 1.5, 0, Color.RED)
	sclip.source_path = sine
	sclip.chain.effects.append(AWEffect.create("Reverb", sclip.chain.new_effect_id()))
	ep.clips.append(sclip)
	var ref_engine := AWEngine.new()
	ref_engine.set_project(ep)
	var length := ep.export_end_resolved()
	var total := int(round(length * rate))
	var ref := ref_engine.render_preview_range(0.0, length)

	# 32-bit float: the file is exactly the preview render, tail and chunk boundaries included.
	var ex := AWExporter.new()
	var fractions: Array[float] = []
	ex.progress.connect(func(f: float) -> void: fractions.append(f))
	var r: Dictionary = await ex.run(ep, abs_path, 32)
	check(r.ok and absi(int(r.frames) - total) <= 1, "export: 32-bit run succeeds (%d frames, wanted %d)" % [int(r.frames), total])
	check(FileAccess.file_exists(abs_path) and not FileAccess.file_exists(abs_path + ".part"), "export: the file exists and no .part is left")
	var w := _read_wav(abs_path)
	check(w.ok and w.rate == rate and w.channels == 2 and w.bits == 32 and w.format_tag == 3, "export: header is stereo 32-bit float at the mix rate (%d Hz)" % rate)
	check(w.ok and int(w.file_bytes) == int(r.bytes) and absi(int(w.frames) - total) <= 1, "export: file size matches the report (%d bytes)" % int(r.bytes))
	var worst := 0.0
	var peak := 0.0
	if w.ok:
		var smp: PackedFloat32Array = w.samples
		var n := mini(ref.size(), int(w.frames))
		for i in n:
			worst = maxf(worst, maxf(absf(smp[i * 2] - ref[i].x), absf(smp[i * 2 + 1] - ref[i].y)))
			peak = maxf(peak, maxf(absf(ref[i].x), absf(ref[i].y)))
	check(worst < 1e-6, "export: bake equals the preview render sample for sample (worst %.2e)" % worst)
	check(length > 1.5 and fractions.size() >= 2 and is_equal_approx(fractions.back(), 1.0), "export: progress reported in chunks (%d steps)" % fractions.size())
	check(absf(float(r.peak_db) - 20.0 * log(peak) / log(10.0)) < 0.01, "export: reported peak %.2f dBFS matches the render" % float(r.peak_db))

	# The tail rings on past the last clip (the demo holds a Reverb).
	var last_clip_end := int(ep.last_clip_end_sec() * rate)
	check(peak > 0.1, "export: the test sound is audible (peak %.2f)" % peak)
	var tail_peak := 0.0
	if w.ok:
		for i in range(last_clip_end + 2000, mini(total, int(w.frames))):
			tail_peak = maxf(tail_peak, absf((w.samples as PackedFloat32Array)[i * 2]))
	check(tail_peak > 0.0001 or total <= last_clip_end + 2000, "export: the tail is in the file (peak %.4f after the last clip)" % tail_peak)

	# 16-bit: within a couple of LSB of the float render (TPDF dither).
	var r16: Dictionary = await AWExporter.new().run(ep, abs_path, 16)
	var w16 := _read_wav(abs_path)
	var worst16 := 0.0
	if w16.ok:
		var s16: PackedFloat32Array = w16.samples
		for i in mini(ref.size(), int(w16.frames)):
			var cx := clampf(ref[i].x, -1.0, 1.0)
			worst16 = maxf(worst16, absf(s16[i * 2] - cx))
	check(r16.ok and w16.ok and w16.bits == 16 and w16.format_tag == 1 and worst16 < 3.0 / 32768.0, "export: 16-bit file is PCM within 3 LSB of the render (worst %.1f LSB)" % (worst16 * 32768.0))
	check(r16.ok and int(r16.bytes) == int(w16.file_bytes) and int(r16.bytes) == int(w16.frames) * 4 + 44, "export: a 16-bit file is header + 4 bytes a frame")

	# Godot's own WAV loader reads both depths like the preview (its playback lags 2 frames).
	# Uncompressed and QOA, the import modes a user would pick.
	for mode in [0, 2]:
		var g16 := _godot_wav_decode(abs_path, total, {"compress/mode": mode}).slice(4)
		var e16 := _rel_error(g16, ref)
		check(g16.size() / 2 > total / 2 and e16 < 1e-5, "export: Godot's WAV loader (compress mode %d) plays the 16-bit file like the preview (error %.1f dB)" % [mode, 10.0 * log(maxf(e16, 1e-12)) / log(10.0)])
	var r32b: Dictionary = await AWExporter.new().run(ep, abs_path, 32)
	var g32 := _godot_wav_decode(abs_path, total, {"compress/mode": 0}).slice(4)
	var e32 := _rel_error(g32, ref)
	check(r32b.ok and g32.size() / 2 > total / 2 and e32 < 1e-6, "export: Godot's WAV loader plays the 32-bit file like the preview (error %.1f dB)" % (10.0 * log(maxf(e32, 1e-12)) / log(10.0)))

	# Ogg Vorbis: Godot decodes it and it matches the render closely; higher quality means a bigger file.
	var opath := ProjectSettings.globalize_path("user://aw_export_test.ogg")
	var ro: Dictionary = await AWExporter.new().run(ep, opath, 16, "ogg", 5.0)
	var obytes := FileAccess.get_file_as_bytes(opath)
	check(ro.ok and obytes.size() > 1000 and obytes.slice(0, 4).get_string_from_ascii() == "OggS", "export Ogg: an Ogg file (%d bytes)" % obytes.size())
	var ostream := AudioStreamOggVorbis.load_from_buffer(obytes)
	check(ostream != null and absf(ostream.get_length() - length) < 0.05, "export Ogg: Godot loads it (%.3f s, wanted %.3f)" % [ostream.get_length() if ostream else -1.0, length])
	if ostream != null:
		var opb := ostream.instantiate_playback()
		opb.start(0.0)
		var dec_frames := PackedVector2Array()
		var guard_o := 0
		while dec_frames.size() < total and guard_o < 2000:
			var got_o: PackedVector2Array = opb.mix_audio(1.0, mini(4096, total - dec_frames.size()))
			if got_o.is_empty():
				break
			dec_frames.append_array(got_o)
			guard_o += 1
		var dec_samples := PackedFloat32Array()
		dec_samples.resize(dec_frames.size() * 2)
		for i in dec_frames.size():
			dec_samples[i * 2] = dec_frames[i].x
			dec_samples[i * 2 + 1] = dec_frames[i].y
		var oerr := _rel_error(dec_samples, ref)
		check(dec_frames.size() > total / 2 and oerr < 0.01, "export Ogg: decodes to within 20 dB of the render (error %.5f, %d frames)" % [oerr, dec_frames.size()])
	var ro2: Dictionary = await AWExporter.new().run(ep, opath, 16, "ogg", 9.0)
	check(ro2.ok and int(ro2.bytes) > int(ro.bytes), "export Ogg: quality 9 is larger than quality 5 (%d vs %d bytes)" % [int(ro2.bytes), int(ro.bytes)])
	DirAccess.remove_absolute(opath)
	var rbad: Dictionary = await AWExporter.new().run(ep, opath, 16, "mp3")
	check(not rbad.ok and rbad.error.begins_with("Unknown format"), "export: an unknown format is refused")

	# Cancel mid-way: no file appears, an existing file stays as it was.
	var before := FileAccess.get_file_as_bytes(abs_path)
	var ec := AWExporter.new()
	ec.progress.connect(func(_f: float) -> void: ec.cancel())
	var rc: Dictionary = await ec.run(ep, abs_path, 32)
	check(not rc.ok and rc.cancelled and not FileAccess.file_exists(abs_path + ".part"), "export: cancel stops it and removes the .part file")
	check(FileAccess.get_file_as_bytes(abs_path) == before, "export: a cancelled export leaves the old file untouched")

	# Clipping is reported: +12 dB on the clip pushes it over full scale.
	var clip_src: AWEffect = sclip.chain.effects[0]
	clip_src.params["gain_db"] = 12.0
	var rhot: Dictionary = await AWExporter.new().run(ep, abs_path, 32)
	clip_src.params["gain_db"] = 0.0
	check(rhot.ok and int(rhot.clipped) > 0 and AWExporter.summary(rhot).contains("clip"), "export: samples over full scale are counted and the summary warns (%d)" % int(rhot.clipped))

	# Nothing to export: an empty project.
	var empty := AWProject.new()
	var re: Dictionary = await AWExporter.new().run(empty, abs_path, 16)
	check(not re.ok and re.error.begins_with("Nothing to export"), "export: an empty project says so")

	# Format choice in the document and the dock.
	var xpf: AWExportPanel = screen.export_panel
	d.set_export_path("assets/sfx/jump.wav")
	d.set_export_format("ogg")
	check(d.project.export_path == "assets/sfx/jump.ogg" and xpf._quality_row.visible and not xpf._depth_row.visible, "export dock: Ogg swaps the extension, shows Quality, hides Bit depth")
	d.set_export_format("wav")
	check(d.project.export_path == "assets/sfx/jump.wav" and xpf._depth_row.visible, "export dock: back to WAV")
	d.set_export_path("assets/sfx/custom_name")
	d.set_export_format("ogg")
	check(d.project.export_path == "assets/sfx/custom_name.ogg", "export dock: a name without extension gets one")
	d.set_export_format("wav")
	d.set_export_path("assets/sfx/jump.wav")

	# The dock: Export button runs it through the document and shows the result.
	d.set_export_path(path)
	d.set_export_bit_depth(16)
	var xp: AWExportPanel = screen.export_panel
	d.export_now()
	check(d.exporting and xp._export_btn.text == "Cancel" and xp._progress.visible, "export dock: while rendering the button says Cancel and shows progress")
	var guard := 0
	while d.exporting and guard < 400:
		await frames(tree, 1)
		guard += 1
	await frames(tree, 2)
	check(not d.exporting and xp._export_btn.text == "Export" and not xp._progress.visible and xp._result.visible and xp._result.text.begins_with("Exported"), "export dock: finished, result line shown (%s)" % xp._result.text)
	d.set_export_bit_depth(16)
	d.set_export_path("assets/sfx/jump.wav")
	DirAccess.remove_absolute(abs_path)

static func _render_project(p: AWProject, secs: float) -> PackedVector2Array:
	var e := AWEngine.new()
	e.set_project(p)
	return e.render_preview_range(0.0, secs)


static func editor_resource_tests(_tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	d.new_project()
	d.set_project(AWProject.create_demo())
	var path := "user://aw_editor_res.tres"
	check(d.save_project(path), "editor resource: saved")
	check(d.project.resource_path == path, "editor resource: the open sound is the resource for its path")
	var cached := ResourceLoader.load(path) # what the editor / inspector holds
	check(cached == d.project, "editor resource: the editor's copy is the open sound, not a stale one")

	# An edit and another save reach the same object and the file.
	d.set_props(d.project.clips[0], {"name": "After the edit"}, "Rename")
	check(d.save_project(path), "editor resource: second save")
	check((ResourceLoader.load(path) as AWProject).clips[0].name == "After the edit", "editor resource: loading the path returns the saved content")
	var on_disk := AWProjectIO.open(path)
	check(on_disk.ok and on_disk.project.clips[0].name == "After the edit", "editor resource: the file on disk has the edit")

	# Saving the editor's own copy (inspector / Ctrl+S on a resource) can't revert our save.
	check(ResourceSaver.save(cached, path) == OK, "editor resource: an editor save of the cached copy works")
	var again := AWProjectIO.open(path)
	check(again.ok and again.project.clips[0].name == "After the edit", "editor resource: and still has the edit")

	# Save As moves the resource to the new path; the recovery copy never takes it over.
	var path2 := "user://aw_editor_res2.tres"
	check(d.save_project(path2) and d.project.resource_path == path2, "editor resource: save as follows the new path")
	d.set_props(d.project.clips[0], {"name": "Dirty again"}, "Rename")
	d.write_recovery()
	check(d.project.resource_path == path2, "editor resource: the recovery copy does not take over the path")
	d.new_project()


## A sound with one clip of a sine at `hz` (for telling exports apart).
static func _sine_project(hz: float, path: String) -> AWProject:
	write_wav(path, 1.0, func(i: int, rt: int) -> Vector2i:
		var v := int(12000.0 * sin(TAU * hz * i / rt))
		return Vector2i(v, v))
	var p := AWProject.create_default()
	var c := AWClip.create("sine", 0.0, 1.0, 0, Color.RED)
	c.source_path = path
	p.clips.append(c)
	p.export_end_sec = 1.0
	return p


## Zero crossings per second of the left channel of an imported stream (a frequency estimate).
static func _crossings(st: AudioStreamWAV) -> float:
	if st == null:
		return -1.0
	var pb := st.instantiate_playback()
	pb.start(0.0)
	var fr: PackedVector2Array = pb.mix_audio(1.0, int(st.mix_rate * 0.5))
	var n := 0
	for i in range(1, fr.size()):
		if (fr[i - 1].x < 0.0) != (fr[i].x < 0.0):
			n += 1
	return n / 0.5 / 2.0


## Waits until the editor has (re)imported `path` after `since_msec`, up to `max_sec`.
static func _wait_import(tree: SceneTree, path: String, since_msec: int, max_sec := 20.0) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	var t0 := Time.get_ticks_msec()
	var stable := 0
	while Time.get_ticks_msec() - t0 < max_sec * 1000.0:
		await tree.process_frame
		var imported := FileAccess.file_exists(path + ".import") and FileAccess.get_modified_time(path + ".import") * 1000 >= since_msec / 1000 * 1000 - 1000
		if fs.is_scanning() or not imported:
			stable = 0
			continue
		stable += 1
		if stable > 20:
			print("IMPORT waited %d ms" % (Time.get_ticks_msec() - t0))
			return
	print("IMPORT gave up after %d ms" % (Time.get_ticks_msec() - t0))


static func reexport_tests(tree: SceneTree, _screen: AWMainScreen) -> void:
	# Exporting over a file that is already imported: the editor must play the new sound, not the
	# previously imported one (owner report: a WAV sounded wrong until the editor was restarted).
	var target := "res://aw_reexport_test.wav"
	var low := _sine_project(200.0, "/tmp/aw_reexport_200.wav")
	var high := _sine_project(1000.0, "/tmp/aw_reexport_1000.wav")
	var r1: Dictionary = await AWExporter.new().run(low, target, 16)
	await _wait_import(tree, target, int(Time.get_unix_time_from_system() * 1000.0))
	var first := ResourceLoader.load(target) as AudioStreamWAV # held, like an open inspector or player
	var f1 := _crossings(first)
	check(r1.ok and absf(f1 - 200.0) < 10.0, "re-export: first export imported (%.0f Hz)" % f1)
	await tree.create_timer(1.1).timeout # file times have one-second resolution
	var t2 := int(Time.get_unix_time_from_system() * 1000.0)
	var r2: Dictionary = await AWExporter.new().run(high, target, 32)
	await _wait_import(tree, target, t2)
	var again := ResourceLoader.load(target) as AudioStreamWAV
	var f2 := _crossings(again)
	var f_held := _crossings(first)
	print("REEXPORT after second export: load %.0f Hz, held copy %.0f Hz" % [f2, f_held])
	check(r2.ok and absf(f2 - 1000.0) < 20.0, "re-export: loading the file gives the new sound (%.0f Hz)" % f2)
	check(absf(f_held - 1000.0) < 20.0, "re-export: a copy the editor already held is updated too (%.0f Hz)" % f_held)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(target))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(target + ".import"))
	EditorInterface.get_resource_filesystem().scan()


## What the newer LFO parameters do, on the GDScript reference (the native sampler matches it, above).
static func lfo_param_tests(ch: AWChain) -> void:
	var wet: AWCurve = null
	for c in ch.curves:
		if c.param == "wet":
			wet = c
	var keys := ch.get_keys(wet)
	ch.set_keys(wet, [{"t": 0.0, "v": 0.2, "in": Vector2.ZERO, "out": Vector2.ZERO, "mode": AWCurve.HandleMode.LINEAR},
		{"t": 4.0, "v": 0.8, "in": Vector2.ZERO, "out": Vector2.ZERO, "mode": AWCurve.HandleMode.LINEAR}])
	var mk := func() -> AWLfo:
		var l := AWLfo.new()
		l.start_sec = 0.0
		l.end_sec = 4.0
		l.fade_in_sec = 0.0
		l.fade_out_sec = 0.0
		l.freq_hz = 2.0
		l.min_value = 0.0
		l.max_value = 1.0
		return l

	# Defaults reproduce the old formula exactly (old sounds don't change).
	var l0: AWLfo = mk.call()
	wet.lfo = l0
	var same := true
	for i in 200:
		var t := i * 0.019
		same = same and absf(ch.sample_norm(wet, t) - (0.5 + 0.5 * sin(TAU * 2.0 * t))) < 1e-9
	check(same, "lfo params: defaults give the same sine as before")

	# Relative: wobbles ±Depth around the drawn ramp instead of replacing it.
	var lr: AWLfo = mk.call()
	lr.mode = AWLfo.Mode.RELATIVE
	lr.depth = 0.1
	wet.lfo = lr
	var dev := 0.0
	var mean := 0.0
	for i in 400:
		var t := i * 0.01
		var d := ch.sample_norm(wet, t) - ch.base_norm(wet, t)
		dev = maxf(dev, absf(d))
		mean += d / 400.0
	check(absf(dev - 0.1) < 0.002 and absf(mean) < 0.01, "lfo params: Relative swings ±Depth around the curve (max %.3f, mean %.4f)" % [dev, mean])
	check(lr.summary("Reverb", "wet").contains("±10%"), "lfo params: summary shows the relative depth (%s)" % lr.summary("Reverb", "wet"))

	# Phase 90°: a sine starts at the top.
	var lp: AWLfo = mk.call()
	lp.phase_deg = 90.0
	wet.lfo = lp
	check(absf(ch.sample_norm(wet, 0.0) - 1.0) < 1e-6, "lfo params: Phase 90° starts a sine at its peak")

	# Jitter: cycle lengths vary, the phase still only moves forward, and it's repeatable.
	var lj: AWLfo = mk.call()
	lj.jitter_rate = 1.0
	lj.random_seed = 4
	var lens := []
	var prev_edge := 0.0
	var mono := true
	var last := -INF
	for i in 2000:
		var p := lj.warped_phase(i * 0.002)
		mono = mono and p >= last
		last = p
	for k in range(1, 8):
		var edge := lj.time_of_warped_phase(float(k))
		lens.append(edge - prev_edge)
		prev_edge = edge
	var lmin: float = lens.min()
	var lmax: float = lens.max()
	check(mono and lmax / lmin > 1.15 and lmin > 0.0, "lfo params: Jitter varies cycle lengths (%.3f to %.3f s) and the phase never runs backwards" % [lmin, lmax])
	var lj2: AWLfo = lj.duplicate()
	check(is_equal_approx(lj.warped_phase(1.234), lj2.warped_phase(1.234)), "lfo params: Jitter is repeatable for a seed")
	var lj3: AWLfo = lj.duplicate()
	lj3.random_seed = 9
	check(not is_equal_approx(lj.warped_phase(1.234), lj3.warped_phase(1.234)), "lfo params: another seed gives other cycles")

	# Jitter depth: cycle peaks differ.
	var ld: AWLfo = mk.call()
	ld.jitter_depth = 1.0
	ld.random_seed = 2
	var peaks := []
	for k in 6:
		peaks.append(absf(ld.swing((k + 0.25) / 2.0)))
	check((peaks.max() as float) - (peaks.min() as float) > 0.2 and (peaks.max() as float) <= 1.0, "lfo params: Jit Depth varies the cycle heights (%s)" % str(peaks))

	# Glide: 0 keeps the hard square; 1 turns it into the sine.
	var lg: AWLfo = mk.call()
	lg.shape = AWLfo.Shape.SQUARE
	var hard := lg.shape_at(0.24) == 1.0 and lg.shape_at(0.26) == 1.0 and lg.shape_at(0.51) == 0.0
	lg.glide = 1.0
	var sine_like := true
	for i in 50:
		var p := i * 0.021
		sine_like = sine_like and absf(lg.shape_at(p) - (0.5 + 0.5 * sin(TAU * p))) < 1e-9
	check(hard and sine_like, "lfo params: Glide 0 keeps Square hard, Glide 100% makes it a sine")
	var lrnd: AWLfo = mk.call()
	lrnd.shape = AWLfo.Shape.RANDOM
	lrnd.glide = 1.0
	var max_step := 0.0
	for i in range(1, 2000):
		max_step = maxf(max_step, absf(lrnd.shape_at(i * 0.001) - lrnd.shape_at((i - 1) * 0.001)))
	check(max_step < 0.01, "lfo params: Glide makes Random a smooth drift (largest step %.4f)" % max_step)
	var lsaw: AWLfo = mk.call()
	lsaw.shape = AWLfo.Shape.SAW
	lsaw.glide = 0.4
	var saw_step := 0.0
	for i in range(1, 2000):
		saw_step = maxf(saw_step, absf(lsaw.shape_at(i * 0.001) - lsaw.shape_at((i - 1) * 0.001)))
	check(saw_step < 0.02, "lfo params: Glide removes the Saw's reset jump (largest step %.4f)" % saw_step)

	# ADSR: Attack 1 s rises to full, Decay 1 s falls to Sustain 0.4, which holds; Release (the last
	# 1 s of the span) fades from there to nothing.
	var lde: AWLfo = mk.call()
	lde.fade_in_sec = 1.0
	lde.decay_sec = 1.0
	lde.sustain = 0.4
	lde.fade_out_sec = 1.0
	lde.end_sec = 5.0
	var env := [lde.envelope(0.5), lde.envelope(1.0), lde.envelope(1.5), lde.envelope(2.5), lde.envelope(4.5), lde.envelope(5.0)]
	check(absf(env[0] - 0.5) < 1e-6 and absf(env[1] - 1.0) < 1e-6 and absf(env[2] - 0.7) < 1e-6 and absf(env[3] - 0.4) < 1e-6 and absf(env[4] - 0.2) < 1e-6 and env[5] < 1e-6, "lfo ADSR: attack, decay to sustain, hold, release (%s)" % str(env))
	var old := AWProject.create_default()
	var oc := AWClip.create("c", 0.0, 1.0, 0, Color.RED)
	old.clips.append(oc)
	var ocv := AWCurve.new()
	ocv.effect_id = oc.chain.effects[0].id
	ocv.param = "gain_db"
	oc.chain.curves.append(ocv)
	var ol: AWLfo = mk.call()
	ol.decay_sec = 1.5 # a format-6 half-life
	ocv.lfo = ol
	old.format_version = 6
	var opath := ProjectSettings.globalize_path("user://aw_old6.tres")
	ResourceSaver.save(old, opath)
	var oo := AWProjectIO.open(opath)
	var ml: AWLfo = oo.project.clips[0].chain.curves[0].lfo if oo.ok else null
	check(ml != null and absf(ml.decay_sec - 6.0) < 1e-6 and ml.sustain == 0.0, "lfo ADSR: an old half-life Decay converts to Decay 4x to Sustain 0")
	DirAccess.remove_absolute(opath)

	# Repair clamps the new fields; save and open keeps them.
	var bad := AWProject.create_default()
	var bc := AWClip.create("c", 0.0, 1.0, 0, Color.RED)
	bad.clips.append(bc)
	var bcurve := AWCurve.new()
	bcurve.effect_id = bc.chain.effects[0].id
	bcurve.param = "gain_db"
	bc.chain.curves.append(bcurve)
	var bl: AWLfo = mk.call()
	bl.depth = 5.0
	bl.glide = -1.0
	bl.decay_sec = NAN
	bcurve.lfo = bl
	var rep := AWProjectIO.sanitize(bad)
	check(bl.depth == 1.0 and bl.glide == 0.0 and bl.decay_sec == 0.0 and rep.size() >= 3, "lfo params: repair clamps out-of-range values (%d repairs)" % rep.size())
	bl.mode = AWLfo.Mode.RELATIVE
	bl.depth = 0.33
	bl.phase_deg = 120.0
	bl.jitter_rate = 0.4
	bl.jitter_depth = 0.2
	bl.glide = 0.6
	bl.decay_sec = 2.5
	var path := "user://aw_lfo_params.tres"
	check(AWProjectIO.save(bad, path, false) == OK, "lfo params: saved")
	var back := AWProjectIO.open(path)
	var lb: AWLfo = back.project.clips[0].chain.curves[0].lfo if back.ok else null
	check(lb != null and lb.signature() == bl.signature(), "lfo params: save and open keep every LFO setting")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	wet.lfo = null
	ch.set_keys(wet, keys)


static func _rm_tree(abs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	for f in DirAccess.get_files_at(abs_dir):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	for d in DirAccess.get_directories_at(abs_dir):
		_rm_tree(abs_dir.path_join(d))
	DirAccess.remove_absolute(abs_dir)


static func import_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var imports_abs := ProjectSettings.globalize_path(AWImporter.ROOT)
	_rm_tree(imports_abs)
	_rm_tree("/tmp/aw_imp")
	DirAccess.make_dir_recursive_absolute("/tmp/aw_imp/sub folder")
	var tone := func(hz: float) -> Callable:
		return func(i: int, rt: int) -> Vector2i:
			var v := int(9000.0 * sin(TAU * hz * i / rt))
			return Vector2i(v, v)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	write_wav("/tmp/aw_imp/door slam.wav", 0.6, func(i: int, rt: int) -> Vector2i:
		var t := float(i) / rt
		var env := exp(-t * 7.0) * minf(1.0, t * 400.0) + 0.25 * exp(-maxf(t - 0.22, 0.0) * 18.0) * float(t > 0.22)
		var v := int(clampf((rng.randf() * 2.0 - 1.0) * 0.6 * env + 0.3 * sin(TAU * 70.0 * t) * env, -1.0, 1.0) * 32000.0)
		return Vector2i(v, v))
	write_wav("/tmp/aw_imp/glass.wav", 0.4, tone.call(900.0))
	write_wav("/tmp/aw_imp/sub folder/step.wav", 0.3, tone.call(400.0))
	var f := FileAccess.open("/tmp/aw_imp/notes.txt", FileAccess.WRITE)
	f.store_string("not a sound")
	f.close()
	var saved_copy: bool = AWImporter.copy_by_default()
	d.new_project()

	# Copy (the default): the file lands in res://audio_workstation_imports/<sound>/ and plays.
	var got := d.import_files(PackedStringArray(["/tmp/aw_imp/door slam.wav", "/tmp/aw_imp/notes.txt"]), 0, 0.5, true)
	var want := AWImporter.ROOT.path_join("Untitled/door slam.wav")
	check(got.size() == 1 and got[0].source_path == want and FileAccess.file_exists(want), "import: an outside file is copied into %s (%s)" % [want.get_base_dir(), got[0].source_path if got.size() > 0 else "-"])
	check(got.size() == 1 and absf(got[0].start_sec - 0.5) < 1e-6 and got[0].row == 0 and absf(got[0].length_sec - 0.6) < 0.01, "import: placed at the row and time, with the file's length")
	check(got.size() == 1 and not d.is_clip_external(got[0]), "import: a copied clip is not marked as outside the project")
	var pk := d.engine.get_peaks(want, 50.0)
	var loud := 0.0
	for v in pk:
		loud = maxf(loud, v)
	check(loud > 0.1, "import: the copied clip has sound right away, before the editor's import (peak %.2f)" % loud)
	# The same file again reuses the copy; a different file with the same name gets a suffix.
	var again := d.import_files(PackedStringArray(["/tmp/aw_imp/door slam.wav"]), 1, 0.0, true)
	check(again.size() == 1 and again[0].source_path == want, "import: an identical file reuses the existing copy")
	DirAccess.make_dir_recursive_absolute("/tmp/aw_imp/other")
	write_wav("/tmp/aw_imp/other/door slam.wav", 0.2, tone.call(300.0))
	var clash := d.import_files(PackedStringArray(["/tmp/aw_imp/other/door slam.wav"]), 2, 0.0, true)
	check(clash.size() == 1 and clash[0].source_path == AWImporter.ROOT.path_join("Untitled/door slam_2.wav"), "import: a different file with the same name gets _2 (%s)" % (clash[0].source_path if clash.size() > 0 else "-"))

	# A saved sound uses its file name for the folder.
	check(d.save_project("res://aw_import_test_hit.tres"), "import: saved the sound")
	var named := d.import_files(PackedStringArray(["/tmp/aw_imp/glass.wav"]), 3, 0.0, true)
	check(named.size() == 1 and named[0].source_path == AWImporter.ROOT.path_join("aw_import_test_hit/glass.wav"), "import: the folder is named after the saved sound (%s)" % (named[0].source_path if named.size() > 0 else "-"))

	# Reference in place: marked as outside; Copy Into Project brings it in (undoable).
	var ext := d.import_files(PackedStringArray(["/tmp/aw_imp/sub folder/step.wav"]), 4, 0.0, false)
	check(ext.size() == 1 and ext[0].source_path == "/tmp/aw_imp/sub folder/step.wav" and d.is_clip_external(ext[0]), "import: without copying, the clip uses the file where it is and is marked")
	d.copy_clip_into_project(ext[0])
	check(ext[0].source_path == AWImporter.ROOT.path_join("aw_import_test_hit/step.wav") and not d.is_clip_external(ext[0]), "import: Copy Into Project moves the clip to a copy in the project")
	d.undo()
	check(ext[0].source_path == "/tmp/aw_imp/sub folder/step.wav", "import: Copy Into Project undoes")
	d.redo()

	# Files already in the project are used where they are.
	var inproj := d.import_files(PackedStringArray([ProjectSettings.globalize_path(want)]), 5, 0.0, true)
	check(inproj.size() == 1 and inproj[0].source_path == want, "import: a file inside the project is used in place, as res:// (%s)" % (inproj[0].source_path if inproj.size() > 0 else "-"))

	# The copy choice is remembered.
	AWImporter.set_pref(AWImporter.PREF_COPY, false)
	check(not AWImporter.copy_by_default(), "import: the copy choice is remembered (off)")
	AWImporter.set_pref(AWImporter.PREF_COPY, true)
	check(AWImporter.copy_by_default(), "import: the copy choice is remembered (on)")

	# Dropped from the system file manager onto the grid.
	var grid := screen.timeline.grid
	var n0 := d.project.clips.size()
	var at := Vector2(grid.view.time_to_x(1.0), grid.row_h * 6.5)
	screen.drop_os_files(PackedStringArray(["/tmp/aw_imp/glass.wav", "/tmp/aw_imp/notes.txt"]), at)
	var dropped := d.project.clips[d.project.clips.size() - 1]
	check(d.project.clips.size() == n0 + 1 and dropped.row == 6 and absf(dropped.start_sec - d.snap(1.0)) < 1e-3, "import: a file dropped from the file manager lands where it was dropped (row %d, %.2f s)" % [dropped.row, dropped.start_sec])

	# WAV facts without decoding.
	var wi := AWImporter.wav_info("/tmp/aw_imp/door slam.wav")
	check(wi.get("channels", 0) == 2 and wi.get("bits", 0) == 16 and absf(float(wi.get("length", 0.0)) - 0.6) < 0.01, "import: WAV header read for the browser (%s)" % str(wi))

	# The browser.
	var b := screen.browser
	for w: Window in screen.find_children("*", "Window", true, false):
		if w != b and w.visible:
			w.hide() # a dialog left open by an earlier test would block this one
	screen._on_request("import")
	await frames(tree, 4)
	check(b.visible, "browser: File > Import Sound opens it")
	b.open_dir("/tmp/aw_imp")
	await frames(tree, 2)
	var names: Array = b.entries.map(func(e: Dictionary) -> String: return e.name)
	check(names == ["other", "sub folder", "door slam.wav", "glass.wav"], "browser: folders first, then sounds; other files hidden (%s)" % str(names))
	b._search.text = "gla"
	b._search.text_changed.emit("gla")
	check(b.entries.size() == 1 and b.entries[0].name == "glass.wav", "browser: search filters the folder")
	b._search.text = ""
	b._search.text_changed.emit("")
	b.select_paths(PackedStringArray(["/tmp/aw_imp/door slam.wav"]))
	await frames(tree, 3)
	check(b.wave_peaks.size() == 600 and b.preview.stream != null, "browser: selecting a sound shows its waveform")
	check(b.preview.playing or not b._autoplay.button_pressed, "browser: Play on select plays it")
	b.stop()
	b.open_dir("/tmp/aw_imp/sub folder")
	b.go_back()
	check(b.dir == "/tmp/aw_imp", "browser: Back returns to the previous folder")
	var fav0 := b.favorites().has("/tmp/aw_imp")
	b.toggle_favorite()
	check(b.favorites().has("/tmp/aw_imp") != fav0, "browser: favorite toggles and is remembered")
	b.toggle_favorite()
	check(AWImporter.get_pref(AWImporter.PREF_LAST_DIR, "") == "/tmp/aw_imp", "browser: the folder is remembered")
	b.select_paths(PackedStringArray(["/tmp/aw_imp/door slam.wav", "/tmp/aw_imp/glass.wav"]))
	b._select_file("/tmp/aw_imp/door slam.wav")
	b.play(0.0)
	await tree.create_timer(0.15).timeout
	check(b.get_ok_button().text == "Import 2", "browser: the Import button counts the selection (%s)" % b.get_ok_button().text)
	if OS.get_environment("AW_SHOTS") != "":
		await frames(tree, 6)
		var img := b.get_texture().get_image() if not b.is_embedded() else tree.root.get_viewport().get_texture().get_image()
		img.save_png(out_dir.path_join("aw_sound_browser.png"))
	screen._import_at = Vector2(8, 0.25)
	var n1 := d.project.clips.size()
	b.confirmed.emit()
	await frames(tree, 2)
	check(d.project.clips.size() == n1 + 2 and d.project.clips[n1].row == 8 and d.project.clips[n1 + 1].row == 9, "browser: Import adds the selected sounds, one row each")
	b.hide()
	check(not b.preview.playing, "browser: closing stops the preview")

	# The grid's menu offers Import Sound and Copy Into Project.
	var items := []
	grid._open_menu(Vector2(grid.view.time_to_x(10.0), 2.0))
	for i in grid._menu.item_count:
		items.append(grid._menu.get_item_text(i))
	grid._menu.hide()
	check(items.has("Import Sound..."), "grid menu: Import Sound... on empty space")
	var fm_items := []
	for fm: MenuButton in screen.find_children("*", "MenuButton", true, false):
		if fm.text == "File":
			for i in fm.get_popup().item_count:
				fm_items.append(fm.get_popup().get_item_text(i))
	check(fm_items.has("Import Sound..."), "File menu: Import Sound...")

	AWImporter.set_pref(AWImporter.PREF_COPY, saved_copy)
	d.new_project()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://aw_import_test_hit.tres"))
	_rm_tree(imports_abs)
	_rm_tree("/tmp/aw_imp")
	EditorInterface.get_resource_filesystem().scan()


static func _grid_project(d: AWDocument) -> Array[AWClip]:
	d.new_project()
	for nm: Array in [["/tmp/aw_grid_a.wav", 220.0, 1.0], ["/tmp/aw_grid_b.wav", 440.0, 0.8], ["/tmp/aw_grid_c.wav", 660.0, 0.6]]:
		var hz: float = nm[1]
		write_wav(nm[0], nm[2], func(i: int, rt: int) -> Vector2i:
			var v := int(9000.0 * sin(TAU * hz * i / rt) * (1.0 - float(i) / (rt * 1.2)))
			return Vector2i(v, v))
	var a := d.add_clip_from_path("/tmp/aw_grid_a.wav", 0, 0.0)
	var b := d.add_clip_from_path("/tmp/aw_grid_b.wav", 1, 0.5)
	var c := d.add_clip_from_path("/tmp/aw_grid_c.wav", 2, 1.0)
	d.clear_selection()
	return [a, b, c] as Array[AWClip]


static func grid_edit_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var grid := screen.timeline.grid
	var clips := _grid_project(d)
	var a := clips[0]
	var b := clips[1]
	var c := clips[2]
	d.set_snap(0.05)
	await frames(tree, 2)

	# Copy / paste at the playhead, on the same rows; cut removes; paste works after New too.
	d.set_selection([a, b] as Array[AWClip])
	key(screen, KEY_C, true)
	d.seek(3.0)
	key(screen, KEY_V, true)
	check(d.project.clips.size() == 5 and d.selection.size() == 2, "copy/paste: two clips pasted and selected")
	var p0: AWClip = d.selection[0]
	var p1: AWClip = d.selection[1]
	check(absf(p0.start_sec - 3.0) < 1e-6 and absf(p1.start_sec - 3.5) < 1e-6 and p0.row == 0 and p1.row == 1, "copy/paste: lands at the playhead, spacing and rows kept")
	check(p0 != a and p0.chain != a.chain and p0.source_path == a.source_path, "copy/paste: pasted clips are independent copies")
	d.undo()
	check(d.project.clips.size() == 3, "copy/paste: paste undoes in one step")
	d.set_selection([c] as Array[AWClip])
	key(screen, KEY_X, true)
	check(d.project.clips.size() == 2 and not d.project.clips.has(c), "cut: removes the clip")
	d.seek(0.25)
	key(screen, KEY_V, true)
	check(d.project.clips.size() == 3 and absf(d.selection[0].start_sec - 0.25) < 1e-6, "cut: pastes back at the playhead")
	c = d.selection[0]

	# Nudge: one snap step per arrow press (Shift = 10), Up/Down move rows; never before 0 or row 0.
	d.set_selection([b] as Array[AWClip])
	key(screen, KEY_RIGHT)
	check(absf(b.start_sec - 0.55) < 1e-6, "nudge: Right moves one snap step (%.3f)" % b.start_sec)
	key(screen, KEY_LEFT, false, true)
	check(absf(b.start_sec - 0.05) < 1e-6, "nudge: Shift+Left moves ten steps (%.3f)" % b.start_sec)
	key(screen, KEY_LEFT, false, true)
	check(b.start_sec >= 0.0 and b.start_sec < 1e-6, "nudge: stops at 0")
	key(screen, KEY_DOWN)
	key(screen, KEY_UP)
	key(screen, KEY_UP)
	key(screen, KEY_UP)
	check(b.row == 0, "nudge: Up/Down change rows, not above row 0 (row %d)" % b.row)
	key(screen, KEY_RIGHT, false, false, true)
	check(absf(b.start_sec - 0.05) < 1e-6, "nudge: holding the key repeats")
	d.set_snap(0.0)
	key(screen, KEY_RIGHT)
	check(absf(b.start_sec - 0.06) < 1e-6, "nudge: 10 ms per press with snap off")
	d.set_snap(0.05)

	# Trim to playhead (Q start, W end); curves keep their place on the audio.
	d.set_selection([a] as Array[AWClip])
	var gain_curve := d.make_curve(a.chain, a.chain.effects[0], "gain_db")
	a.chain.set_keys(gain_curve, [{"t": 0.6, "v": 0.5, "in": Vector2.ZERO, "out": Vector2.ZERO, "mode": AWCurve.HandleMode.LINEAR}])
	d.seek(0.2)
	key(screen, KEY_Q)
	check(absf(a.start_sec - 0.2) < 1e-6 and absf(a.source_offset_sec - 0.2) < 1e-6 and absf(a.length_sec - 0.8) < 1e-6, "trim to playhead: Q trims the start")
	check(absf(a.chain.get_keys(gain_curve)[0].t - 0.4) < 1e-6, "trim to playhead: curve keys stay on the same audio")
	d.seek(0.7)
	key(screen, KEY_W)
	check(absf(a.length_sec - 0.5) < 1e-6 and a.end_sec() <= 0.7 + 1e-6, "trim to playhead: W trims the end")
	d.undo()
	d.undo()
	check(absf(a.start_sec) < 1e-6 and absf(a.length_sec - 1.0) < 1e-6 and absf(a.chain.get_keys(gain_curve)[0].t - 0.6) < 1e-6, "trim to playhead: both undo")

	# Rename (F2 and double-click on the name strip) and colour.
	key(screen, KEY_F2)
	var ed: LineEdit = grid._rename_edit
	check(ed.visible and ed.text == a.name, "rename: F2 opens the name editor")
	ed.text = "Impact body"
	ed.text_submitted.emit(ed.text)
	check(a.name == "Impact body" and not ed.visible, "rename: Enter renames")
	var ra := grid.clip_rect(b)
	click(grid, ra.position + Vector2(20, 5), MOUSE_BUTTON_LEFT, true, true)
	check(ed.visible and grid._rename_clip == b, "rename: double-click on the name strip opens it")
	var ek := InputEventKey.new()
	ek.keycode = KEY_ESCAPE
	ek.pressed = true
	ed.text = "nope"
	ed.gui_input.emit(ek)
	check(b.name != "nope" and not ed.visible, "rename: Esc cancels")
	d.set_selection([a, b] as Array[AWClip])
	d.set_clip_color(a, AWProject.CLIP_COLORS[5])
	check(a.color == AWProject.CLIP_COLORS[5] and b.color == AWProject.CLIP_COLORS[5], "colour: applies to the selection")
	d.undo()
	check(a.color != AWProject.CLIP_COLORS[5] or b.color != AWProject.CLIP_COLORS[5], "colour: undoes")

	# Ctrl+vertical drag: clip gain (relative on a selection); Ctrl+click still toggles.
	d.set_selection([a] as Array[AWClip])
	a.chain.remove_track(gain_curve)
	a.chain.curves.erase(gain_curve)
	var rb := grid.clip_rect(b)
	var mid := rb.get_center()
	click(grid, mid, MOUSE_BUTTON_LEFT, true, false, false, true)
	click(grid, mid, MOUSE_BUTTON_LEFT, false)
	check(d.is_selected(b) and d.is_selected(a), "ctrl+click: still toggles the selection")
	var ga := float(a.chain.effects[0].get_param("gain_db"))
	var gb := float(b.chain.effects[0].get_param("gain_db"))
	click(grid, mid, MOUSE_BUTTON_LEFT, true, false, false, true)
	for i in range(1, 6):
		move(grid, mid + Vector2(0, -4.0 * i), false, {"ctrl": true})
	click(grid, mid + Vector2(0, -20), MOUSE_BUTTON_LEFT, false)
	var da := float(a.chain.effects[0].get_param("gain_db")) - ga
	var db := float(b.chain.effects[0].get_param("gain_db")) - gb
	check(absf(da - 5.0) < 0.01 and absf(db - 5.0) < 0.01 and d.is_selected(b), "ctrl+drag: raises the gain of all selected clips by the same amount (+%.2f, +%.2f dB)" % [da, db])
	d.undo()
	check(absf(float(a.chain.effects[0].get_param("gain_db")) - ga) < 1e-6, "ctrl+drag: gain change undoes in one step")

	# Ctrl+Alt+drag: slip the audio under the clip; the clip stays.
	d.set_selection([c] as Array[AWClip])
	d.set_props(c, {"source_offset_sec": 0.2, "length_sec": 0.3}, "setup")
	var rc := grid.clip_rect(c)
	var from := rc.get_center()
	var px := grid.view.pixels_per_sec
	click(grid, from, MOUSE_BUTTON_LEFT, true, false, false, true, true)
	move(grid, from + Vector2(0.1 * px, 0), false, {"ctrl": true, "alt": true})
	click(grid, from + Vector2(0.1 * px, 0), MOUSE_BUTTON_LEFT, false)
	check(absf(c.source_offset_sec - 0.1) < 0.005 and absf(c.start_sec - 0.25) < 1e-6, "slip: dragging right by 0.1 s shows audio 0.1 s earlier, clip stays (offset %.3f)" % c.source_offset_sec)
	click(grid, from, MOUSE_BUTTON_LEFT, true, false, false, true, true)
	move(grid, from + Vector2(-5.0 * px, 0), false, {"ctrl": true, "alt": true})
	click(grid, from + Vector2(-5.0 * px, 0), MOUSE_BUTTON_LEFT, false)
	check(c.source_offset_sec <= 0.6 - 0.3 + 0.001, "slip: can't run past the end of the file (offset %.3f)" % c.source_offset_sec)

	# Groups (frames): Ctrl+G frames the selection, Ctrl+Shift+G removes the frame.
	d.set_selection([a, b] as Array[AWClip])
	key(screen, KEY_G, true)
	check(d.project.groups.size() == 1 and d.project.group_of(a) != null and d.project.group_of(a) == d.project.group_of(b), "groups: Ctrl+G frames the selection")
	d.select_clip(a)
	check(d.selection.size() == 1, "groups: clicking a clip selects only that clip")
	key(screen, KEY_G, true, true)
	check(d.project.groups.is_empty() and d.project.group_of(a) == null, "groups: Ctrl+Shift+G ungroups")
	await frames(tree, 1)

	# Double-click on empty space opens Import at that spot.
	var opened := [false]
	var on_req := func(_r: int, _t: float) -> void: opened[0] = true
	d.import_requested.connect(on_req)
	click(grid, Vector2(grid.view.time_to_x(6.0), grid.row_h * 5.5), MOUSE_BUTTON_LEFT, true, true)
	d.import_requested.disconnect(on_req)
	screen.browser.hide()
	check(opened[0], "double-click on empty space asks to import there")
	d.new_project()


## Left channel of a render at time t (seconds).
static func _at(r: PackedVector2Array, t: float) -> float:
	var i := clampi(int(t * AudioServer.get_mix_rate()), 0, r.size() - 1)
	return r[i].x


static func reverse_fade_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var e := d.engine
	d.new_project()
	# A rising ramp: the level tells where in the file we are (0 at the start, 0.5 at 1 s).
	write_wav("/tmp/aw_ramp.wav", 1.0, func(i: int, rt: int) -> Vector2i:
		var v := int(16384.0 * float(i) / rt)
		return Vector2i(v, v))
	var c := d.add_clip_from_path("/tmp/aw_ramp.wav", 0, 0.0)
	d.set_props(c, {"source_offset_sec": 0.2, "length_sec": 0.6}, "setup")
	var fwd := e.render_preview_range(0.0, 0.6)
	check(absf(_at(fwd, 0.1) - 0.15) < 0.01 and absf(_at(fwd, 0.5) - 0.35) < 0.01, "reverse: forward clip plays the ramp up (%.3f, %.3f)" % [_at(fwd, 0.1), _at(fwd, 0.5)])
	d.select_clip(c)
	d.toggle_reverse_clips(c)
	await frames(tree, 2)
	var rev := e.render_preview_range(0.0, 0.6)
	check(c.reversed and absf(_at(rev, 0.1) - 0.35) < 0.01 and absf(_at(rev, 0.5) - 0.15) < 0.01, "reverse: the same part of the file plays backwards (%.3f, %.3f)" % [_at(rev, 0.1), _at(rev, 0.5)])
	check(absf(c.source_time(0.0) - 0.8) < 1e-6 and absf(c.source_time(0.6) - 0.2) < 1e-6, "reverse: clip time maps to the file backwards")

	# Splitting a reversed clip keeps the sound identical.
	d.seek(0.25)
	d.split_selected_at_playhead()
	await frames(tree, 2)
	var split := e.render_preview_range(0.0, 0.6)
	var worst := 0.0
	for i in range(0, mini(split.size(), rev.size()), 37):
		worst = maxf(worst, absf(split[i].x - rev[i].x))
	check(d.project.clips.size() == 2 and worst < 0.002, "reverse: splitting a reversed clip doesn't change the sound (worst %.4f)" % worst)
	d.undo()
	await frames(tree, 2)

	# Trimming a reversed clip: Q at 0.2 s removes the first 0.2 s heard (the file's later part).
	d.select_clip(c)
	d.seek(0.2)
	d.trim_selected_to_playhead("start")
	await frames(tree, 2)
	check(absf(c.length_sec - 0.4) < 1e-6 and absf(c.source_offset_sec - 0.2) < 1e-6, "reverse: trimming the start keeps the file offset (offset %.3f, length %.3f)" % [c.source_offset_sec, c.length_sec])
	var tr := e.render_preview_range(0.0, 0.6)
	check(absf(_at(tr, 0.25) - _at(rev, 0.25)) < 0.01, "reverse: the rest still plays where it did (%.3f vs %.3f)" % [_at(tr, 0.25), _at(rev, 0.25)])
	d.undo()
	d.seek(0.4)
	d.trim_selected_to_playhead("end")
	check(absf(c.length_sec - 0.4) < 1e-6 and absf(c.source_offset_sec - 0.4) < 1e-6, "reverse: trimming the end moves the file offset (offset %.3f)" % c.source_offset_sec)
	d.undo()
	d.toggle_reverse_clips(c)
	check(not c.reversed, "reverse: toggles back")

	# Fade shapes: at the middle of a fade-in, Linear = 1/2, Slow = 1/4, Fast = 3/4, S-Curve = 1/2, Equal Power = 0.707.
	write_wav("/tmp/aw_dc.wav", 1.0, func(_i: int, _rt: int) -> Vector2i: return Vector2i(16384, 16384))
	d.new_project()
	var f := d.add_clip_from_path("/tmp/aw_dc.wav", 0, 0.0)
	d.set_props(f, {"fade_in_sec": 0.4}, "setup")
	var want := [0.5, 0.75, 0.25, 0.5, 0.7071]
	var got := []
	for shape in 5:
		d.select_clip(f)
		d.set_fade_shape(f, "in", shape)
		await frames(tree, 1)
		var rr := e.render_preview_range(0.0, 0.5)
		got.append(_at(rr, 0.2) / 0.5)
	var ok := true
	for k in 5:
		ok = ok and absf(got[k] - want[k]) < 0.02 and absf(AWClip.fade_gain(k, 0.5) - want[k]) < 0.001
	check(ok, "fade shapes: engine and drawing agree on each shape (%s)" % str(got))

	# Crossfade on request: overlapping clips get equal-power fades across the overlap.
	var g := d.add_clip_from_path("/tmp/aw_dc.wav", 1, 0.7)
	d.set_props(f, {"fade_in_sec": 0.0, "fade_in_shape": 0}, "setup")
	d.set_selection([f, g] as Array[AWClip])
	check(d.crossfade_selected() == 1, "crossfade: one overlapping pair")
	check(absf(f.fade_out_sec - 0.3) < 1e-4 and absf(g.fade_in_sec - 0.3) < 1e-4 and f.fade_out_shape == AWClip.FadeShape.EQUAL_POWER and g.fade_in_shape == AWClip.FadeShape.EQUAL_POWER, "crossfade: fades cover the overlap with equal-power shapes")
	await frames(tree, 1)
	var xf := e.render_preview_range(0.0, 1.7)
	check(absf(_at(xf, 0.85) - 0.5 * 2.0 * sin(PI * 0.25)) < 0.02, "crossfade: equal-power sum in the middle of the overlap (%.3f)" % _at(xf, 0.85))
	d.undo()
	check(f.fade_out_sec == 0.0 and g.fade_in_sec == 0.0, "crossfade: undoes in one step")
	d.set_selection([f] as Array[AWClip])
	check(d.crossfade_selected() == 0, "crossfade: needs overlapping clips")

	# Saved and reopened.
	d.set_props(f, {"reversed": true, "fade_out_shape": AWClip.FadeShape.S_CURVE}, "setup")
	check(d.save_project("user://aw_rev.tres") and d.load_project("user://aw_rev.tres") and d.project.clips[0].reversed and d.project.clips[0].fade_out_shape == AWClip.FadeShape.S_CURVE, "reverse and fade shape survive save and open")
	if OS.get_environment("AW_SHOTS") != "":
		d.set_props(d.project.clips[0], {"fade_in_sec": 0.3, "fade_in_shape": AWClip.FadeShape.SLOW, "fade_out_sec": 0.4}, "shot")
		d.set_props(d.project.clips[1], {"fade_in_sec": 0.3, "fade_in_shape": AWClip.FadeShape.EQUAL_POWER}, "shot")
		screen.timeline.fit_all()
		await shot(tree, "aw_grid_fades.png")
	d.new_project()


static func _peak_l(r: PackedVector2Array) -> float:
	var m := 0.0
	for f in r:
		m = maxf(m, absf(f.x))
	return m


static func row_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var e := d.engine
	var hdr := screen.timeline.headers
	var grid := screen.timeline.grid
	write_wav("/tmp/aw_row_dc.wav", 0.5, func(_i: int, _rt: int) -> Vector2i: return Vector2i(8192, 8192))
	d.new_project()
	var a := d.add_clip_from_path("/tmp/aw_row_dc.wav", 0, 0.0) # row 0: 0.25
	var b := d.add_clip_from_path("/tmp/aw_row_dc.wav", 1, 0.0) # row 1: 0.25
	d.clear_selection()
	await frames(tree, 2)
	check(hdr != null and hdr.size.x >= AWRowHeaders.WIDTH - 1.0, "rows: headers sit left of the grid")
	check(absf(_peak_l(e.render_preview_range(0.0, 0.4)) - 0.5) < 0.01, "rows: both rows play (0.5)")

	# Mute via the header's M button.
	var bt := hdr.buttons(1)
	click(hdr, (bt.mute as Rect2).get_center())
	await frames(tree, 1)
	check(d.project.row(1) != null and d.project.row(1).muted, "rows: M mutes the row")
	check(absf(_peak_l(e.render_preview_range(0.0, 0.4)) - 0.25) < 0.01, "rows: a muted row is silent")
	d.undo()
	check(not d.project.row(1).muted, "rows: mute undoes")

	# Solo: only soloed rows play; Ctrl+click solos only that row; export follows.
	click(hdr, (hdr.buttons(0).solo as Rect2).get_center())
	await frames(tree, 1)
	check(d.project.any_solo() and d.project.row_audible(0) and not d.project.row_audible(1), "rows: S solos the row")
	check(absf(_peak_l(e.render_preview_range(0.0, 0.4)) - 0.25) < 0.01, "rows: with a solo, other rows are silent")
	check(screen.export_panel.solo_note.visible, "rows: the Export dock warns that Solo is on")
	var path := ProjectSettings.globalize_path("user://aw_row_export.wav")
	var r: Dictionary = await AWExporter.new().run(d.project, path, 32)
	var w := _read_wav(path)
	var pk := 0.0
	if w.ok:
		for i in range(0, (w.samples as PackedFloat32Array).size(), 2):
			pk = maxf(pk, absf((w.samples as PackedFloat32Array)[i]))
	check(r.ok and absf(pk - 0.25) < 0.01, "rows: the export follows Solo (peak %.3f)" % pk)
	DirAccess.remove_absolute(path)
	click(hdr, (hdr.buttons(1).solo as Rect2).get_center(), MOUSE_BUTTON_LEFT, true, false, false, true)
	check(d.project.row(1).solo and not d.project.row(0).solo, "rows: Ctrl+click on S solos only that row")
	d.undo()
	d.undo()
	check(not d.project.any_solo() and not screen.export_panel.solo_note.visible, "rows: solos undo, warning goes")

	# Lock: clips on a locked row can't be selected or dragged.
	d.select_clip(a)
	click(hdr, (hdr.buttons(0).lock as Rect2).get_center())
	check(d.project.row_locked(0) and not d.is_selected(a), "rows: L locks the row and drops its clips from the selection")
	var ra := grid.clip_rect(a)
	click(grid, ra.get_center())
	click(grid, ra.get_center(), MOUSE_BUTTON_LEFT, false)
	check(not d.is_selected(a), "rows: a click doesn't select a clip on a locked row")
	drag(grid, Vector2(2, 2), Vector2(grid.size.x - 2, grid.row_h * 2.5))
	check(not d.is_selected(a) and d.is_selected(b), "rows: box select skips locked rows")
	d.undo()

	# Header click selects the row's clips; double-click renames; colour.
	click(hdr, Vector2(30, grid.row_h * 1.5))
	check(d.selection.size() == 1 and d.is_selected(b), "rows: clicking a header selects its clips")
	click(hdr, Vector2(30, grid.row_h * 1.5), MOUSE_BUTTON_LEFT, true, true)
	check(hdr._edit.visible, "rows: double-click opens the name editor")
	hdr._edit.text = "Debris"
	hdr._edit.text_submitted.emit("Debris")
	check(d.project.row_name(1) == "Debris" and d.project.row_name(0) == "Row 1", "rows: renamed (others keep their default name)")
	d.set_row_prop(1, "color", AWProject.CLIP_COLORS[2])
	check(d.project.row(1).color == AWProject.CLIP_COLORS[2], "rows: colour")

	# Saved and reopened.
	d.set_row_prop(0, "muted", true)
	check(d.save_project("user://aw_rows.tres") and d.load_project("user://aw_rows.tres") and d.project.row_name(1) == "Debris" and d.project.row(0).muted, "rows: settings survive save and open")
	if OS.get_environment("AW_SHOTS") != "":
		d.add_clip_from_path("/tmp/aw_row_dc.wav", 2, 0.3)
		d.set_row_prop(2, "solo", true)
		d.set_row_prop(2, "name", "Sweetener")
		d.set_row_prop(3, "locked", true)
		await frames(tree, 3)
		await shot(tree, "aw_row_headers.png")
	d.new_project()


static func multi_edit_tests(_tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var clips := _grid_project(d)
	var a := clips[0]
	var b := clips[1]
	var c := clips[2]
	d.set_param(b.chain.effects[0], "gain_db", -6.0)
	d.set_param(c.chain.effects[0], "pitch_semitones", 2.0)
	d.set_selection([a, b, c] as Array[AWClip])
	d._focus(a)
	var src := a.chain.effects[0]
	# A drag: previews, then restore + commit, as the Clip card does.
	d.preview_param(src, "gain_db", 1.0)
	d.preview_param(src, "gain_db", 3.0)
	check(absf(float(b.chain.effects[0].get_param("gain_db")) + 3.0) < 1e-6, "multi-edit: the drag preview moves every selected clip by the same amount")
	d.preview_param(src, "gain_db", 0.0)
	d.set_param(src, "gain_db", 3.0)
	check(absf(float(a.chain.effects[0].get_param("gain_db")) - 3.0) < 1e-6 and absf(float(b.chain.effects[0].get_param("gain_db")) + 3.0) < 1e-6 and absf(float(c.chain.effects[0].get_param("gain_db")) - 3.0) < 1e-6, "multi-edit: +3 dB on one adds 3 dB to each (balance kept)")
	d.set_param(src, "pitch_semitones", -1.0)
	check(absf(float(c.chain.effects[0].get_param("pitch_semitones")) - 1.0) < 1e-6 and absf(float(b.chain.effects[0].get_param("pitch_semitones")) + 1.0) < 1e-6, "multi-edit: pitch is relative too")
	d.undo()
	check(absf(float(c.chain.effects[0].get_param("pitch_semitones")) - 2.0) < 1e-6, "multi-edit: one undo restores every clip")
	d.set_param(src, "gain_db", 24.0)
	check(float(a.chain.effects[0].get_param("gain_db")) <= 24.0 + 1e-6 and float(c.chain.effects[0].get_param("gain_db")) <= 24.0 + 1e-6 and absf(float(b.chain.effects[0].get_param("gain_db")) - 18.0) < 1e-6, "multi-edit: each clip stays within the range")
	d.set_selection([a] as Array[AWClip])
	var bg := float(b.chain.effects[0].get_param("gain_db"))
	d.set_param(src, "gain_db", -10.0)
	check(is_equal_approx(float(b.chain.effects[0].get_param("gain_db")), bg), "multi-edit: one selected clip edits only itself")
	d.new_project()


static func timing_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var e := d.engine
	var grid := screen.timeline.grid
	var ruler: AWTimeRuler = screen.timeline._ruler
	var saved := {}
	for t: Array in AWDocument.SNAP_TARGETS:
		saved[t[0]] = d.snap_target_on(t[0])
	var clips := _grid_project(d)
	var a := clips[0] # row 0, 0.0 .. 1.0
	var b := clips[1] # row 1, 0.5 .. 1.3
	d.set_snap(0.05)
	d.seek(0.0)
	# A close zoom, so "a few pixels" is a few milliseconds whatever the test window's width.
	d.timeline_view.pixels_per_sec = 800.0
	d.timeline_view.scroll_x = 0.0
	d.timeline_view.changed.emit()
	await frames(tree, 2)
	var pps := d.timeline_view.pixels_per_sec

	# Object snapping: a clip edge within a few pixels wins over the grid; far away the grid applies.
	for k in ["edges", "playhead", "markers"]:
		d.set_snap_target(k, true)
	d.set_snap_target("transients", false)
	var tg := d.snap_targets([b])
	check(tg.has(0.0) and tg.has(1.0) and not tg.has(0.5), "snap: targets are the other clips' edges (not the dragged clip's)")
	var near := 1.0 + 4.0 / pps # 4 px right of a's end
	check(absf(d.snap_span(near, b.play_length(), tg) - 1.0) < 1e-9, "snap: a start 4 px from a clip end snaps onto it")
	var near_end := 1.0 - b.play_length() - 3.0 / pps # b's END 3 px before a's end
	check(absf(d.snap_span(near_end, b.play_length(), tg) + b.play_length() - 1.0) < 1e-9, "snap: the end of a moved clip snaps too")
	check(absf(d.snap_span(1.4321, b.play_length(), tg) - 1.45) < 1e-9, "snap: away from targets the grid applies (1.45)")
	d.set_snap_target("edges", false)
	check(absf(d.snap_span(near, b.play_length(), d.snap_targets([b])) - d.snap(near)) < 1e-9, "snap: Clip Edges off ignores edges")
	d.set_snap_target("edges", true)
	d.seek(2.2)
	check(absf(d.snap_to(2.2 + 5.0 / pps, d.snap_targets()) - 2.2) < 1e-9, "snap: the playhead attracts")
	d.set_snap(0.0)
	check(d.snap_targets().is_empty() and is_equal_approx(d.snap_to(1.234567, PackedFloat64Array([1.2345])), 1.234567), "snap: nothing snaps with snap off")
	d.set_snap(1.0 / 30.0)
	check(absf(d.snap(0.51) - 15.0 / 30.0) < 1e-9, "snap: 30 fps grid (0.51 -> frame 15)")
	d.set_snap(0.05)

	# Dragging a clip on the grid snaps its edge onto another clip's end (and shows a guide).
	d.select_clip(b)
	var rb := grid.clip_rect(b)
	var from := rb.get_center()
	var to := from + Vector2((1.0 + 3.0 / pps - b.start_sec) * pps, 0)
	click(grid, from)
	move(grid, from.lerp(to, 0.5))
	move(grid, to)
	var guide := grid._snap_hit
	click(grid, to, MOUSE_BUTTON_LEFT, false)
	check(absf(b.start_sec - 1.0) < 1e-9 and absf(guide - 1.0) < 1e-9, "snap: dragging a clip near another's end lands exactly on it (%.4f)" % b.start_sec)
	d.undo()

	# Transients: a click track yields onsets at its clicks; clips report them in project time.
	write_wav("/tmp/aw_clicks.wav", 1.0, func(i: int, rt: int) -> Vector2i:
		var t := float(i) / rt
		var v := 0
		for onset in [0.1, 0.35, 0.7]:
			if t >= onset and t < onset + 0.05:
				v = int(20000.0 * exp(-(t - onset) * 80.0) * sin(TAU * 900.0 * (t - onset)))
		return Vector2i(v, v))
	var ct := d.add_clip_from_path("/tmp/aw_clicks.wav", 3, 1.0)
	var on := d.source_transients("/tmp/aw_clicks.wav")
	var ok_on := on.size() == 3
	for k in mini(on.size(), 3):
		ok_on = ok_on and absf(on[k] - [0.1, 0.35, 0.7][k]) < 0.012
	check(ok_on, "transients: three clicks found near 0.10, 0.35, 0.70 s (%s)" % str(on))
	d.set_props(ct, {"source_offset_sec": 0.2, "length_sec": 0.7}, "setup")
	var cp := d.clip_transients(ct)
	check(cp.size() == 2 and absf(cp[0] - 1.15) < 0.012 and absf(cp[1] - 1.5) < 0.012, "transients: follow the clip's offset and position (%s)" % str(cp))
	d.set_snap_target("transients", true)
	check(d.snap_targets().has(cp[0]), "transients: are snap targets when switched on")
	d.set_snap_target("transients", false)

	# Snap menu: steps as radio items, targets as remembered checkboxes.
	var sm: MenuButton = screen.find_child("SnapMenu", true, false)
	var pop := sm.get_popup() if sm else null
	check(pop != null and pop.get_item_index(100 + 3) >= 0 and not pop.is_item_checked(pop.get_item_index(103)), "snap menu: has the target checkboxes (Transients off)")
	if pop:
		pop.id_pressed.emit(103)
		check(d.snap_target_on("transients") and pop.is_item_checked(pop.get_item_index(103)), "snap menu: ticking Transients turns it on")
		pop.id_pressed.emit(103)
		pop.id_pressed.emit(AWDocument.SNAP_OPTIONS.size() - 1)
		check(is_equal_approx(d.snap_sec, 1.0 / 60.0) and sm.text.begins_with("60 fps"), "snap menu: picking 60 fps (%s)" % sm.text)
		pop.id_pressed.emit(3)

	# Markers: M adds at the playhead; sorted; jump with Ctrl+arrows; drag on the ruler; rename; delete.
	d.seek(0.8)
	key(screen, KEY_M)
	d.seek(0.3)
	key(screen, KEY_M)
	check(d.project.markers.size() == 2 and d.project.markers[0].time_sec == 0.3 and d.project.markers[1].name == "Marker 1", "markers: M adds at the playhead, kept in time order")
	d.seek(0.0)
	key(screen, KEY_RIGHT, true)
	check(is_equal_approx(d.playhead_sec, 0.3), "markers: Ctrl+Right jumps to the next marker")
	key(screen, KEY_RIGHT, true)
	key(screen, KEY_LEFT, true)
	check(is_equal_approx(d.playhead_sec, 0.3), "markers: Ctrl+Left jumps back")
	var m1: AWMarker = d.project.markers[1]
	var mx := d.timeline_view.time_to_x(m1.time_sec)
	var ry := ruler.size.y - 6.0
	check(ruler.marker_at(Vector2(mx + 2, ry)) == m1, "markers: the ruler finds a marker under the mouse")
	click(ruler, Vector2(mx, ry))
	move(ruler, Vector2(d.timeline_view.time_to_x(1.0) + 3.0, ry))
	click(ruler, Vector2(d.timeline_view.time_to_x(1.0) + 3.0, ry), MOUSE_BUTTON_LEFT, false)
	check(absf(m1.time_sec - 1.0) < 1e-9, "markers: dragging on the ruler moves it (snapped to the clip end, %.4f)" % m1.time_sec)
	d.undo()
	check(absf(m1.time_sec - 0.8) < 1e-9, "markers: the move undoes")
	ruler.start_marker_rename(m1)
	ruler._rename.text = "Impact"
	ruler._rename.text_submitted.emit("Impact")
	check(m1.name == "Impact", "markers: renamed")

	# WAV export writes cue points with names, and the loop as a sampler loop Godot detects.
	d.set_props(d.project, {"loop_enabled": true, "loop_start_sec": 0.25, "loop_end_sec": 0.75}, "setup")
	var path := ProjectSettings.globalize_path("user://aw_cues.wav")
	var rx: Dictionary = await AWExporter.new().run(d.project, path, 16)
	var by := FileAccess.get_file_as_bytes(path)
	var chunks := {}
	var pos := 12
	while pos + 8 <= by.size():
		var cid := by.slice(pos, pos + 4).get_string_from_ascii()
		var clen := by.decode_u32(pos + 4)
		chunks[cid] = by.slice(pos + 8, pos + 8 + clen)
		pos += 8 + clen + (clen & 1)
	var rate := int(AudioServer.get_mix_rate())
	var cue: PackedByteArray = chunks.get("cue ", PackedByteArray())
	check(rx.ok and by.decode_u32(4) == by.size() - 8, "wav cues: RIFF size covers the extra chunks")
	check(cue.size() == 4 + 48 and cue.decode_u32(0) == 2 and cue.decode_u32(4 + 20) == int(round(0.3 * rate)) and cue.decode_u32(28 + 20) == int(round(0.8 * rate)), "wav cues: two cue points at the markers")
	var lst: PackedByteArray = chunks.get("LIST", PackedByteArray())
	check(lst.size() > 4 and lst.slice(0, 4).get_string_from_ascii() == "adtl" and lst.hex_encode().contains("Impact".to_utf8_buffer().hex_encode()), "wav cues: marker names as labels")
	var smpl: PackedByteArray = chunks.get("smpl", PackedByteArray())
	check(smpl.size() == 60 and smpl.decode_u32(28) == 1 and smpl.decode_u32(44) == int(round(0.25 * rate)), "wav cues: the loop as a smpl loop")
	var lw := AudioStreamWAV.load_from_file(path, {"edit/loop_mode": 0})
	check(lw != null and lw.loop_mode != AudioStreamWAV.LOOP_DISABLED and absi(lw.loop_begin - int(round(0.25 * rate))) <= 1 and absi(lw.loop_end - int(round(0.75 * rate))) <= 1, "wav cues: Godot's importer detects the loop (%s..%s)" % [str(lw.loop_begin if lw else -1), str(lw.loop_end if lw else -1)])
	var w := _read_wav(path)
	check(w.ok and absi(int(w.frames) - int(rx.frames)) <= 0, "wav cues: the audio data is unchanged")
	d.set_props(d.project, {"loop_enabled": false}, "setup")
	DirAccess.remove_absolute(path)
	d.remove_marker(d.project.markers[0])
	check(d.project.markers.size() == 1 and d.project.markers[0] == m1, "markers: deleted")
	check(d.save_project("user://aw_markers.tres") and d.load_project("user://aw_markers.tres") and d.project.markers.size() == 1 and d.project.markers[0].name == "Impact", "markers: survive save and open")
	clips = []
	for cc in d.project.clips:
		clips.append(cc)

	# Time selection: Shift+drag on the ruler, then split / delete inside / loop.
	a = d.project.clips[0]
	var ya := ruler.size.y - 6.0
	click(ruler, Vector2(d.timeline_view.time_to_x(0.2), ya), MOUSE_BUTTON_LEFT, true, false, true)
	move(ruler, Vector2(d.timeline_view.time_to_x(0.6), ya))
	click(ruler, Vector2(d.timeline_view.time_to_x(0.6), ya), MOUSE_BUTTON_LEFT, false)
	check(d.has_time_selection() and absf(d.time_sel.x - 0.2) < 1e-6 and absf(d.time_sel.y - 0.6) < 1e-6, "time selection: Shift+drag on the ruler selects 0.2 to 0.6 s (%s)" % str(d.time_sel))
	var n0 := d.project.clips.size()
	var before := e.render_preview_range(0.0, 1.5)
	check(d.split_at_time_selection() == 2, "time selection: split cuts the two clips it crosses")
	check(d.project.clips.size() == n0 + 3, "time selection: a clip crossing both edges becomes three, one crossing one edge two")
	var after := e.render_preview_range(0.0, 1.5)
	var worst := 0.0
	for i in range(0, mini(before.size(), after.size()), 23):
		worst = maxf(worst, absf(before[i].x - after[i].x))
	check(worst < 0.002, "time selection: splitting doesn't change the sound (worst %.4f)" % worst)
	d.undo()
	check(d.project.clips.size() == n0, "time selection: split undoes in one step")
	d.clear_selection()
	key(screen, KEY_DELETE)
	var cut := e.render_preview_range(0.0, 1.5)
	var inside := 0.0
	var outside := 0.0
	for i in range(int(0.22 * rate), int(0.58 * rate)):
		inside = maxf(inside, absf(cut[i].x))
	for i in range(int(0.62 * rate), int(0.95 * rate)):
		outside = maxf(outside, absf(cut[i].x))
	check(inside < 1e-4 and outside > 0.05, "time selection: Delete removes the audio inside, keeps the rest (inside %.5f, after %.3f)" % [inside, outside])
	d.undo()
	d.loop_time_selection()
	check(d.project.loop_enabled and is_equal_approx(d.project.loop_start_sec, 0.2) and is_equal_approx(d.project.loop_end_sec, 0.6), "time selection: Loop Selection sets the loop")
	key(screen, KEY_ESCAPE)
	check(not d.has_time_selection(), "time selection: Esc clears it")

	# Loop strip: dragging anywhere on it sets new loop bounds.
	click(ruler, Vector2(d.timeline_view.time_to_x(1.1), 4))
	move(ruler, Vector2(d.timeline_view.time_to_x(1.6), 4))
	click(ruler, Vector2(d.timeline_view.time_to_x(1.6), 4), MOUSE_BUTTON_LEFT, false)
	check(is_equal_approx(d.project.loop_start_sec, 1.1) and is_equal_approx(d.project.loop_end_sec, 1.6), "loop strip: a drag sets the loop bounds (%.2f..%.2f)" % [d.project.loop_start_sec, d.project.loop_end_sec])
	click(ruler, Vector2(d.timeline_view.time_to_x(1.3), 4))
	move(ruler, Vector2(d.timeline_view.time_to_x(1.4), 4))
	click(ruler, Vector2(d.timeline_view.time_to_x(1.4), 4), MOUSE_BUTTON_LEFT, false)
	check(is_equal_approx(d.project.loop_start_sec, 1.3) and is_equal_approx(d.project.loop_end_sec, 1.4), "loop strip: dragging inside the loop sets new bounds too")

	# Scrub: a drag on the ruler scrubs and leaves the playhead where it ends.
	click(ruler, Vector2(d.timeline_view.time_to_x(0.1), ya))
	move(ruler, Vector2(d.timeline_view.time_to_x(0.3), ya))
	check(d.scrubbing and e.core.call("is_scrubbing"), "scrub: dragging on the ruler scrubs")
	move(ruler, Vector2(d.timeline_view.time_to_x(0.5), ya))
	await frames(tree, 3)
	click(ruler, Vector2(d.timeline_view.time_to_x(0.5), ya), MOUSE_BUTTON_LEFT, false)
	check(not d.scrubbing and not e.core.call("is_scrubbing") and absf(d.playhead_sec - 0.5) < 0.01, "scrub: release ends it at the mouse (%.3f)" % d.playhead_sec)

	# The scrub sound itself (same code as the audio thread, run directly): grains at normal pitch
	# that follow the mouse (owner choice), forward or backward, silent when the mouse holds still.
	write_wav("/tmp/aw_scrub_ramp.wav", 2.0, func(i: int, rt: int) -> Vector2i: return Vector2i(int(16000.0 * float(i) / (rt * 2.0)), 0))
	d.new_project()
	d.add_clip_from_path("/tmp/aw_scrub_ramp.wav", 0, 0.0)
	await frames(tree, 2)
	var block := 256
	var rslope := 0.5 / (2.0 * rate)
	var tgt := PackedFloat64Array()
	for k in 200: # a slow drag, 0.25x, from 0.5 s
		tgt.append(0.5 + 0.25 * float(k + 1) * block / rate)
	var fw := e.scrub_simulate(tgt, block)
	var near_ok := true
	for k in range(60, 190, 10):
		var i := k * block + block / 2
		var at_target := tgt[k] * rate * rslope
		if absf(fw[i].x) > 0.02 and absf(fw[i].x - at_target) > 0.05 * rate * rslope:
			near = false
	check(fw.size() == 200 * block and near_ok, "scrub: what you hear comes from where the mouse is (within 50 ms)")
	check(fw[int(fw.size() * 0.9)].x > fw[int(fw.size() * 0.5)].x, "scrub: dragging right moves forward through the sound")
	var bk := PackedFloat64Array()
	for k in 200:
		bk.append(1.5 - 0.25 * float(k + 1) * block / rate)
	var bw := e.scrub_simulate(bk, block)
	var lv_b := 0.0
	for f in bw.slice(bw.size() / 2):
		lv_b = maxf(lv_b, absf(f.x))
	check(lv_b > 0.2 and bw[int(bw.size() * 0.9)].x < bw[int(bw.size() * 0.5)].x, "scrub: dragging left plays from earlier and earlier positions")
	# Normal pitch and full level even on a slow drag: a 440 Hz tone stays 440 Hz.
	write_wav("/tmp/aw_scrub_tone.wav", 2.0, func(i: int, rt: int) -> Vector2i:
		var v := int(16000.0 * sin(TAU * 440.0 * i / rt))
		return Vector2i(v, v))
	d.new_project()
	d.add_clip_from_path("/tmp/aw_scrub_tone.wav", 0, 0.0)
	await frames(tree, 2)
	var slow := PackedFloat64Array()
	for k in 300: # 0.1x
		slow.append(0.5 + 0.1 * float(k + 1) * block / rate)
	var slw := e.scrub_simulate(slow, block)
	var part := slw.slice(int(slw.size() * 0.3), int(slw.size() * 0.95))
	var crossings := 0
	var rms := 0.0
	for i in range(1, part.size()):
		if (part[i - 1].x < 0.0) != (part[i].x < 0.0):
			crossings += 1
		rms += part[i].x * part[i].x
	rms = sqrt(rms / part.size())
	var hz := crossings / 2.0 / (part.size() / float(rate))
	print("SCRUB slow drag on 440 Hz: %.1f Hz, rms %.3f (source %.3f)" % [hz, rms, 0.4883 / sqrt(2.0)])
	check(absf(hz - 440.0) < 440.0 * 0.06, "scrub: a slow drag keeps the sound's pitch (%.0f Hz from a 440 Hz tone)" % hz)
	check(rms > 0.25, "scrub: and its level (rms %.2f)" % rms)
	var still := PackedFloat64Array()
	still.resize(120)
	still.fill(1.0)
	var st := e.scrub_simulate(still, block)
	var tail := 0.0
	for f in st.slice(st.size() - 4096):
		tail = maxf(tail, absf(f.x))
	check(tail < 0.001, "scrub: a still mouse is silent")

	for k: String in saved:
		d.set_snap_target(k, saved[k])
	d.new_project()


## Middle-button drag on a control: press, one motion by `rel`, release (Shift = zoom).
static func mid_drag(ctrl: Control, at: Vector2, rel: Vector2, shift := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_MIDDLE
	e.pressed = true
	e.shift_pressed = shift
	e.position = at
	e.global_position = ctrl.get_global_transform() * at
	ctrl._gui_input(e)
	var m := InputEventMouseMotion.new()
	m.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	m.shift_pressed = shift
	m.position = at + rel
	m.global_position = ctrl.get_global_transform() * (at + rel)
	m.relative = rel
	ctrl._gui_input(m)
	var r := InputEventMouseButton.new()
	r.button_index = MOUSE_BUTTON_MIDDLE
	r.pressed = false
	r.position = at + rel
	ctrl._gui_input(r)


static func layer_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	print("--- timeline layers and navigation ---")
	var d := screen.doc
	var tl := screen.timeline
	var clips := _grid_project(d)
	d.set_edit_mode(AWDocument.EditMode.CLIPS)
	await frames(tree, 3)
	var v := d.timeline_view
	var g := tl.graph
	var grid := tl.grid
	check(d.curve_view == d.timeline_view and g.view == grid.view, "layers: curves share the grid's time axis")
	check(g.mouse_filter == Control.MOUSE_FILTER_IGNORE and is_equal_approx(tl.scroll.modulate.a, 1.0) and not tl.dots.is_visible_in_tree(), "layers: clip mode edits the grid; curve layer ignores the mouse, no curve column")
	check(absf(g.global_position.x - grid.global_position.x) < 0.5 and absf(g.size.x - grid.size.x) < 0.5, "layers: the curve layer lies exactly over the grid (x %.0f / %.0f, w %.0f / %.0f)" % [g.global_position.x, grid.global_position.x, g.size.x, grid.size.x])

	# Middle-drag pans, Shift+middle-drag zooms anchored at the top-left.
	v.frame(0.0, 2.0)
	tl.set_row_height(48.0, 0.0)
	await frames(tree, 1)
	var t0 := v.x_to_time(0.0) + 0.0
	mid_drag(grid, Vector2(200, 30), Vector2(-100, 0))
	check(absf(v.x_to_time(0.0) - (t0 + 100.0 / v.pixels_per_sec)) < 1e-3, "pan: middle-drag left moves time with the mouse")
	mid_drag(grid, Vector2(200, 30), Vector2(0, -60))
	check(absf(tl.row_scroll() - 60.0) < 1.5, "pan: middle-drag up scrolls the rows (%.0f px)" % tl.row_scroll())
	var under := v.x_to_time(300.0)
	var pps := v.pixels_per_sec
	mid_drag(grid, Vector2(300, 30), Vector2(80, 0), true)
	check(v.pixels_per_sec > pps * 1.8 and absf(v.x_to_time(300.0) - under) < 1e-3, "zoom: Shift+middle-drag right zooms time in around the press (the moment under it stays: %.3f s)" % under)
	tl.set_row_scroll(96.0)
	await frames(tree, 1) # the scroll container moves the grid on its next layout pass
	var rh := grid.row_h
	var press_y := tl.row_scroll() + 30.0
	var row_under := grid.y_to_rowf(press_y)
	mid_drag(grid, Vector2(300, press_y), Vector2(0, 40), true)
	await frames(tree, 1)
	check(grid.row_h > rh * 1.3 and absf(grid.y_to_rowf(tl.row_scroll() + 30.0) - row_under) < 0.05, "zoom: Shift+middle-drag down makes rows taller around the press (row %.2f stays under it: %.2f)" % [row_under, grid.y_to_rowf(tl.row_scroll() + 30.0)])
	# 1:1: a drag out and back in many small steps ends where it began, whatever the path.
	var pps1 := v.pixels_per_sec
	var rh1 := grid.row_h
	var left1 := v.x_to_time(0.0)
	var top1 := grid.y_to_rowf(tl.row_scroll())
	var at := Vector2(300, tl.row_scroll() + 30.0)
	var under1 := v.x_to_time(300.0)
	var pe := InputEventMouseButton.new()
	pe.button_index = MOUSE_BUTTON_MIDDLE
	pe.pressed = true
	pe.shift_pressed = true
	pe.position = at
	pe.global_position = grid.get_global_transform() * at
	grid._gui_input(pe)
	var path: Array[Vector2] = [Vector2(15, 7), Vector2(40, 22), Vector2(-10, 30), Vector2(25, -12), Vector2(0, 0)]
	var mid_ok := true
	for off: Vector2 in path:
		var me := InputEventMouseMotion.new()
		me.button_mask = MOUSE_BUTTON_MASK_MIDDLE
		me.shift_pressed = true
		me.position = at + off
		me.global_position = grid.get_global_transform() * (at + off)
		grid._gui_input(me)
		if off == Vector2(40, 22):
			mid_ok = absf(v.pixels_per_sec - pps1 * exp(40.0 * AWTimelinePane.ZOOM_DRAG)) < 0.5 and absf(v.x_to_time(300.0) - under1) < 1e-3
	var re := InputEventMouseButton.new()
	re.button_index = MOUSE_BUTTON_MIDDLE
	re.global_position = grid.get_global_transform() * at
	grid._gui_input(re)
	await frames(tree, 1)
	check(mid_ok and absf(v.pixels_per_sec - pps1) < 0.01 and absf(grid.row_h - rh1) < 0.01 and absf(v.x_to_time(0.0) - left1) < 1e-4 and absf(grid.y_to_rowf(tl.row_scroll()) - top1) < 0.05, "zoom: follows the mouse 1:1 from where the drag began; back at the start it is undone")

	# Scale handles on the scrollbars.
	v.frame(0.0, 2.0)
	await frames(tree, 1)
	var hb := tl.hbar
	var th := hb.thumb_px()
	var a0 := v.x_to_time(0.0)
	var span0 := v.x_to_time(v.view_width) - a0
	drag(hb, Vector2(th.y - 3.0, 6), Vector2(th.y - 3.0 - (th.y - th.x) * 0.5, 6))
	var span1 := v.x_to_time(v.view_width) - v.x_to_time(0.0)
	check(span1 < span0 * 0.7 and absf(v.x_to_time(0.0) - a0) < 1e-3, "scale bar: dragging the thumb's right end zooms time in, start fixed (%.2f -> %.2f s)" % [span0, span1])
	v.scroll_by(200.0)
	await frames(tree, 1)
	th = hb.thumb_px()
	var b0 := v.x_to_time(v.view_width)
	drag(hb, Vector2(th.x + 3.0, 6), Vector2(th.x + 3.0 - 20.0, 6))
	check(absf(v.x_to_time(v.view_width) - b0) < 0.01 and v.x_to_time(v.view_width) - v.x_to_time(0.0) > span1 * 1.05, "scale bar: dragging the left end zooms out, end fixed")
	th = hb.thumb_px()
	var span2 := v.x_to_time(v.view_width) - v.x_to_time(0.0)
	var s2 := v.x_to_time(0.0)
	drag(hb, Vector2((th.x + th.y) * 0.5, 6), Vector2((th.x + th.y) * 0.5 + 15.0, 6))
	check(v.x_to_time(0.0) > s2 + 0.01 and absf(v.x_to_time(v.view_width) - v.x_to_time(0.0) - span2) < 1e-3, "scale bar: dragging the middle scrolls without zooming")
	th = hb.thumb_px()
	click(hb, Vector2((th.x + th.y) * 0.5, 6), MOUSE_BUTTON_LEFT, true, true)
	click(hb, Vector2((th.x + th.y) * 0.5, 6), MOUSE_BUTTON_LEFT, false)
	check(v.x_to_time(0.0) <= 0.0 + 1e-6 and v.x_to_time(v.view_width) >= d.project.content_end_sec(), "scale bar: double-click fits time")
	tl.set_row_height(48.0, 0.0)
	tl.set_row_scroll(48.0)
	await frames(tree, 1)
	var vb := tl.vbar
	var vt := vb.thumb_px()
	var rh2 := grid.row_h
	var top2 := tl.row_scroll() / rh2
	drag(vb, Vector2(6, vt.y - 3.0), Vector2(6, vt.y - 3.0 + 40.0))
	await frames(tree, 1)
	check(grid.row_h < rh2 * 0.95 and absf(tl.row_scroll() / grid.row_h - top2) < 0.1, "scale bar: dragging the vertical thumb's end shows more rows, top row fixed (%.0f -> %.0f px)" % [rh2, grid.row_h])

	# Fit, where the scrollbars meet.
	v.zoom_by(6.0)
	v.scroll_to(300.0)
	tl.set_row_height(100.0)
	tl.set_row_scroll(200.0)
	tl.fit_button.pressed.emit()
	await frames(tree, 1)
	check(v.x_to_time(0.0) <= 0.0 + 1e-6 and v.x_to_time(v.view_width) >= d.project.content_end_sec() and tl.row_scroll() < 1.0, "fit: both axes fit (time 0 to the end, rows from the top)")

	# Tab switches modes; clicks reach only the active layer.
	grid.grab_focus()
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.pressed = true
	screen._input(tab)
	await frames(tree, 1)
	check(d.edit_mode == AWDocument.EditMode.CURVES and g.mouse_filter == Control.MOUSE_FILTER_STOP and absf(tl.scroll.modulate.a - 0.3) < 0.01 and tl.dots.is_visible_in_tree(), "Tab: curve mode (grid faded, curve layer on top, value axis shown)")
	var cpos := grid.get_global_transform() * grid.clip_rect(clips[1]).get_center()
	d.clear_selection()
	for pressed: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = cpos
		e.global_position = cpos
		tree.root.push_input(e)
	await frames(tree, 1)
	check(d.selection.is_empty(), "curve mode: a click over a clip doesn't reach the grid")
	screen._input(tab)
	await frames(tree, 1)
	for pressed: bool in [true, false]:
		var e2 := InputEventMouseButton.new()
		e2.button_index = MOUSE_BUTTON_LEFT
		e2.pressed = pressed
		e2.position = cpos
		e2.global_position = cpos
		tree.root.push_input(e2)
	await frames(tree, 1)
	check(d.edit_mode == AWDocument.EditMode.CLIPS and d.is_selected(clips[1]), "Tab back: clip mode, the same click selects the clip")
	var le := LineEdit.new()
	screen.add_child(le)
	le.grab_focus()
	screen._input(tab)
	check(d.edit_mode == AWDocument.EditMode.CLIPS, "Tab in a text field is left alone")
	le.queue_free()

	# Opening a curve enters curve mode.
	var a := clips[0]
	d.select_clip(a)
	d.set_edit_mode(AWDocument.EditMode.CLIPS)
	var gc := d.make_curve(a.chain, a.chain.effects[0], "gain_db")
	check(d.edit_mode == AWDocument.EditMode.CURVES and d.active_curve == gc, "Make Curve switches to curve mode")
	d.set_active_curve(null)
	check(d.edit_mode == AWDocument.EditMode.CURVES, "deselecting a curve stays in curve mode")

	# Value axis: pan and zoom.
	await frames(tree, 2)
	d.value_view.reset()
	var v_under := g.y_to_val_unclamped(40.0)
	mid_drag(g, Vector2(100, 40), Vector2(0, 40), true)
	check(d.value_view.span < 0.75 and absf(g.y_to_val_unclamped(40.0) - v_under) < 1e-3, "values: Shift+middle-drag down zooms in around the press (value %.2f stays under it; span %.2f)" % [v_under, d.value_view.span])
	var lo0 := d.value_view.lo
	var uh := g.unit_h()
	mid_drag(g, Vector2(100, 40), Vector2(0, -20))
	check(absf(d.value_view.lo - (lo0 - 20.0 / uh)) < 1e-3 or (lo0 - 20.0 / uh < 0.0 and d.value_view.lo == 0.0), "values: middle-drag up pans down the value range")
	var y_half := g.val_to_y(gc, 0.5)
	check(absf(g.y_to_val(gc, y_half) - 0.5) < 1e-4, "values: the value mapping round-trips when zoomed")
	key(screen, KEY_F)
	check(is_equal_approx(d.value_view.span, 1.0) and d.value_view.lo == 0.0, "F in curve mode resets the value zoom")

	# A key placed on the layer lands at the right project and clip time (pitched clip).
	d.set_param(a.chain.effects[0], "pitch_semitones", -12.0)
	v.frame(0.0, d.project.content_end_sec())
	await frames(tree, 2)
	var tp := 1.2
	d.set_active_curve(gc)
	var ins := Vector2(v.time_to_x(tp), g.val_to_y(gc, 0.3))
	var nk := a.chain.get_keys(gc).size()
	click(g, ins, MOUSE_BUTTON_LEFT, true, true)
	click(g, ins, MOUSE_BUTTON_LEFT, false)
	var found := false
	for k: Dictionary in a.chain.get_keys(gc):
		found = found or absf(k.t - a.project_to_local(tp)) < 1e-3
	check(a.chain.get_keys(gc).size() == nk + 1 and found, "key placed at project %.2f s lands at clip time %.2f s (pitched -12)" % [tp, a.project_to_local(tp)])
	d.undo()
	d.undo()

	# Shared chains: the focused clip edits, the chain's other clips show faint copies.
	d.select_clip(clips[1])
	var shared := d.new_chain_for(clips[1])
	d.set_clip_chain(clips[2], shared)
	d.select_clip(clips[1])
	await frames(tree, 2)
	var copies := g.copy_clips()
	check(d.chain_tab == AWDocument.ChainTab.CHAIN and copies.size() == 1 and copies[0] == clips[2], "shared chain: copies drawn over the chain's other clips (%d)" % copies.size())
	if OS.get_environment("AW_SHOTS") != "":
		var lp := d.add_effect(shared, "Low Pass")
		d.make_curve(shared, lp, "cutoff_hz")
		await shot(tree, "aw_curve_layer.png")
		d.set_edit_mode(AWDocument.EditMode.CLIPS)
		await shot(tree, "aw_clip_layer.png")
	d.set_edit_mode(AWDocument.EditMode.CLIPS)


static func group_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	print("--- groups (frames) ---")
	var d := screen.doc
	var tl := screen.timeline
	var grid := tl.grid
	var clips := _grid_project(d)
	var a := clips[0]
	var b := clips[1]
	var c := clips[2]
	d.set_edit_mode(AWDocument.EditMode.CLIPS)
	d.timeline_view.frame(0.0, 3.0)
	tl.set_row_height(48.0, 0.0)
	await frames(tree, 2)
	d.set_selection([a, b] as Array[AWClip])
	var g := d.group_selected()
	await frames(tree, 1)
	check(g != null and is_equal_approx(g.start_sec, 0.0) and absf(g.end_sec - b.end_sec()) < 1e-6 and g.row == 0 and g.row_count == 2, "group: frame spans the selection (0 to %.2f s, rows 1-2)" % (g.end_sec if g else -1.0))
	check(d.project.group_clips(g) == [a, b] and d.selected_group == g, "group: its clips are the ones inside the frame; it is selected")
	check(is_equal_approx(grid.row_top(0), AWClipGrid.STRIP_H) and is_equal_approx(grid.strip_rect(g).position.y, 0.0) and grid.clip_rect(a).position.y > AWClipGrid.STRIP_H, "group: its strip sits above the first row; no clip is covered")
	check(d.project.groups.size() == 1, "group: one group")
	d.select_clip(a)
	check(d.selection == [a] and d.selected_group == null, "group: clicking a clip selects just that clip")
	# Overlap is refused.
	d.set_selection([b, c] as Array[AWClip])
	check(d.group_selected() == null and d.project.groups.size() == 1, "group: a frame that would overlap another is refused")
	# Live membership.
	c.row = 1
	c.start_sec = 0.6
	check(d.project.group_of(c) == g, "group: a clip moved inside the frame joins")
	c.row = 2
	c.start_sec = 1.0
	check(d.project.group_of(c) == null, "group: moved out again, it leaves")
	d.project_changed.emit(true)
	await frames(tree, 1)

	# Drag the strip: the group moves with its clips, one undo step.
	var px := d.timeline_view.pixels_per_sec
	var sr := grid.strip_rect(g)
	var from := Vector2(sr.position.x + sr.size.x * 0.5, sr.position.y + sr.size.y * 0.5)
	drag(grid, from, from + Vector2(0.5 * px, 0))
	check(absf(g.start_sec - 0.5) < 1e-4 and absf(a.start_sec - 0.5) < 1e-4 and absf(b.start_sec - 1.0) < 1e-4 and absf(c.start_sec - 1.0) < 1e-6, "group: dragging the strip moves the frame and its clips (c stays)")
	d.undo()
	check(is_equal_approx(g.start_sec, 0.0) and is_equal_approx(a.start_sec, 0.0) and is_equal_approx(b.start_sec, 0.5), "group: one undo puts the group and its clips back")
	# Right end: wider span.
	sr = grid.strip_rect(g)
	drag(grid, Vector2(sr.end.x - 2.0, sr.position.y + 9.0), Vector2(d.timeline_view.time_to_x(2.0), sr.position.y + 9.0))
	check(absf(g.end_sec - 2.0) < 1e-4 and is_equal_approx(g.start_sec, 0.0), "group: dragging the strip's right end sets the span (to %.2f s)" % g.end_sec)
	# Rows handle: drag down one row; c (row 3, starting at 1.0 s) joins.
	var hr := grid.handle_rect(g)
	var hfrom := Vector2(hr.get_center().x, hr.end.y - 6.0)
	var y3 := grid.row_top(2) + grid.row_height(2) * 0.5
	drag(grid, hfrom, Vector2(hfrom.x, y3))
	check(g.row_count == 3 and d.project.group_of(c) == g, "group: the rows handle takes in another row, and its clip joins")
	d.undo()
	check(g.row_count == 2 and d.project.group_of(c) == null, "group: undo the rows handle")
	await frames(tree, 1)

	# Strip buttons: mute, solo, collapse.
	var bt := grid._strip_buttons(g)
	click(grid, (bt["mute"] as Rect2).get_center())
	click(grid, (bt["mute"] as Rect2).get_center(), MOUSE_BUTTON_LEFT, false)
	check(g.muted and not d.project.is_clip_audible(a) and d.project.is_clip_audible(c), "group: M mutes the group's clips only")
	d.undo()
	click(grid, (bt["solo"] as Rect2).get_center())
	click(grid, (bt["solo"] as Rect2).get_center(), MOUSE_BUTTON_LEFT, false)
	check(g.solo and d.project.is_clip_audible(a) and not d.project.is_clip_audible(c), "group: S solos the group (others fall silent)")
	d.undo()
	var h_before := grid.content_height()
	click(grid, (bt["collapse"] as Rect2).get_center())
	click(grid, (bt["collapse"] as Rect2).get_center(), MOUSE_BUTTON_LEFT, false)
	await frames(tree, 1)
	check(g.collapsed and is_equal_approx(grid.row_height(0), AWClipGrid.COLLAPSED_ROW_H) and grid.content_height() < h_before and d.project.is_clip_audible(a), "group: collapse folds its rows (the clips still play)")
	if OS.get_environment("AW_SHOTS") != "":
		await shot(tree, "aw_group_collapsed.png")
	# Dragging a collapsed group down moves it steadily (no jumping back and forth between rows).
	var csr := grid.strip_rect(g)
	var cfrom := Vector2(csr.get_center().x, csr.get_center().y)
	click(grid, cfrom)
	var rows_seen: Array[int] = []
	for k in range(1, 41):
		move(grid, cfrom + Vector2(0, k * grid.row_h * 3.0 / 40.0))
		rows_seen.append(g.row)
	click(grid, cfrom + Vector2(0, grid.row_h * 3.0), MOUSE_BUTTON_LEFT, false)
	var steady := true
	for k in range(1, rows_seen.size()):
		steady = steady and rows_seen[k] >= rows_seen[k - 1]
	check(steady and g.row >= 1 and g.collapsed, "group: a collapsed group dragged down moves steadily (rows %s)" % str(rows_seen.slice(0, 40, 4)))
	d.undo()
	d.undo()
	await frames(tree, 1)
	check(not g.collapsed and is_equal_approx(grid.row_height(0), grid.row_h), "group: expand again")

	# The group chain is a bus: its clips are mixed, then processed once.
	var e := d.engine
	if e.is_available():
		var peak := func(buf: PackedVector2Array) -> float:
			var m := 0.0
			for f in buf:
				m = maxf(m, maxf(absf(f.x), absf(f.y)))
			return m
		var dry_both: float = peak.call(e.render_preview_range(0.6, 0.35))
		var dry_c: float = peak.call(e.render_preview_range(1.35, 0.1))
		var gch := d.new_group_chain(g)
		check(d.chain_tab == AWDocument.ChainTab.GROUP and d.active_chain() == gch and is_equal_approx(d.local_to_view(0.0), g.start_sec), "group chain: its tab shows, curves on the group's clock")
		var lim := d.add_effect(gch, "Limiter")
		d.set_param(lim, "ceiling_db", -12.0)
		var bus_both: float = peak.call(e.render_preview_range(0.6, 0.35))
		var bus_c: float = peak.call(e.render_preview_range(1.35, 0.1))
		check(dry_both > 0.3 and bus_both <= db_to_linear(-12.0) * 1.05, "group chain: a limiter on the group holds the mixed clips to its ceiling (%.2f -> %.2f; per-clip limiting would let ~0.5 through)" % [dry_both, bus_both])
		check(absf(bus_c - dry_c) < 1e-4, "group chain: a clip outside the group is unaffected")
		if OS.get_environment("AW_SHOTS") != "":
			await shot(tree, "aw_group_chain.png")
		d.remove_group_chain(g)
		check(g.chain == null, "group chain: removed")

	# Save, open, and the format-7 migration.
	var path := ProjectSettings.globalize_path("user://aw_groups.tres")
	AWProjectIO.save(d.project, path, false)
	var o := AWProjectIO.open(path)
	check(o.ok and o.project.groups.size() == 1 and o.project.groups[0].row_count == 2 and o.project.groups[0].name == g.name, "group: saved and opened")
	DirAccess.remove_absolute(path)
	var old := AWProject.create_default()
	var oa := AWClip.create("a", 0.2, 1.0, 1, Color.RED)
	var ob := AWClip.create("b", 0.8, 0.5, 2, Color.RED)
	var oc := AWClip.create("c", 3.0, 0.5, 0, Color.RED)
	oa.group_id = 4
	ob.group_id = 4
	old.clips.append_array([oa, ob, oc])
	old.format_version = 7
	var opath := ProjectSettings.globalize_path("user://aw_old7.tres")
	ResourceSaver.save(old, opath)
	var oo := AWProjectIO.open(opath)
	var og: AWGroup = oo.project.groups[0] if oo.ok and not oo.project.groups.is_empty() else null
	check(og != null and is_equal_approx(og.start_sec, 0.2) and is_equal_approx(og.end_sec, 1.3) and og.row == 1 and og.row_count == 2 and oo.project.clips[0].group_id == 0, "group: format 7 group ids become a frame")
	DirAccess.remove_absolute(opath)
	if OS.get_environment("AW_SHOTS") != "":
		d.select_group(g)
		await shot(tree, "aw_groups.png")


static func navigation_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var tl := screen.timeline
	var clips := _grid_project(d)
	await frames(tree, 2)
	# Z zooms to the selected clips, or to the time selection.
	d.select_clip(clips[1])
	key(screen, KEY_Z)
	var v := d.timeline_view
	check(v.x_to_time(0.0) <= clips[1].start_sec and v.x_to_time(v.view_width) >= clips[1].end_sec() and v.x_to_time(v.view_width) - v.x_to_time(0.0) < clips[1].play_length() * 1.2, "zoom: Z frames the selected clip")
	d.set_time_selection(0.1, 0.2)
	key(screen, KEY_Z)
	check(absf(v.x_to_time(v.view_width) - v.x_to_time(0.0) - 0.1 / 0.92) < 0.01, "zoom: Z frames the time selection")
	d.clear_time_selection()
	# Hover info on a clip.
	var grid := tl.grid
	v.frame(0.0, 2.0)
	await frames(tree, 1)
	var tip := grid._get_tooltip(grid.clip_rect(clips[0]).get_center())
	check(tip.contains(clips[0].name) and tip.contains("Gain") and tip.contains(clips[0].source_path), "hover: a clip's tooltip shows file, gain and more")
	if OS.get_environment("AW_SHOTS") != "":
		d.set_time_selection(0.35, 0.65)
		d.seek(0.9)
		d.add_marker(0.2, "Hit")
		d.add_marker(1.2, "Tail")
		d.set_snap_target("transients", true)
		var hs := tl.get_parent() as HSplitContainer
		var keep_off := hs.split_offset if hs else 0
		if hs:
			hs.split_offset = 420
		await frames(tree, 3)
		v.frame(0.0, 1.7)
		await frames(tree, 3)
		await shot(tree, "aw_timing.png")
		if hs:
			hs.split_offset = keep_off
		d.set_snap_target("transients", false)
	d.new_project()


static func shared_chain_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var e := d.engine
	var cp := screen.chain_panel
	var rate := AudioServer.get_mix_rate()
	write_wav("/tmp/aw_sc_dc.wav", 1.0, func(_i: int, _rt: int) -> Vector2i: return Vector2i(8192, 8192))
	d.new_project()
	var a := d.add_clip_from_path("/tmp/aw_sc_dc.wav", 0, 0.0) # 0.25 DC, 0..1 s
	var b := d.add_clip_from_path("/tmp/aw_sc_dc.wav", 1, 2.0) # 0.25 DC, 2..3 s
	var c := d.add_clip_from_path("/tmp/aw_sc_dc.wav", 2, 4.0)
	await frames(tree, 2)
	check(c.fx_chain == null and d.chain_tab == AWDocument.ChainTab.CLIP, "chains: a new clip has no chain (dry)")
	await frames(tree, 2)
	check(cp.tabs.get_tab_title(1).contains("no chain") and cp.find_child("AttachChain", true, false) != null, "chains: a dry clip gets a temporary tab and an Attach card")

	# + makes a chain for the selection; its tab opens with a Clips card listing both clips.
	d.set_selection([a, b] as Array[AWClip])
	cp.tabs.current_tab = cp.tabs.tab_count - 1
	await frames(tree, 3)
	var ch := a.fx_chain
	check(ch != null and b.fx_chain == ch and d.project.chains.has(ch) and c.fx_chain == null, "chains: + attaches a new chain to the selected clips")
	check(d.chain_tab == AWDocument.ChainTab.CHAIN and d.tab_chain == ch and cp.tabs.get_tab_title(cp.tabs.current_tab) == ch.name, "chains: its tab opens")
	var titles := []
	for i in cp.tabs.tab_count:
		titles.append(cp.tabs.get_tab_title(i))
	check(titles[0] == "Master" and titles.has(ch.name) and titles[titles.size() - 1].strip_edges() == "+", "chains: tabs read Master, chains, + (%s)" % str(titles))
	var card: AWClipsCard = cp.find_child("ClipsCard", true, false)
	check(card != null and card.rows.size() == 2 and card.rows[0].clip == a and (card.rows[0].knobs as Array).size() == 3, "chains: the Clips card has a row with Gain / Pitch / Pan per clip")

	# One effect, every clip on the chain; each clip keeps its own gain.
	var amp := d.add_effect(ch, "Amplify")
	d.set_param(amp, "volume_db", -6.0206)
	await frames(tree, 2)
	var r := e.render_preview_range(0.0, 5.0)
	check(absf(_at(r, 0.5) - 0.125) < 0.003 and absf(_at(r, 2.5) - 0.125) < 0.003 and absf(_at(r, 4.5) - 0.25) < 0.003, "chains: an effect on the chain applies to all its clips, not to others (%.3f %.3f %.3f)" % [_at(r, 0.5), _at(r, 2.5), _at(r, 4.5)])
	card = cp.find_child("ClipsCard", true, false)
	var bknob: AWKnob = card.rows[1].knobs[0]
	bknob.binding.set_value(-6.0206)
	await frames(tree, 2)
	r = e.render_preview_range(0.0, 3.0)
	check(absf(_at(r, 0.5) - 0.125) < 0.003 and absf(_at(r, 2.5) - 0.0625) < 0.003, "chains: Gain in the Clips card is per clip (%.3f, %.3f)" % [_at(r, 0.5), _at(r, 2.5)])
	d.undo()

	# A curve on the chain runs on each clip's own clock.
	var cv := d.make_curve(ch, amp, "volume_db")
	ch.set_keys(cv, [{"t": 0.0, "v": ch.to_norm(cv, -60.0), "in": Vector2.ZERO, "out": Vector2.ZERO, "mode": AWCurve.HandleMode.LINEAR},
		{"t": 1.0, "v": ch.to_norm(cv, 0.0), "in": Vector2.ZERO, "out": Vector2.ZERO, "mode": AWCurve.HandleMode.LINEAR}])
	d.project_changed.emit(false)
	await frames(tree, 2)
	r = e.render_preview_range(0.0, 3.0)
	check(absf(_at(r, 0.75) - _at(r, 2.75)) < 0.003 and _at(r, 0.75) > _at(r, 0.25) + 0.02, "chains: a chain curve plays the same on each clip, from its own start (%.3f vs %.3f)" % [_at(r, 0.75), _at(r, 2.75)])
	check(d.active_chain() == ch and not d.curve_on_clip and screen.find_child("OwnerChain", true, false) != null, "chains: the curve view shows the chain's curves")
	# A clip's own Gain curve, made from its knob, switches the view to that clip's curves.
	d.select_clip(a)
	var aknob: AWKnob = (cp.find_child("ClipsCard", true, false) as AWClipsCard).rows[0].knobs[0]
	aknob.binding.on_menu(1)
	await frames(tree, 2)
	check(d.curve_on_clip and d.active_chain() == a.chain and a.chain.get_curve(a.chain.effects[0].id, "gain_db") != null, "chains: a clip's Gain curve shows that clip's own curves")
	d.set_curve_on_clip(false)
	check(d.active_chain() == ch, "chains: the switch goes back to the chain's curves")

	# Duplicate shares the chain; Effect Chain menu; delete and undo; rename.
	d.select_clip(a)
	d.duplicate_selected()
	var dup := d.selection[0]
	check(dup.fx_chain == ch and d.project.chains.size() == 1, "chains: a duplicated clip uses the same chain (not a copy)")
	d.set_clip_chain(dup, null)
	check(dup.fx_chain == null and a.fx_chain == ch, "chains: one clip can leave the chain")
	d.undo()
	d.delete_chain(ch)
	check(not d.project.chains.has(ch) and a.fx_chain == null and b.fx_chain == null, "chains: deleting a chain leaves its clips dry")
	d.undo()
	check(d.project.chains.has(ch) and a.fx_chain == ch and b.fx_chain == ch, "chains: delete undoes")
	d.rename_chain(ch, "Impact FX")
	check(ch.name == "Impact FX", "chains: renamed")
	var ch2 := d.duplicate_chain(ch)
	check(ch2 != ch and ch2.name == "Impact FX copy" and ch2.effects.size() == ch.effects.size() and ch2.effects[0] != ch.effects[0], "chains: duplicate makes an independent copy")
	d.set_clip_chain(c, ch2)
	var all_labels: Array = d.all_lfos().map(func(x: Dictionary) -> String: return x.label)
	d.add_lfo(ch, cv)
	all_labels = d.all_lfos().map(func(x: Dictionary) -> String: return x.label)
	check(all_labels.any(func(l: String) -> bool: return l.begins_with("Impact FX\\")), "chains: chain LFOs are listed under the chain's name (%s)" % str(all_labels))

	# Saved and reopened: still one shared chain object.
	check(d.save_project("user://aw_shared.tres") and d.load_project("user://aw_shared.tres"), "chains: save and open")
	var p := d.project
	var users := 0
	for k in p.clips:
		if k.fx_chain and k.fx_chain.name == "Impact FX":
			users += 1
			check(p.chains.has(k.fx_chain), "chains: reopened clip points at a listed chain")
	var first: AWChain = null
	for k in p.clips:
		if k.fx_chain and k.fx_chain.name == "Impact FX":
			if first == null:
				first = k.fx_chain
			elif k.fx_chain != first:
				users = -100
	check(users == 3 and p.chains.size() == 2, "chains: after reopening, the clips still share one chain (%d users)" % users)

	# Paste into a new sound brings a copy of the chain along.
	d.select_clip(p.clips[0])
	d.copy_selected()
	d.new_project()
	d.paste()
	check(d.project.clips.size() == 1 and d.project.chains.size() == 1 and d.project.clips[0].fx_chain == d.project.chains[0], "chains: pasting into another sound lists a copy of the chain")

	# Opening an older sound (format 5): clips' own effects move into "<clip> FX" chains, same sound.
	var old := AWProject.create_demo()
	for k in old.clips:
		k.source_path = "/tmp/aw_sc_dc.wav"
	old.format_version = 5
	d.set_project(old)
	await frames(tree, 2)
	var before := e.render_preview_range(0.0, 3.0)
	var fpath := ProjectSettings.globalize_path("user://aw_old5.tres")
	ResourceSaver.save(old, fpath)
	check(d.load_project(fpath), "migration: a format 5 sound opens")
	var bed: AWClip = d.project.clips[3]
	check(bed.fx_chain != null and bed.fx_chain.name == bed.name + " FX" and bed.chain.effects.size() == 1 and bed.fx_chain.effects.size() == 3 and d.project.chains.size() == 1, "migration: the clip's effects moved into \"%s FX\"" % bed.name)
	check(bed.fx_chain.curves.size() == 3 and bed.chain.curves.size() == 1, "migration: effect curves moved with them; the Pitch curve stayed (%d / %d)" % [bed.fx_chain.curves.size(), bed.chain.curves.size()])
	await frames(tree, 2)
	var after := e.render_preview_range(0.0, 3.0)
	var worst := 0.0
	for i in range(0, mini(before.size(), after.size()), 31):
		worst = maxf(worst, absf(before[i].x - after[i].x))
	check(worst < 1e-4, "migration: the sound is unchanged (worst %.6f)" % worst)
	DirAccess.remove_absolute(fpath)

	# File > New after working on a chain: the panel shows the new, empty sound (owner report).
	d.new_project()
	var nx := d.add_clip_from_path("/tmp/aw_sc_dc.wav", 0, 0.0)
	d.set_selection([nx] as Array[AWClip])
	var ch_old := d.new_chain_for(null)
	d.add_effect(ch_old, "Reverb")
	await frames(tree, 3)
	d.new_project()
	await frames(tree, 3)
	check(d.chain_tab == AWDocument.ChainTab.CLIP and d.tab_chain == null and cp.find_child("ClipsCard", true, false) == null and cp._cards.is_empty() and cp.tabs.tab_count == 2, "chains: File > New clears the chain panel (tabs: %d)" % cp.tabs.tab_count)
	# Export outside the project: an absolute path is kept and the file lands there.
	check(AWMainScreen.export_path_for(ProjectSettings.globalize_path("res://assets/sfx/hit.wav")) == "assets/sfx/hit.wav", "export: a file inside the project is stored relative to it")
	check(AWMainScreen.export_path_for("/tmp/aw_other_project/sfx/hit.wav") == "/tmp/aw_other_project/sfx/hit.wav", "export: a file elsewhere keeps its absolute path")
	d.set_export_path(AWMainScreen.export_path_for("/tmp/aw_other_project/sfx/hit.wav"))
	DirAccess.make_dir_recursive_absolute("/tmp/aw_other_project")
	nx = d.add_clip_from_path("/tmp/aw_sc_dc.wav", 0, 0.0)
	var rr: Dictionary = await AWExporter.new().run(d.project, d.export_target(), 16)
	check(rr.ok and FileAccess.file_exists("/tmp/aw_other_project/sfx/hit.wav"), "export: writes into another folder outside res:// (%s)" % str(rr.error))
	d.set_export_path("assets/sfx/jump.wav")
	DirAccess.remove_absolute("/tmp/aw_other_project/sfx/hit.wav")

	# 16 rows from the start.
	check(screen.timeline.grid.row_count() >= 16, "grid: at least 16 rows (%d)" % screen.timeline.grid.row_count())

	# Toolbar shortcuts; the narrow left column is gone.
	for nm in ["EditMarker", "EditTrimStart", "EditTrimEnd", "EditReverse", "EditCrossfade", "EditGroup"]:
		check(screen.find_child(nm, true, false) != null, "toolbar: %s button" % nm)
	if OS.get_environment("AW_SHOTS") != "":
		d.new_project()
		var x1 := d.add_clip_from_path("/tmp/aw_sc_dc.wav", 0, 0.0)
		var x2 := d.add_clip_from_path("/tmp/aw_sc_dc.wav", 1, 0.5)
		d.add_clip_from_path("/tmp/aw_sc_dc.wav", 2, 1.0)
		d.rename_clip(x1, "Body")
		d.rename_clip(x2, "Debris")
		d.set_selection([x1, x2] as Array[AWClip])
		var sc := d.new_chain_for(null)
		d.rename_chain(sc, "Impact FX")
		d.add_effect(sc, "Low Pass")
		d.add_effect(sc, "Reverb")
		var other := AWChain.new()
		d.select_clip(d.project.clips[2])
		var dc := d.new_chain_for(null)
		d.rename_chain(dc, "Sweetener")
		d.select_clip(x1)
		await frames(tree, 4)
		await shot(tree, "aw_chain_tabs.png")
	d.new_project()


static func empty_start_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	d.new_project()
	check(d.project.clips.is_empty(), "empty start: a new sound has no clips")
	check(d.project.master_chain != null and d.project.master_chain.effects.size() == 1, "empty start: master chain has only the Output card")
	check(d.project.title == "Untitled" and not d.is_dirty(), "empty start: untitled and clean")
	d.play_pause()
	await frames(tree, 5)
	d.stop()
	await frames(tree, 3)
	check(true, "empty start: playing an empty sound does not crash")
	var sine := "/tmp/aw_empty_sine.wav"
	write_wav(sine, 0.5, func(i: int, rt: int) -> Vector2i:
		var v := int(8000.0 * sin(TAU * 300.0 * i / rt))
		return Vector2i(v, v))
	d.add_clip_from_path(sine, 0, 0.0)
	await frames(tree, 3)
	check(d.project.clips.size() == 1 and d.project.clips[0].source_path == sine, "empty start: a clip can be added to an empty sound")
	check(d.save_project("user://aw_empty_start.tres") and d.load_project("user://aw_empty_start.tres"), "empty start: saves and reopens")
	d.new_project()


static func load_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var e := d.engine
	var sine := "/tmp/aw_load_sine.wav"
	write_wav(sine, 4.0, func(i: int, rt: int) -> Vector2i:
		var v := int(8000.0 * sin(TAU * 200.0 * i / rt))
		return Vector2i(v, v))
	# A busy project: 48 clips, each with Delay, Reverb and Chorus, plus a master chain.
	var p := AWProject.create_demo()
	p.clips.clear()
	for i in 48:
		var c := AWClip.new()
		c.name = "c%d" % i
		c.source_path = sine
		c.start_sec = float(i % 12) * 0.5
		c.length_sec = 3.0
		c.chain = AWChain.create("Source")
		for t in ["Delay", "Reverb", "Chorus"]:
			c.chain.effects.append(AWEffect.create(t, c.chain.new_effect_id()))
		p.clips.append(c)
	d.set_project(p)
	check(e.get_load().size() == 2, "load: get_load returns [average, peak]")
	var t0 := Time.get_ticks_usec()
	var out := e.render_preview_range(0.0, 8.0)
	var secs := (Time.get_ticks_usec() - t0) / 1e6
	var speed := 8.0 / maxf(secs, 1e-6)
	print("LOAD busy project: 8 s rendered in %.2f s (%.1fx real time)" % [secs, speed])
	check(out.size() > 0 and speed > 1.5, "load: a busy project (48 clips x 3 effects) renders faster than real time (%.1fx)" % speed)

	# Playing while the plan changes constantly stays alive and reports a sane load.
	d.seek(0.0)
	d.play_pause()
	for i in 40:
		d.set_props(p.clips[i % p.clips.size()], {"muted": i % 2 == 0}, "Mute")
		await tree.process_frame
	var l := e.get_load()
	check(is_finite(float(l[0])) and is_finite(float(l[1])) and float(l[1]) >= 0.0, "load: meter reports finite numbers while playing and editing")
	print("LOAD while playing: avg %.3f peak %.3f" % [float(l[0]), float(l[1])])
	d.stop()
	screen.toolbar_update_cpu()

	# Dragging a knob while playing keeps the effects' state (no reset, no click); adding an
	# effect changes the layout and starts the effects fresh.
	var small := AWProject.create_default()
	for i in 2:
		var sc := AWClip.new()
		sc.name = "s%d" % i
		sc.source_path = sine
		sc.length_sec = 3.5
		sc.chain = AWChain.create("Source")
		for t in ["Delay", "Reverb"]:
			sc.chain.effects.append(AWEffect.create(t, sc.chain.new_effect_id()))
		small.clips.append(sc)
	d.set_project(small)
	d.seek(0.0)
	d.play_pause()
	await frames(tree, 10)
	var s0: Array = e.get_fx_swaps()
	var rev: AWEffect = small.clips[0].chain.effects[2]
	# A slow machine mixes less often; keep dragging until the audio thread has taken several plans.
	for i in 150:
		d.preview_param(rev, "wet", 0.1 + 0.004 * i)
		await frames(tree, 2)
		if i >= 20 and int(e.get_fx_swaps()[0]) - int(s0[0]) >= 5:
			break
	var s1: Array = e.get_fx_swaps()
	print("SWAPS knob drag: kept %d, fresh %d" % [int(s1[0]) - int(s0[0]), int(s1[1]) - int(s0[1])])
	check(int(s1[0]) - int(s0[0]) >= 5 and int(s1[1]) == int(s0[1]), "playing: a knob drag keeps effect state across plan swaps (kept %d, fresh %d)" % [int(s1[0]) - int(s0[0]), int(s1[1]) - int(s0[1])])
	d.add_effect(small.clips[0].chain, "Chorus")
	for i in 400: # the audio thread picks the new plan up on its next mix
		await tree.process_frame
		if int(e.get_fx_swaps()[1]) > int(s1[1]):
			break
	var s2: Array = e.get_fx_swaps()
	check(int(s2[1]) > int(s1[1]), "playing: adding an effect rebuilds the chain")
	d.stop()
	d.new_project()


static func recovery_tests(_tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	AWRecovery.discard()
	d.new_project()
	d.set_project(AWProject.create_demo())
	check(not AWRecovery.exists(), "recovery: none for a fresh sound")
	d.tick_recovery(10.0)
	check(not AWRecovery.exists(), "recovery: nothing written while clean")

	# An edit starts the countdown; the copy appears after the quiet period, not before.
	d.set_props(d.project.clips[0], {"name": "Recovered clip"}, "Rename")
	check(d.is_dirty(), "recovery: edit makes it dirty")
	d.tick_recovery(0.1)
	d.tick_recovery(AWDocument.RECOVERY_DELAY - 1.0)
	check(not AWRecovery.exists(), "recovery: not written before the delay")
	d.tick_recovery(2.0)
	check(AWRecovery.exists(), "recovery: written after the delay")
	check(AWRecovery.info().original == "", "recovery: records no original for an unsaved sound")

	# Restore into a different state.
	d.new_project()
	d.set_project(AWProject.create_demo())
	check(not AWRecovery.exists(), "recovery: a deliberate New discards it")
	d.set_props(d.project.clips[0], {"name": "Recovered clip"}, "Rename")
	d.write_recovery()
	d.set_props(d.project.clips[0], {"name": "Something else"}, "Rename")
	check(d.restore_recovery(), "recovery: restore succeeds")
	check(d.project.clips[0].name == "Recovered clip" and d.is_dirty(), "recovery: restored content, marked unsaved")
	d.tick_recovery(0.1)
	d.tick_recovery(AWDocument.RECOVERY_DELAY + 1.0)
	check(AWRecovery.exists(), "recovery: restored work is protected again")

	# A save removes it.
	check(d.save_project("user://aw_recovery_save.tres"), "recovery: save ok")
	check(not AWRecovery.exists() and not d.is_dirty(), "recovery: removed by a clean save")

	# Remembers the file the sound belongs to.
	d.set_props(d.project.clips[0], {"name": "Edited again"}, "Rename")
	d.tick_recovery(0.1)
	d.tick_recovery(AWDocument.RECOVERY_DELAY + 1.0)
	check(AWRecovery.info().original == "user://aw_recovery_save.tres", "recovery: remembers the original file")
	d.new_project()
	d.set_project(AWProject.create_demo())
	check(not AWRecovery.exists(), "recovery: discarded when the user starts over")

	# Damaged recovery copy: handled, then removed.
	var f := FileAccess.open(AWRecovery.PATH, FileAccess.WRITE)
	f.store_string("junk")
	f.close()
	check(not d.restore_recovery() and not AWRecovery.exists(), "recovery: unreadable copy is refused and removed")

	# Opening from the FileSystem dock.
	d.new_project()
	d.set_project(AWProject.create_demo())
	screen.open_from_editor("user://aw_recovery_save.tres")
	check(d.project_path == "user://aw_recovery_save.tres", "recovery: open_from_editor opens the sound")
	d.new_project()
	d.set_project(AWProject.create_demo())


static func source_tests(_tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	DirAccess.make_dir_recursive_absolute("/tmp/aw_src/a/deep")
	DirAccess.make_dir_recursive_absolute("/tmp/aw_src/b")
	var gen := func(i: int, rt: int) -> Vector2i:
		var v := int(9000.0 * sin(TAU * 220.0 * i / rt))
		return Vector2i(v, v)
	write_wav("/tmp/aw_src/a/deep/boom.wav", 0.5, gen)
	write_wav("/tmp/aw_src/b/tick.wav", 0.5, gen)
	var p := AWProject.create_demo()
	p.clips[0].source_path = "/tmp/aw_src/a/deep/boom.wav"
	p.clips[1].source_path = "/tmp/aw_src/a/deep/boom.wav"
	p.clips[2].source_path = "/tmp/aw_src/b/tick.wav"
	d.set_project(p)
	check(d.missing_paths().is_empty(), "sources: nothing missing at first")
	check(not d.is_clip_missing(p.clips[0]), "sources: present clip not marked")

	# Missing files are marked, but the project still opens.
	var path := "user://aw_src_test.tres"
	check(d.save_project(path), "sources: saved")
	DirAccess.remove_absolute("/tmp/aw_src/a/deep/boom.wav")
	check(d.load_project(path), "sources: opens with a missing file")
	check(d.missing_paths().size() == 1 and d.is_clip_missing(d.project.clips[0]) and d.is_clip_missing(d.project.clips[1]), "sources: both clips of the missing file are marked")
	check(not d.is_clip_missing(d.project.clips[2]), "sources: other clip not marked")
	check(d.project.clips[0].source_path == "/tmp/aw_src/a/deep/boom.wav", "sources: missing path kept so it can be relinked")

	# Relink one file: all clips that used it follow, and undo restores.
	write_wav("/tmp/aw_src/b/boom2.wav", 0.5, gen)
	d.relink_clip(d.project.clips[0], "/tmp/aw_src/b/boom2.wav")
	check(d.missing_paths().is_empty() and d.project.clips[1].source_path == "/tmp/aw_src/b/boom2.wav", "sources: relink moves every clip using the file")
	d.undo()
	check(d.is_clip_missing(d.project.clips[0]) and d.project.clips[1].source_path == "/tmp/aw_src/a/deep/boom.wav", "sources: relink undone")
	d.redo()
	check(d.missing_paths().is_empty(), "sources: relink redone")
	d.relink_clip(d.project.clips[0], "/tmp/aw_src/nothing.wav")
	check(d.project.clips[0].source_path == "/tmp/aw_src/b/boom2.wav", "sources: relink to a missing file refused")

	# Relink from a folder, found by file name.
	d.undo()
	check(d.relink_in_folder("/tmp/aw_src/empty_nowhere") == 0, "sources: folder without the file relinks nothing")
	write_wav("/tmp/aw_src/a/deep/boom.wav", 0.5, gen)
	check(d.relink_in_folder("/tmp/aw_src/a") == 2 and d.missing_paths().is_empty(), "sources: folder search relinks by name, recursively")

	# Moved files are followed by UID (only for files Godot knows; here, check the mechanism).
	var q := AWProject.create_demo()
	q.clips[0].source_path = "/tmp/aw_src/a/deep/boom.wav"
	q.clips[0].source_uid = "uid://notarealuid"
	check(AWProjectIO.refresh_sources(q).is_empty() and q.clips[0].source_path == "/tmp/aw_src/a/deep/boom.wav", "sources: unknown uid leaves path alone")
	# A file renamed in the editor keeps its UID: the clip follows it, and a clip named after the
	# file takes the new name (names the user typed stay).
	write_wav("/tmp/aw_src/b/renamed_hit.wav", 0.5, gen)
	var uid_id := ResourceUID.create_id()
	ResourceUID.add_id(uid_id, "/tmp/aw_src/b/renamed_hit.wav")
	var mv := AWProject.create_default()
	for nm in ["old_hit", "old_hit 2", "My punch"]:
		var mc := AWClip.new()
		mc.name = nm
		mc.source_path = "/tmp/aw_src/b/old_hit.wav"
		mc.source_uid = ResourceUID.id_to_text(uid_id)
		mv.clips.append(mc)
	var moved := AWProjectIO.refresh_sources(mv)
	check(moved.size() == 3 and mv.clips[0].source_path == "/tmp/aw_src/b/renamed_hit.wav", "sources: a renamed file is followed by its uid")
	check(mv.clips[0].name == "renamed_hit" and mv.clips[1].name == "renamed_hit 2" and mv.clips[2].name == "My punch", "sources: clip names follow the file, typed names stay (%s, %s, %s)" % [mv.clips[0].name, mv.clips[1].name, mv.clips[2].name])
	check(AWProjectIO.follow_name("boomerang", "a/boom.wav", "a/hit.wav") == "boomerang", "sources: a name that only starts with the file name is kept")
	ResourceUID.remove_id(uid_id)
	check(AWProjectIO.path_for_uid("") == "" and AWProjectIO.uid_for_path("/tmp/aw_src/b/tick.wav") == "", "sources: files outside the project have no uid")

	# Menu offers relink only for a missing clip.
	DirAccess.remove_absolute("/tmp/aw_src/a/deep/boom.wav")
	d.refresh_sources()
	check(d.is_clip_missing(d.project.clips[0]), "sources: refresh re-detects missing files")
	d.relink_requested.connect(func(_c: AWClip, m: String) -> void: print("relink asked: ", m), CONNECT_ONE_SHOT)
	d.relink_requested.emit(d.project.clips[0], "file")
	d.new_project()


static func save_open_tests(tree: SceneTree, screen: AWMainScreen) -> void:
	var d := screen.doc
	var rate := int(AudioServer.get_mix_rate())
	var sine := "/tmp/aw_save_sine.wav"
	write_wav(sine, 1.5, func(i: int, rt: int) -> Vector2i:
		var v := int(12000.0 * sin(TAU * 330.0 * i / rt))
		return Vector2i(v, v))
	var path := "user://aw_save_test.tres"
	var abs_path := ProjectSettings.globalize_path(path)
	DirAccess.remove_absolute(abs_path)

	# A project that uses most of the model: sources, chains, curves, an LFO, export settings.
	var p := AWProject.create_demo()
	for c in p.clips:
		c.source_path = sine
	var bed: AWClip = p.clips[3]
	var delay := AWEffect.create("Delay", bed.chain.new_effect_id())
	delay.params["tap1_delay_ms"] = 180.0
	bed.chain.effects.append(delay)
	var wet := bed.chain.get_curve(bed.chain.effects[2].id, "wet")
	var lfo := AWLfo.new()
	lfo.shape = AWLfo.Shape.TRIANGLE
	lfo.freq_hz = 7.5
	lfo.freq_accel = 0.8
	lfo.fade_smoothing = 0.3
	lfo.max_value = 0.7
	lfo.min_value = 0.2
	lfo.end_sec = 2.0
	wet.lfo = lfo
	p.export_format = "ogg"
	p.export_ogg_quality = 7.5
	p.export_end_sec = 4.5
	p.export_path = "assets/sfx/saved_test.ogg"
	p.title = "Round trip"
	var before := _render_project(p, 3.5)

	# Save and open: the same sound, sample for sample.
	d.set_project(p)
	check(d.save_project(abs_path) and FileAccess.file_exists(abs_path), "save: the file is written")
	check(not FileAccess.file_exists(abs_path.get_basename() + ".aw_saving.tres"), "save: no temporary file is left behind")
	var r := AWProjectIO.open(abs_path)
	check(r.ok and r.repairs.is_empty(), "open: a file we saved opens with nothing repaired (%s)" % str(r.repairs))
	var q: AWProject = r.project
	var after := _render_project(q, 3.5)
	var worst := 0.0
	var peak := 0.0
	for i in mini(before.size(), after.size()):
		worst = maxf(worst, maxf(absf(before[i].x - after[i].x), absf(before[i].y - after[i].y)))
		peak = maxf(peak, absf(before[i].x))
	check(before.size() == after.size() and peak > 0.05 and worst < 1e-5, "save and open: the render matches sample for sample to within -100 dB (sizes %d/%d, peak %.2f, worst %s)" % [before.size(), after.size(), peak, str(worst)])
	check(q.title == "Round trip" and q.clips.size() == p.clips.size() and q.export_format == "ogg" and is_equal_approx(q.export_ogg_quality, 7.5) and is_equal_approx(q.export_end_sec, 4.5) and q.export_path == "assets/sfx/saved_test.ogg", "open: title, clips and export settings come back")
	var qwet := q.clips[3].chain.get_curve(q.clips[3].chain.effects[2].id, "wet")
	check(qwet != null and qwet.lfo != null and qwet.lfo.shape == AWLfo.Shape.TRIANGLE and is_equal_approx(qwet.lfo.freq_accel, 0.8) and is_equal_approx(qwet.lfo.fade_smoothing, 0.3), "open: the LFO and its new controls come back")
	check(q.clips[3].chain.get_keys(qwet).size() == bed.chain.get_keys(wet).size() and q.clips[3].chain.effects.size() == bed.chain.effects.size(), "open: curve keys and effects come back")
	check(is_equal_approx(q.clips[3].chain.effects[bed.chain.effects.size() - 1].get_param("tap1_delay_ms"), 180.0), "open: effect settings come back")

	# Dirty flag, title and undo history.
	check(not d.is_dirty() and d.file_label() == "aw_save_test.tres", "dirty: just saved is clean (%s)" % d.file_label())
	d.toggle_loop()
	check(d.is_dirty() and d.file_label() == "aw_save_test.tres*", "dirty: an edit shows the star (%s)" % d.file_label())
	d.undo()
	check(not d.is_dirty(), "dirty: undoing back to the saved state is clean again")
	d.set_export_ogg_quality(3.0)
	check(d.is_dirty(), "dirty: an export setting counts too, though it isn't undoable")
	var fl: Label = screen.find_child("FileName", true, false)
	check(fl != null and fl.text == "aw_save_test.tres*", "toolbar shows the file name and star (%s)" % (fl.text if fl else "?"))
	check(d.save_project(abs_path) and not d.is_dirty(), "dirty: saving clears it")
	d.toggle_loop()
	check(d.can_undo() and d.is_dirty(), "history: there is something to undo before opening")
	check(d.load_project(abs_path) and not d.can_undo() and not d.is_dirty() and d.project_path == abs_path, "open: undo history is cleared and the file is clean")

	# Unsaved changes: New and Open ask first.
	var ran := [0]
	d.toggle_loop()
	screen.ask_discard(func() -> void: ran[0] += 1)
	check(ran[0] == 0 and screen._confirm.visible, "unsaved: the question is shown and nothing has run yet")
	screen._confirm.custom_action.emit(&"discard")
	check(ran[0] == 1 and not screen._confirm.visible, "unsaved: Don't Save runs the action")
	d.save_project(abs_path)
	screen.ask_discard(func() -> void: ran[0] += 1)
	check(ran[0] == 2, "unsaved: with no changes the action runs at once")
	d.toggle_loop()
	screen.ask_discard(func() -> void: ran[0] += 1)
	screen._confirm.canceled.emit()
	screen._confirm.hide()
	check(ran[0] == 2 and not screen._pending_after_ask.is_valid(), "unsaved: Cancel does nothing")
	d.save_project(abs_path)
	d.new_project()
	check(d.project_path == "" and d.file_label() == "Untitled" and not d.can_undo(), "new: an untitled sound, history cleared")
	var fm: MenuButton = null
	for ch in screen.get_child(0).get_children():
		if ch is MenuButton and (ch as MenuButton).text == "File":
			fm = ch
	var items: Array[String] = []
	if fm:
		for i in fm.get_popup().item_count:
			items.append(fm.get_popup().get_item_text(i))
	check(items.has("Export Sound") and not items.has("Export WAV...") and not items.has("Export as AudioStream..."), "File menu: Export Sound replaces the old export stubs (%s)" % str(items))

	# Failures leave things alone.
	var before_bytes := FileAccess.get_file_as_bytes(abs_path)
	check(not d.save_project("user://aw_no_such_dir/x.tres") and FileAccess.get_file_as_bytes(abs_path) == before_bytes, "save: an unwritable path fails with a message and harms nothing")
	var junk := ProjectSettings.globalize_path("user://aw_junk.tres")
	var jf := FileAccess.open(junk, FileAccess.WRITE)
	jf.store_string("this is not a resource {{{")
	jf.close()
	var rj := AWProjectIO.open(junk)
	check(not rj.ok and rj.error != "", "open: a damaged file gives a message, not a crash (%s)" % rj.error)
	var other := ProjectSettings.globalize_path("user://aw_other.tres")
	ResourceSaver.save(Animation.new(), other)
	var ro := AWProjectIO.open(other)
	check(not ro.ok and ro.error.contains("isn't an Audio Workstation sound"), "open: another kind of resource is refused (%s)" % ro.error)
	var rm := AWProjectIO.open(ProjectSettings.globalize_path("user://aw_missing_file.tres"))
	check(not rm.ok and rm.error.contains("doesn't exist"), "open: a missing file is reported")
	var newer := AWProject.new()
	newer.format_version = 99
	var newer_path := ProjectSettings.globalize_path("user://aw_newer.tres")
	ResourceSaver.save(newer, newer_path)
	var rn := AWProjectIO.open(newer_path)
	check(not rn.ok and rn.error.contains("newer version"), "open: a file from a newer version is refused (%s)" % rn.error)
	var was := d.project
	check(not d.load_project(junk) and d.project == was, "open: a failed open keeps the current sound")

	# Migration: older files are brought up one version at a time.
	var old := AWProject.new()
	old.title = "old"
	old.format_version = 1
	var old_path := ProjectSettings.globalize_path("user://aw_old.tres")
	ResourceSaver.save(old, old_path)
	AWProjectIO.migrations[1] = func(pr: AWProject) -> void: pr.title += "+migrated"
	var rold := AWProjectIO.open(old_path)
	AWProjectIO.migrations.erase(1)
	check(rold.ok and rold.project.title == "old+migrated" and rold.project.format_version == AWProject.FORMAT_VERSION and str(rold.repairs).contains("Updated from format 1"), "open: an older format is migrated (%s)" % str(rold.repairs))

	# Repair: a damaged project is made safe, and the engine can still render it.
	var bad := AWProject.new()
	bad.length_sec = NAN
	bad.export_bit_depth = 24
	bad.export_format = "mp3"
	bad.master_chain = null
	var c1 := AWClip.create("good", 0.0, 1.0, 0, Color.RED)
	c1.source_path = sine
	var c2 := AWClip.create("broken", NAN, INF, -3, Color.BLUE)
	c2.source_path = sine
	c2.chain = null
	var c3 := AWClip.create("odd chain", 0.5, 1.0, 1, Color.GREEN)
	c3.source_path = sine
	var ghost := AWEffect.create("Reverb", 5)
	ghost.effect_type = "Flanger9000"
	var rv := AWEffect.create("Reverb", 6)
	rv.params["room_size"] = 7.5
	rv.params["bogus"] = 1.0
	rv.params["wet"] = NAN
	var rv2 := AWEffect.create("Reverb", 6)
	c3.chain.effects.assign([c3.chain.effects[0], ghost, rv, rv2, null])
	var orphan := AWCurve.new()
	orphan.effect_id = 99
	orphan.param = "wet"
	var dupe_a := AWCurve.new()
	dupe_a.effect_id = 6
	dupe_a.param = "wet"
	var dupe_b := AWCurve.new()
	dupe_b.effect_id = 6
	dupe_b.param = "wet"
	c3.chain.curves.assign([orphan, dupe_a, dupe_b, null])
	bad.clips.assign([c1, null, c2, c3])
	var rep := AWProjectIO.sanitize(bad)
	check(rep.size() >= 10 and bad.length_sec == 4.0 and bad.export_bit_depth == 16 and bad.export_format == "wav" and bad.master_chain != null, "repair: project fields and master chain are fixed (%d repairs)" % rep.size())
	check(bad.clips.size() == 3 and is_finite(bad.clips[1].start_sec) and is_finite(bad.clips[1].length_sec) and bad.clips[1].row >= 0 and bad.clips[1].chain != null, "repair: the empty clip is dropped, the broken one gets safe values and a chain")
	var fx: Array[AWEffect] = bad.clips[2].chain.effects
	var ids := {}
	var unique := true
	for e in fx:
		unique = unique and not ids.has(e.id)
		ids[e.id] = true
	check(fx.size() == 3 and fx[0].effect_type == "Clip" and unique and bad.clips[2].chain.next_effect_id > 6, "repair: unknown and empty effects removed, ids unique, source card first")
	var rp: AWEffect = fx[1]
	check(is_equal_approx(rp.get_param("room_size"), 1.0) and not rp.params.has("bogus") and is_equal_approx(rp.get_param("wet"), 0.5), "repair: settings clamped, unknown dropped, NaN reset")
	check(bad.clips[2].chain.curves.is_empty() or bad.clips[2].chain.curves.size() == 1, "repair: orphan, duplicate and empty curves removed (%d left)" % bad.clips[2].chain.curves.size())
	var rb := _render_project(bad, 2.0)
	var finite := true
	for fr in rb:
		finite = finite and is_finite(fr.x) and is_finite(fr.y)
	check(rb.size() > 0 and finite, "repair: the engine renders the repaired project without NaN")
	check(AWProjectIO.sanitize(bad).is_empty(), "repair: a second pass finds nothing more")

	# Export into the project folder (res://) works, not only user://.
	var res_target := "res://aw_res_export_test.wav"
	var rex: Dictionary = await AWExporter.new().run(q, res_target, 16)
	check(rex.ok and FileAccess.file_exists(res_target), "export: a res:// target works (%s)" % str(rex.error))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(res_target))
	for f in [abs_path, junk, other, newer_path, old_path]:
		DirAccess.remove_absolute(f)
	d.set_project(AWProject.create_demo())


static func get_process_delta(tree: SceneTree) -> float:
	return maxf(1.0 / 60.0, get_delta_guess(tree))


static func get_delta_guess(_tree: SceneTree) -> float:
	return 1.0 / 60.0


static func run(screen: AWMainScreen) -> void:
	var tree := screen.get_tree()
	out_dir = OS.get_environment("AW_OUT")
	var shots := OS.get_environment("AW_SHOTS") != ""
	await frames(tree, 60)
	EditorInterface.set_main_screen_editor("Audio")
	await frames(tree, 20)
	var d := screen.doc
	d.set_project(AWProject.create_demo()) # most tests below use the sample sound; the app itself starts empty
	var p := d.project
	var c4 := p.clips[3]
	var ch := c4.chain

	print("--- native engine ---")
	var expect := OS.get_environment("AW_EXPECT_ENGINE")
	var eng := d.engine
	var chip: Label = screen.find_child("EngineStatus", true, false)
	if expect == "0":
		check(not eng.is_available(), "no binary: engine reported missing")
		check(chip != null and chip.text.contains("Engine not built"), "toolbar says '%s'" % (chip.text if chip else "?"))
		check(eng.render_test(64).is_empty() and eng.get_info().is_empty(), "engine calls are safe without the binary")
	else:
		check(eng.is_available(), "native core AWCore loaded")
		var info := eng.get_info()
		check(info.get("version") == "0.13.0" and info.get("api") == "4.7" and info.get("godot_cpp") == "10.0.0-stable", "build info: %s" % str(info))
		check(chip != null and chip.text.contains("Engine 0.13.0"), "toolbar says '%s'" % (chip.text if chip else "?"))
		var rate: float = eng.core.call("get_sample_rate")
		check(is_equal_approx(rate, AudioServer.get_mix_rate()), "core renders at the mix rate (%d Hz)" % int(rate))
		var silent := eng.render_test(480)
		var silent_ok := silent.size() == 480
		for v in silent:
			silent_ok = silent_ok and v == Vector2.ZERO
		check(silent_ok, "silence renders 480 zero frames")
		var n := int(rate)
		var tone := eng.render_test(n, 1000.0, -6.0)
		var peak := 0.0
		var crossings := 0
		for i in range(1, tone.size()):
			peak = maxf(peak, absf(tone[i].x))
			if (tone[i - 1].x < 0.0) != (tone[i].x < 0.0):
				crossings += 1
		check(tone.size() == n and absf(peak - db_to_linear(-6.0)) < 0.002, "test tone: 1 s rendered, peak %.4f (-6 dB = %.4f)" % [peak, db_to_linear(-6.0)])
		check(absf(crossings / 2.0 - 1000.0) <= 1.0, "test tone measures %.1f Hz" % (crossings / 2.0))
		check(tone[100].x == tone[100].y, "stereo frames carry both channels")
		check(int(eng.core.call("get_frames_rendered")) == n, "core counts rendered frames")
		var t0 := Time.get_ticks_usec()
		eng.render_test(n * 10, 440.0, -12.0)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		check(ms < 500.0, "10 s of audio rendered in %.1f ms (%.0fx real time)" % [ms, 10000.0 / maxf(ms, 0.001)])

	print("--- row height ---")
	for g in screen.find_children("*", "AWClipGrid", true, false):
		var h0: float = g.row_h
		g.set_row_height(h0 * 2.0)
		check(is_equal_approx(g.row_h, h0 * 2.0) and g.custom_minimum_size.y >= g.row_h * 6.0, "Alt+wheel row height: %.0f -> %.0f px" % [h0, g.row_h])
		g.set_row_height(10000.0)
		check(g.row_h == AWClipGrid.ROW_H_MAX, "row height is capped at %.0f" % AWClipGrid.ROW_H_MAX)
		g.set_row_height(h0)

	if expect != "0":
		print("--- dry playback ---")
		await dry_playback_tests(screen)
		print("--- automation ---")
		automation_tests(screen)
		effects_tests(screen)
		print("--- sampler ---")
		sampler_tests(screen)

	print("--- model ---")
	check(d.focus_clip == c4 and d.active_chain() == ch, "starts on Clip 4's chain")
	check(ch.curves.size() == 4, "demo has 4 curves")
	var rev: AWEffect = ch.effects[2]
	var c := d.make_curve(ch, rev, "room_size")
	check(ch.curves.size() == 5 and d.active_curve == c and ch.get_keys(c).size() == 2, "make curve")
	check(is_equal_approx(ch.sample(c, 1.0), 0.8), "new curve holds the current value")
	d.undo()
	check(ch.curves.size() == 4 and ch.automation.find_track(c.track_path(), Animation.TYPE_BEZIER) == -1, "undo make curve removes track")
	d.redo()
	check(ch.curves.size() == 5, "redo make curve")
	d.set_param(rev, "damping", 0.9)
	check(is_equal_approx(rev.get_param("damping"), 0.9), "set static param")
	d.undo()
	check(is_equal_approx(rev.get_param("damping"), 0.5), "undo static param")

	var dl := d.add_effect(ch, "Delay")
	check(ch.effects.back() == dl, "add effect appends")
	var dc := d.make_curve(ch, dl, "dry")
	var keys := ch.get_keys(dc)
	keys[0].v = 0.25
	d.set_curve_keys(ch, dc, keys, "edit")
	d.remove_effect(ch, dl)
	check(not ch.effects.has(dl) and not ch.curves.has(dc), "remove effect removes its curves")
	d.undo()
	check(ch.effects.has(dl) and ch.curves.has(dc) and is_equal_approx(ch.get_keys(dc)[0].v, 0.25), "undo remove effect restores curve keys")
	d.move_effect(ch, dl, 1)
	check(ch.effects[1] == dl, "move effect")
	d.move_effect(ch, dl, 0)
	check(ch.effects[0].is_fixed(), "fixed card stays first")
	d.undo(); d.undo(); d.undo(); d.undo(); d.undo()
	check(not ch.effects.has(dl), "undo back past add effect")

	var pc: AWCurve = ch.curves[0]
	d.cycle_curve_display(pc)
	check(pc.display == AWCurve.Display.DIM and d.is_curve_visible(pc) and not d.is_curve_editable(pc), "dot cycle -> Dim (visible, not editable)")
	d.cycle_curve_display(pc)
	check(pc.display == AWCurve.Display.OFF and not d.is_curve_visible(pc), "dot cycle -> Off (hidden)")
	d.cycle_curve_display(pc)
	check(pc.display == AWCurve.Display.ON, "dot cycle -> On")
	d.toggle_solo(ch.curves[2])
	check(not d.is_curve_visible(ch.curves[1]) and d.is_curve_visible(ch.curves[2]), "solo hides others")
	d.toggle_solo(ch.curves[2])
	check(d.is_curve_visible(ch.curves[1]), "unsolo")
	d.toggle_mute(ch.curves[1])
	check(not d.is_curve_visible(ch.curves[1]), "mute")
	d.show_all_curves()
	check(d.is_curve_visible(ch.curves[1]), "show all")

	d.set_chain_tab(AWDocument.ChainTab.MASTER)
	check(d.active_chain() == p.master_chain and d.active_curve == null, "master tab shows master chain")
	d.select_clip(p.clips[0])
	check(d.chain_tab == AWDocument.ChainTab.CLIP and d.active_chain() == p.clips[0].chain, "selecting a clip shows its chain")
	d.set_curve_time(AWDocument.CurveTime.PROJECT)
	check(is_equal_approx(d.view_to_local(1.0), 1.0 - p.clips[0].start_sec), "project-time view offsets by clip start")
	d.set_curve_time(AWDocument.CurveTime.CLIP)
	check(is_equal_approx(d.view_to_project(1.0), 1.0) and is_equal_approx(d.local_to_view(0.0), p.clips[0].start_sec), "curves sit on the shared timeline: a clip's curve time 0 is at its start")

	d.select_clip(c4)
	var n := p.clips.size()
	var end_before := c4.end_sec()
	var s_cut := c4.project_to_local(1.6)
	d.split_clip(c4, 1.6)
	var right: AWClip = p.clips[p.clips.find(c4) + 1]
	check(p.clips.size() == n + 1 and absf(c4.length_sec - s_cut) < 1e-4 and is_equal_approx(right.start_sec, 1.6), "split at 1.6 s cuts at audio time %.3f s" % s_cut)
	check(absf(right.chain.sample(right.chain.curves[0], 0.0) - ch.sample(ch.curves[0], s_cut)) < 1e-3, "split shifts right half's curves to stay in sync")
	check(absf(c4.end_sec() - 1.6) < 2e-3 and absf(right.end_sec() - end_before) < 2e-3, "split halves meet at 1.6 s and end where the clip ended")
	check(right.chain.effects[1] != ch.effects[1], "split copy has its own chain")
	d.undo()
	check(p.clips.size() == n and is_equal_approx(c4.length_sec, 2.8), "undo split")
	d.select_clip(p.clips[1])
	d.duplicate_selected()
	check(p.clips.size() == n + 1, "duplicate")
	d.delete_selected_clips()
	check(p.clips.size() == n, "delete")
	d.undo()
	check(p.clips.size() == n + 1, "undo delete")
	d.undo()
	check(p.clips.size() == n, "undo duplicate")

	print("--- UI: clip grid ---")
	var grid := screen.timeline.grid
	await frames(tree, 4)
	var c2 := p.clips[1]
	d.set_snap(0.05)
	var r := grid.clip_rect(c2)
	var start0 := c2.start_sec
	var row0 := c2.row
	var dx := 0.4 * grid.view.pixels_per_sec
	drag(grid, r.get_center(), r.get_center() + Vector2(dx, grid.row_h * 2))
	check(is_equal_approx(c2.start_sec, start0 + 0.4) and c2.row == row0 + 2, "drag clip: +0.4 s, +2 rows (got %.3f, row %d)" % [c2.start_sec, c2.row])
	d.undo()
	check(is_equal_approx(c2.start_sec, start0) and c2.row == row0, "one undo restores the drag")
	r = grid.clip_rect(c2)
	var len0 := c2.length_sec
	drag(grid, Vector2(r.end.x - 2, r.get_center().y), Vector2(r.end.x - 2 - 0.3 * grid.view.pixels_per_sec, r.get_center().y))
	check(is_equal_approx(c2.length_sec, len0 - 0.3), "trim right edge (got %.3f)" % c2.length_sec)
	d.undo()
	r = grid.clip_rect(c2)
	var off0 := c2.source_offset_sec
	drag(grid, Vector2(r.position.x + 2, r.get_center().y), Vector2(r.position.x + 2 + 0.2 * grid.view.pixels_per_sec, r.get_center().y))
	check(is_equal_approx(c2.start_sec, start0 + 0.2) and is_equal_approx(c2.source_offset_sec, off0 + 0.2), "trim left edge moves source offset")
	d.undo()
	r = grid.clip_rect(c2)
	drag(grid, Vector2(r.position.x + 1, r.position.y + 2), Vector2(r.position.x + 0.25 * grid.view.pixels_per_sec, r.position.y + 2))
	check(c2.fade_in_sec > 0.2, "drag fade-in handle (got %.3f)" % c2.fade_in_sec)
	d.undo()
	var r1 := grid.clip_rect(p.clips[0])
	var r2 := grid.clip_rect(p.clips[1])
	d.clear_selection()
	drag(grid, Vector2(r1.position.x - 5, 1), Vector2(r2.end.x - 5, r2.end.y - 2))
	check(d.selection.size() == 2 and d.is_selected(p.clips[0]) and d.is_selected(p.clips[1]), "marquee selects two clips (got %d)" % d.selection.size())
	var s1 := p.clips[0].start_sec
	var s2 := p.clips[1].start_sec
	r = grid.clip_rect(p.clips[0])
	drag(grid, r.get_center(), r.get_center() + Vector2(0.1 * grid.view.pixels_per_sec, 0))
	check(is_equal_approx(p.clips[0].start_sec, s1 + 0.1) and is_equal_approx(p.clips[1].start_sec, s2 + 0.1), "multi-selection moves together")
	d.undo()
	check(is_equal_approx(p.clips[0].start_sec, s1) and is_equal_approx(p.clips[1].start_sec, s2), "undo multi-move")
	click(grid, Vector2(grid.view.time_to_x(2.5), grid.row_h * 5.5))
	click(grid, Vector2(grid.view.time_to_x(2.5), grid.row_h * 5.5), MOUSE_BUTTON_LEFT, false)
	check(d.selection.is_empty() and is_equal_approx(d.playhead_sec, 2.5), "click empty: deselect + seek")

	print("--- UI: curve graph ---")
	d.select_clip(c4)
	await frames(tree, 6)
	var g := screen.timeline.graph
	d.set_edit_mode(AWDocument.EditMode.CURVES)
	await frames(tree, 2)
	var wet: AWCurve = ch.curves[2]
	var k1: Dictionary = ch.get_keys(wet)[1]
	var kp := g.key_pos(wet, k1)
	click(g, kp)
	click(g, kp, MOUSE_BUTTON_LEFT, false)
	check(d.active_curve == wet and g.selected_keys == [1], "click key selects curve and key")
	drag(g, kp, kp + Vector2(0, 40))
	var k1b: Dictionary = ch.get_keys(wet)[1]
	check(k1b.v < k1.v - 0.05 and is_equal_approx(k1b.t, k1.t), "drag key down lowers value, keeps time")
	d.undo()
	check(is_equal_approx(ch.get_keys(wet)[1].v, k1.v), "undo key drag")
	var hp := g.handle_pos(wet, ch.get_keys(wet)[1], "out")
	var in_before: Vector2 = ch.get_keys(wet)[1]["in"]
	drag(g, hp, hp + Vector2(0, -30))
	var kh: Dictionary = ch.get_keys(wet)[1]
	check((kh.out as Vector2).y > 0.0, "drag out-handle up tilts it")
	check((kh["in"] as Vector2).y < 0.0 and (kh["in"] as Vector2) != in_before, "balanced: in-handle follows")
	d.undo()
	var nkeys := ch.get_keys(wet).size()
	var ip := Vector2(g.local_to_x(2.2), g.val_to_y(wet, 0.72))
	click(g, ip, MOUSE_BUTTON_LEFT, true, true)
	click(g, ip, MOUSE_BUTTON_LEFT, false)
	check(ch.get_keys(wet).size() == nkeys + 1, "double-click inserts key on active curve")
	g.delete_selected_keys()
	check(ch.get_keys(wet).size() == nkeys, "delete selected key")
	d.undo(); d.undo()
	check(ch.get_keys(wet).size() == nkeys, "undo insert")
	var chorus: AWCurve = ch.curves[3]
	var ck := ch.get_keys(chorus).size()
	# Pick the time where the chorus line is furthest from the other curves, so the test
	# doesn't depend on how tall the graph happens to be.
	var best_t := 1.5
	var best_gap := -1.0
	for ti in range(3, 25):
		var tt := ti * 0.1
		var yc := g.val_to_y(chorus, ch.sample_norm(chorus, tt))
		var gap := INF
		for oc: AWCurve in ch.curves:
			if oc != chorus:
				gap = minf(gap, absf(g.val_to_y(oc, ch.sample_norm(oc, tt)) - yc))
		if gap > best_gap:
			best_gap = gap
			best_t = tt
	var on_line := Vector2(g.local_to_x(best_t), g.val_to_y(chorus, ch.sample_norm(chorus, best_t)))
	click(g, on_line, MOUSE_BUTTON_LEFT, true, true)
	click(g, on_line, MOUSE_BUTTON_LEFT, false)
	check(ch.get_keys(chorus).size() == ck + 1 and d.active_curve == chorus, "double-click on another curve's line inserts there")
	d.undo()
	d.set_active_curve(wet)
	var a := g.key_pos(wet, ch.get_keys(wet)[0])
	var b := g.key_pos(wet, ch.get_keys(wet)[2])
	drag(g, Vector2(a.x - 8, 2), Vector2(b.x + 8, g.size.y - 2))
	check(g.selected_keys.size() == 3, "box-select keys on active curve (got %d)" % g.selected_keys.size())

	print("--- UI: dots and cards ---")
	# The Reverb card has a panel now; this section tests the generic rows, so show them for it.
	AWPanelRegistry.suppressed = PackedStringArray(["Reverb"])
	d.project_changed.emit(true)
	var dots: AWCurveDots = screen.timeline.dots
	dots._layout()
	var first: Array = dots._placed[0]
	var fc: AWCurve = first[0]
	click(dots, first[1])
	check(fc.display == AWCurve.Display.DIM, "dot column click cycles display")
	click(dots, first[1])
	click(dots, first[1])
	check(fc.display == AWCurve.Display.ON, "three clicks back to On")
	await frames(tree, 4)
	var cards := screen.chain_panel._cards
	check(cards.size() == ch.effects.size(), "one card per effect (%d)" % cards.size())
	var lim_card: AWEffectCard = cards[2]
	var row: AWParamRow = lim_card.rows[0]
	check(row.curve() == null and row._slider.visible, "uncurved param shows slider + field")
	var lim: AWEffect = row.effect
	row._on_menu(1)
	await frames(tree, 4)
	check(ch.get_curve(lim.id, "room_size") != null, "right-click > Make Curve creates curve")
	cards = screen.chain_panel._cards
	var row2: AWParamRow = (cards[2] as AWEffectCard).rows[0]
	check(not row2._slider.visible and row2._curve_value.visible, "curved param shows curve value instead")
	d.undo()
	await frames(tree, 4)
	var row3: AWParamRow = (screen.chain_panel._cards[2] as AWEffectCard).rows[0]
	row3._slider.drag_started.emit()
	row3._slider.value = 0.25
	row3._slider.drag_ended.emit(true)
	check(is_equal_approx(ch.effects[2].get_param("room_size"), 0.25), "slider drag sets value")
	d.undo()
	check(is_equal_approx(ch.effects[2].get_param("room_size"), 0.8), "slider drag is one undo step")

	AWPanelRegistry.suppressed = PackedStringArray()
	print("--- trim sync ---")
	d.select_clip(c4)
	await frames(tree, 4)
	var probe_times := [1.0, 1.5, 2.0, 2.8]
	var before := []
	for t: float in probe_times:
		for cv in ch.curves:
			before.append(ch.sample(cv, c4.project_to_local(t)))
	var w0 := c4.warp()
	var s0 := w0.unwarp(0.5)
	var nk := ch.get_keys(ch.curves[2]).size()
	var r4 := grid.clip_rect(c4)
	drag(grid, Vector2(r4.position.x + 2, r4.get_center().y), Vector2(r4.position.x + 2 + 0.5 * grid.view.pixels_per_sec, r4.get_center().y))
	check(is_equal_approx(c4.start_sec, 0.5) and absf(c4.source_offset_sec - s0) < 1e-4, "left trim to 0.5 s cuts %.3f s of audio" % s0)
	var after := []
	for t: float in probe_times:
		for cv in ch.curves:
			after.append(ch.sample(cv, c4.project_to_local(t)))
	var same := true
	for i in before.size():
		same = same and absf(float(before[i]) - float(after[i])) < 0.002
	check(same, "after left trim, every curve has the same value at the same moment")
	check(ch.get_keys(ch.curves[2]).size() == nk, "keys before the new start are kept (hidden), not deleted")
	r4 = grid.clip_rect(c4)
	drag(grid, Vector2(r4.position.x + 2, r4.get_center().y), Vector2(r4.position.x + 2 - 0.5 * grid.view.pixels_per_sec, r4.get_center().y))
	check(is_equal_approx(c4.start_sec, 0.0) and absf(ch.get_keys(ch.curves[2])[0].t) < 1e-3, "trimming back out restores the original keys")
	d.undo()
	d.undo()
	check(is_equal_approx(c4.start_sec, 0.0) and is_equal_approx(ch.get_keys(ch.curves[2])[0].t, 0.0), "two undos restore clip and keys")
	d.redo()
	check(is_equal_approx(c4.start_sec, 0.5) and absf(ch.get_keys(ch.curves[2])[0].t + s0) < 1e-4, "redo trim re-shifts keys")
	d.undo()

	print("--- playback-rate sync ---")
	var L := c4.length_sec
	var exact := L * (pow(2.0, 5.0 / 12.0) - 1.0) / ((5.0 / 12.0) * log(2.0))
	check(absf(c4.play_length() - exact) < 1e-3, "pitch 0 -> -5 st: %.2f s of audio plays for %.3f s (exact %.3f)" % [L, c4.play_length(), exact])
	var ok_rt := true
	for sv: float in [-0.4, 0.0, 0.7, 1.9, 2.8, 3.5]:
		ok_rt = ok_rt and absf(c4.warp().unwarp(c4.warp().warp(sv)) - sv) < 1e-4
	check(ok_rt, "warp/unwarp round trip, incl. beyond the clip")
	var rate_start := (c4.project_to_local(0.1) - c4.project_to_local(0.0)) / 0.1
	var rate_end := (c4.project_to_local(c4.end_sec()) - c4.project_to_local(c4.end_sec() - 0.1)) / 0.1
	check(absf(rate_start - 1.0) < 0.02 and absf(rate_end - pow(2.0, -5.0 / 12.0)) < 0.02, "curve playhead speed: %.2fx at start, %.2fx at end" % [rate_start, rate_end])
	d.set_curve_time(AWDocument.CurveTime.CLIP)
	check(absf(c4.project_to_local(c4.end_sec()) - L) < 1e-3, "curve clock reaches the last key exactly when the clip ends")
	check(absf(grid.clip_rect(c4).size.x - c4.play_length() * grid.view.pixels_per_sec) < 0.01, "timeline block spans the played duration")
	var c2b := p.clips[1]
	d.set_param(c2b.chain.effects[0], "pitch_semitones", -12.0)
	check(absf(c2b.play_length() - 2.0 * c2b.length_sec) < 1e-4, "static -12 st doubles a clip's length")
	d.undo()
	check(absf(c2b.play_length() - c2b.length_sec) < 1e-4, "undo restores length")
	d.set_curve_time(AWDocument.CurveTime.PROJECT)
	await frames(tree, 2)
	var last_k: Dictionary = ch.get_keys(ch.curves[2]).back()
	check(absf(g.key_pos(ch.curves[2], last_k).x - grid.view.time_to_x(c4.end_sec()) * 0.0 - g.view.time_to_x(c4.end_sec())) < 0.5, "Project Time: last key drawn at the clip's end on the timeline")
	var k2p := g.key_pos(ch.curves[2], ch.get_keys(ch.curves[2])[2])
	drag(g, k2p, k2p + Vector2(20, 0))
	var moved: Dictionary = ch.get_keys(ch.curves[2])[2]
	check(absf(g.key_pos(ch.curves[2], moved).x - (k2p.x + 20.0)) < g.view.pixels_per_sec * 0.05 + 0.5, "Project Time: dragged key follows the mouse through the warp")
	d.undo()
	d.set_curve_time(AWDocument.CurveTime.CLIP)

	print("--- value axis ---")
	var labels := func(ticks: Array) -> Array: return ticks.map(func(t: Array) -> String: return t[1])
	var ceil_ticks := AWCurveAxis.ticks(ch, ch.curves[1], 400.0)
	var cl: Array = labels.call(ceil_ticks)
	check(cl.has("0") and cl.has("-6") and cl.has("-12") and cl.has("-24"), "dB axis (Ceiling): %s" % str(cl))
	var spaced := true
	for i in range(1, ceil_ticks.size()):
		spaced = spaced and (ceil_ticks[i][0] - ceil_ticks[i - 1][0]) * 400.0 >= AWCurveAxis.MIN_GAP - 0.01
	check(spaced, "dB ticks never closer than %d px" % AWCurveAxis.MIN_GAP)
	var wl: Array = labels.call(AWCurveAxis.ticks(ch, ch.curves[2], 400.0))
	check(wl.front() == "0" and wl.back() == "1" and wl.has("0.5"), "linear axis (Wet): %s" % str(wl))
	var pl: Array = labels.call(AWCurveAxis.ticks(ch, ch.curves[0], 400.0))
	check(pl.has("0") and pl.has("+12") and pl.has("-12"), "semitone axis (Pitch): %s" % str(pl))
	var lpa := d.add_effect(ch, "Low Pass")
	var lpca := d.make_curve(ch, lpa, "cutoff_hz")
	var ll: Array = labels.call(AWCurveAxis.ticks(ch, lpca, 400.0))
	check(ll.has("100") and ll.has("1k") and ll.has("10k"), "log axis (Cutoff): %s" % str(ll))
	var lt := AWCurveAxis.ticks(ch, lpca, 400.0)
	var even := absf((lt[ll.find("1k")][0] - lt[ll.find("100")][0]) - (lt[ll.find("10k")][0] - lt[ll.find("1k")][0])) < 1e-6
	check(even, "log axis: 100->1k and 1k->10k are the same height")
	var small: Array = labels.call(AWCurveAxis.ticks(ch, lpca, 90.0))
	check(small.size() >= 2 and small.size() < ll.size(), "short graph drops ticks to stay readable (%d vs %d)" % [small.size(), ll.size()])
	check(AWCurveAxis.format_tick(1500.0, "Hz") == "1.5k" and AWCurveAxis.format_tick(6.0, "dB") == "+6" and AWCurveAxis.format_tick(-0.25, "") == "-0.25", "tick formatting")
	var axis: AWCurveAxis = screen.timeline.axis
	d.set_active_curve(null)
	check(axis.axis_curve() == null, "axis is empty with no selected curve")
	d.set_active_curve(lpca)
	check(axis.axis_curve() == lpca, "axis follows the selected curve")
	if shots:
		await frames(tree, 2)
		g.selected_keys = [0]
		g.queue_redraw()
		await shot(tree, "aw_axis_log.png")
		d.set_active_curve(ch.curves[1])
		await frames(tree, 2)
		g.selected_keys = [1]
		g.queue_redraw()
		await shot(tree, "aw_axis_db.png")
	d.undo(); d.undo()
	check(not ch.effects.has(lpa), "undo axis test effects")

	print("--- scales ---")
	check(absf(AWCurveMath.to_norm(AWCurve.Scale.LOG, 1000.0, 20.0, 20500.0) - 0.5644) < 0.001, "log: 1 kHz sits at 56% of 20 Hz-20.5 kHz")
	check(absf(AWCurveMath.from_norm(AWCurve.Scale.LOG, AWCurveMath.to_norm(AWCurve.Scale.LOG, 440.0, 20.0, 20500.0), 20.0, 20500.0) - 440.0) < 0.01, "log round trip")
	var n0 := AWCurveMath.to_norm(AWCurve.Scale.FADER, 0.0, -60.0, 24.0)
	var n6 := AWCurveMath.to_norm(AWCurve.Scale.FADER, -6.0, -60.0, 24.0)
	var n40 := AWCurveMath.to_norm(AWCurve.Scale.FADER, -40.0, -60.0, 24.0)
	check(n0 - n6 > (n6 - n40) / 6.0, "fader: more room near 0 dB than at -40 dB (per dB)")
	check(absf(AWCurveMath.from_norm(AWCurve.Scale.FADER, n6, -60.0, 24.0) + 6.0) < 0.01, "fader round trip")
	check(ch.curves[1].scale == AWCurve.Scale.FADER and absf(ch.sample(ch.curves[1], 1.0) + 2.0) < 0.01, "demo ceiling curve is dB/fader, reads -2 dB")
	check(ch.curves[0].scale == AWCurve.Scale.LINEAR and ch.curves[2].scale == AWCurve.Scale.LINEAR, "pitch and wet stay linear")
	var lp := d.add_effect(ch, "Low Pass")
	var lpc := d.make_curve(ch, lp, "cutoff_hz")
	check(lpc.scale == AWCurve.Scale.LOG and absf(ch.sample(lpc, 0.5) - 2000.0) < 0.5, "cutoff curve is log and holds 2000 Hz")
	var lk := ch.get_keys(lpc)
	lk[0].v = 0.0
	lk[1].v = 1.0
	lk[0]["mode"] = AWCurve.HandleMode.LINEAR
	lk[1]["mode"] = AWCurve.HandleMode.LINEAR
	d.set_curve_keys(ch, lpc, lk, "sweep")
	var mid := ch.sample(lpc, c4.length_sec * 0.5)
	check(absf(mid - sqrt(20.0 * 20500.0)) < 5.0, "straight line on log scale = even sweep in octaves (mid %.0f Hz)" % mid)
	# Curves are not limited to the clip: a key can sit well past its end.
	check(d.curve_domain_len() > c4.length_sec * 10.0 and d.curve_span_len() >= c4.length_sec, "curve domain is not the clip length (span %.2f s, clip %.2f s)" % [d.curve_span_len(), c4.length_sec])
	var far := ch.get_keys(lpc)
	far.append({"t": c4.length_sec + 5.0, "v": 0.5, "in": Vector2(-0.5, 0.0), "out": Vector2(0.5, 0.0), "mode": AWCurve.HandleMode.BALANCED})
	d.set_curve_keys(ch, lpc, far, "far key")
	check(ch.get_keys(lpc).size() == 3 and absf(ch.get_keys(lpc)[2].t - (c4.length_sec + 5.0)) < 1e-4, "a key can be placed 5 s beyond the clip end")
	d.undo()
	d.remove_curve(ch, lpc)
	await frames(tree, 4)
	var lp_card: AWEffectCard = screen.chain_panel._cards.back()
	check(lp_card.effect == lp and lp_card.panel.cutoff_knob.binding.scale == AWCurve.Scale.LOG, "cutoff knob is logarithmic")
	d.undo(); d.undo(); d.undo(); d.undo()
	check(not ch.effects.has(lp), "undo back to before Low Pass")
	print("--- control kit and effect panels ---")
	await panel_tests(screen)
	print("--- export ---")
	await export_tests(tree, screen)
	if shots:
		var lp2 := d.add_effect(ch, "Low Pass")
		var c2v := d.make_curve(ch, lp2, "cutoff_hz")
		var k2 := ch.get_keys(c2v)
		k2[0].v = ch.to_norm(c2v, 300.0)
		k2[1].v = ch.to_norm(c2v, 12000.0)
		k2.insert(1, {"t": 1.0, "v": ch.to_norm(c2v, 8000.0), "in": Vector2(-0.2, 0), "out": Vector2(0.2, 0), "mode": AWCurve.HandleMode.BALANCED})
		d.set_curve_keys(ch, c2v, k2, "demo")
		await frames(tree, 4)
		await shot(tree, "aw_scales.png")
		d.undo(); d.undo(); d.undo()
	print("--- LFO ---")
	d.select_clip(c4)
	d.set_curve_time(AWDocument.CurveTime.CLIP)
	await frames(tree, 4)
	var wet2: AWCurve = ch.curves[2]
	var lf := d.add_lfo(ch, wet2)
	check(wet2.lfo == lf and is_equal_approx(lf.end_sec, c4.length_sec), "add LFO spans the whole clip")
	d.undo()
	check(wet2.lfo == null, "undo add LFO")
	d.redo()
	check(wet2.lfo == lf, "redo add LFO")
	d.set_props(lf, {"min_value": 0.2, "max_value": 0.8, "freq_hz": 4.0, "fade_in_sec": 0.0, "fade_out_sec": 0.0, "shape": AWLfo.Shape.SINE}, "setup")
	check(absf(ch.sample(wet2, 1.0) - 0.5) < 1e-4 and absf(ch.sample(wet2, 1.0625) - 0.8) < 1e-4 and absf(ch.sample(wet2, 1.1875) - 0.2) < 1e-4, "sine LFO: 0.5 at phase 0, Max at 1/4 cycle, Min at 3/4")
	d.set_props(lf, {"shape": AWLfo.Shape.SQUARE}, "sq")
	check(absf(ch.sample(wet2, 1.01) - 0.8) < 1e-4 and absf(ch.sample(wet2, 1.14) - 0.2) < 1e-4, "square LFO jumps between Max and Min")
	d.set_props(lf, {"shape": AWLfo.Shape.SINE, "fade_in_sec": 0.5}, "fade")
	var b25 := ch.from_norm(wet2, ch.base_norm(wet2, 0.25))
	var l25 := 0.2 + 0.6 * (0.5 + 0.5 * sin(TAU * 4.0 * 0.25))
	check(absf(ch.sample(wet2, 0.0) - ch.from_norm(wet2, ch.base_norm(wet2, 0.0))) < 1e-4 and absf(ch.sample(wet2, 0.25) - (b25 + (l25 - b25) * 0.5)) < 1e-4, "fade in: starts on the curve, halfway at half the fade")
	d.set_props(lf, {"end_sec": 2.0}, "span")
	check(absf(ch.sample(wet2, 2.3) - ch.from_norm(wet2, ch.base_norm(wet2, 2.3))) < 1e-4, "after the LFO's span the curve plays alone")
	d.undo()
	d.set_props(lf, {"enabled": false}, "off")
	check(absf(ch.sample(wet2, 1.0625) - ch.from_norm(wet2, ch.base_norm(wet2, 1.0625))) < 1e-4, "LFO off = curve only")
	d.undo()

	var lpl := d.add_effect(ch, "Low Pass")
	var cut := d.make_curve(ch, lpl, "cutoff_hz")
	var cl2 := d.add_lfo(ch, cut)
	d.set_props(cl2, {"min_value": 200.0, "max_value": 5000.0, "fade_in_sec": 0.0, "fade_out_sec": 0.0, "freq_hz": 2.0}, "log")
	check(absf(ch.sample(cut, 1.0) - 1000.0) < 0.5, "log LFO centre is the geometric mean (%.1f Hz)" % ch.sample(cut, 1.0))
	d.undo(); d.undo(); d.undo(); d.undo()
	check(not ch.effects.has(lpl), "undo log LFO test")

	print("--- LFO panel ---")
	g._menu_curve = wet2
	g._on_menu(44)
	await frames(tree, 4)
	var panel := screen.lfo_panel
	check(panel._curve == wet2 and d.lfo_curve == wet2 and d.active_curve == wet2, "right-click > Edit LFO opens it in the LFO dock")
	var fk := panel.find_child("freq_hz_knob", true, false) as AWKnob
	check(fk != null and fk.binding.scale == AWCurve.Scale.LOG and is_equal_approx(fk.binding.hi, 100.0) and panel.knobs.size() == 14, "fourteen knobs; Freq is logarithmic, up to 100 Hz")
	var f0 := lf.freq_hz
	click(fk, Vector2(40, 40))
	move(fk, Vector2(40, -20))
	click(fk, Vector2(40, -20), MOUSE_BUTTON_LEFT, false)
	check(lf.freq_hz > f0 * 2.0, "Freq knob drag raises the rate (%.2f Hz)" % lf.freq_hz)
	d.undo()
	check(is_equal_approx(lf.freq_hz, f0), "knob drag is one undo step")
	var mk := panel.find_child("max_value_knob", true, false) as AWKnob
	mk.open_entry()
	mk._entry.text_submitted.emit("0.95")
	check(is_equal_approx(lf.max_value, 0.95), "typing 0.95 into Max sets the value")
	check(mk.binding.text() == AWEffectLibrary.format_value("Reverb", "wet", 0.95), "Max shows like its parameter (%s)" % mk.binding.text())
	d.undo()
	var fadek := panel.find_child("fade_in_sec_knob", true, false) as AWKnob
	check(is_equal_approx(fadek.binding.hi, maxf(lf.span(), 0.01)), "Fade In knob ranges over the LFO span")

	# Freq acceleration and fade smoothing (model, then knobs).
	var ml := AWLfo.new()
	ml.freq_hz = 4.0
	ml.start_sec = 0.0
	ml.end_sec = 4.0
	check(is_equal_approx(ml.phase(0.5), 2.0), "phase without acceleration is freq * time")
	ml.freq_accel = 4.0
	check(is_equal_approx(ml.phase(0.5), 2.5) and is_equal_approx(ml.time_of_phase(2.5), 0.5), "positive accel speeds the LFO up (phase 2.5 at 0.5 s)")
	ml.freq_accel = -8.0
	check(is_equal_approx(ml.phase(1.0), 1.0) and is_equal_approx(ml.phase(3.0), 1.0), "negative accel stops at 0 Hz and holds the phase")
	check(is_inf(ml.time_of_phase(1.5)), "a stopped LFO never reaches a later phase")
	ml.fade_in_sec = 1.0
	ml.fade_out_sec = 0.0
	check(is_equal_approx(ml.envelope(0.25), 0.25), "straight fade is linear")
	ml.fade_smoothing = 1.0
	check(is_equal_approx(ml.envelope(0.25), 0.15625) and is_equal_approx(ml.envelope(1.0), 1.0) and is_equal_approx(ml.envelope(0.5), 0.5), "smoothing eases the fade (0.156 at a quarter, ends unchanged)")
	var ak := panel.find_child("freq_accel_knob", true, false) as AWKnob
	var sk := panel.find_child("fade_smoothing_knob", true, false) as AWKnob
	check(ak != null and ak.bipolar and sk != null, "Accel (bipolar) and Smoothing knobs exist")
	ak.open_entry()
	ak._entry.text_submitted.emit("-25")
	check(is_equal_approx(lf.freq_accel, -2.5) and ak.binding.text() == "-25.0 dHz/s", "typing -25 sets -2.5 Hz/s, shown as %s" % ak.binding.text())
	ak.open_entry()
	ak._entry.text_submitted.emit("1000")
	check(is_equal_approx(lf.freq_accel, 100.0) and ak.binding.text() == "1000.0 dHz/s", "Accel reaches 1000 dHz/s (100 Hz/s), shown as %s" % ak.binding.text())
	ak.open_entry()
	ak._entry.text_submitted.emit("-25")
	var fine_a := ak.binding.from_norm(0.5 + 1.0 / 220.0)
	var wide_a := ak.binding.from_norm(0.75)
	check(absf(fine_a) <= 0.001 and absf(wide_a) > 0.5 and absf(ak.binding.to_norm(ak.binding.from_norm(0.8)) - 0.8) < 0.01, "Accel knob is fine near 0 and wide at the ends (1 px = %.3f Hz/s, 75%% = %.2f Hz/s)" % [fine_a, wide_a])
	# Decay and Depth start at 0: the whole sweep is used, fine at the start (not centred on 0).
	for kname: String in ["decay_sec_knob", "depth_knob"]:
		var uk := panel.find_child(kname, true, false) as AWKnob
		var ub := uk.binding if uk else null
		check(ub != null and is_equal_approx(ub.from_norm(0.0), 0.0) and is_equal_approx(ub.from_norm(1.0), ub.hi) and ub.from_norm(0.5) > 0.0 and ub.from_norm(0.5) <= ub.hi * 0.3 and absf(ub.to_norm(ub.from_norm(0.7)) - 0.7) < 0.01,
			"%s: 0 at the start, the full range across the sweep (half way = %.3f)" % [kname, ub.from_norm(0.5) if ub else -1.0])
	sk.open_entry()
	sk._entry.text_submitted.emit("0.6")
	check(is_equal_approx(lf.fade_smoothing, 0.6), "typing 0.6 sets the smoothing")
	while lf.freq_accel != 0.0 or lf.fade_smoothing != 0.0:
		d.undo()
	check(lf.freq_accel == 0.0 and lf.fade_smoothing == 0.0, "both are undoable")

	print("--- LFO list ---")
	var mlim: AWEffect = p.master_chain.effects[1]
	var mkey: String = AWEffectLibrary.param_schema(mlim.effect_type).keys()[0]
	var mcurve := d.make_curve(p.master_chain, mlim, mkey)
	d.add_lfo(p.master_chain, mcurve)
	await frames(tree, 4)
	var lfo_list := d.all_lfos()
	var labels_now: Array = lfo_list.map(func(e: Dictionary) -> String: return e["label"])
	var want_clip: String = c4.name + "\\Reverb\\Wet"
	var want_master: String = "Master\\%s\\%s" % [mlim.effect_type, AWEffectLibrary.param_label(mlim.effect_type, mkey)]
	check(labels_now.has(want_clip) and labels_now.has(want_master), "all_lfos lists clip and master LFOs: %s" % str(labels_now))
	check(labels_now[0] == want_master, "Master comes first in the list")
	check(panel.list_buttons.size() == lfo_list.size() and panel.list_buttons.any(func(b: Button) -> bool: return (b as AWPathButton).full_text == want_master), "the panel shows one button per LFO")
	var pfont := panel.get_theme_default_font()
	var pfs := panel.get_theme_default_font_size()
	check(AWTheme.middle_truncate(pfont, pfs, want_clip, 10000.0) == want_clip, "paths that fit are left alone")
	var narrow := AWTheme.middle_truncate(pfont, pfs, want_clip, 70.0)
	check(narrow.contains("…") and narrow.begins_with(want_clip.left(2)) and narrow.ends_with(want_clip.right(2)) and pfont.get_string_size(narrow, HORIZONTAL_ALIGNMENT_LEFT, -1, pfs).x <= 70.0, "a narrow path keeps its start and end, middle becomes an ellipsis (%s)" % narrow)
	var pb := panel.list_buttons[labels_now.find(want_clip)] as AWPathButton
	var pb_w := pb.size.x
	pb.size.x = 60.0
	pb._fit()
	check(pb.text.contains("…") and pb.tooltip_text == want_clip, "the list button truncates in the middle and keeps the full path as its tooltip (%s)" % pb.text)
	pb.size.x = pb_w
	pb._fit()
	panel.list_buttons[labels_now.find(want_master)].pressed.emit()
	await frames(tree, 4)
	check(d.chain_tab == AWDocument.ChainTab.MASTER and d.lfo_curve == mcurve and panel.visible, "clicking a Master LFO jumps to the Master chain and opens it")
	panel.list_buttons[labels_now.find(want_clip)].pressed.emit()
	await frames(tree, 4)
	check(d.chain_tab == AWDocument.ChainTab.CLIP and d.focus_clip == c4 and d.lfo_curve == wet2, "clicking a clip LFO selects that clip and opens it")
	d.remove_curve(p.master_chain, mcurve)
	await frames(tree, 3)
	check(panel.list_buttons.size() == lfo_list.size() - 1, "the list follows LFOs being removed")
	d.open_lfo(ch, wet2)
	await frames(tree, 3)

	var shape_btns: Array = panel.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.button_group != null and not String(b.name).begins_with("Mode") and not String(b.name).begins_with("Owner"))
	check(shape_btns.size() == 5, "five shape buttons")
	var rel_btn: Button = panel.find_child("ModeRelative", true, false)
	var abs_btn: Button = panel.find_child("ModeAbsolute", true, false)
	check(rel_btn != null and abs_btn != null and abs_btn.button_pressed, "Absolute / Relative buttons, Absolute by default")
	check(panel.knobs["max_value"].visible and not panel.knobs["depth"].visible, "Absolute shows Max and Min, hides Depth")
	rel_btn.pressed.emit()
	await frames(tree, 2)
	check(lf.mode == AWLfo.Mode.RELATIVE and panel.knobs["depth"].visible and not panel.knobs["max_value"].visible and not panel.knobs["min_value"].visible, "Relative picks the mode and swaps Max/Min for Depth")
	d.undo()
	await frames(tree, 2)
	check(lf.mode == AWLfo.Mode.ABSOLUTE and panel.knobs["max_value"].visible, "mode change undoes")
	for knob_prop in ["phase_deg", "jitter_rate", "jitter_depth", "glide", "decay_sec"]:
		check(panel.knobs.has(knob_prop), "LFO dock has a %s knob" % knob_prop)
	(shape_btns[1] as Button).pressed.emit()
	check(lf.shape == AWLfo.Shape.TRIANGLE, "shape button picks Triangle")
	d.undo()

	# --- Export group (UI state only; the render itself is milestone 5) ---
	var ep: AWProject = d.project
	check(ep.export_bit_depth == 16 and ep.export_end_is_auto() and ep.export_path == "assets/sfx/jump.wav", "export: defaults 16-bit, automatic end, assets/sfx/jump.wav")
	check(d.export_target() == "res://assets/sfx/jump.wav", "export: relative names live under res://")
	d.set_export_end(99999.0)
	check(is_equal_approx(ep.export_end_sec, AWProject.MAX_END_SEC), "export end: clamps to %.0f s" % AWProject.MAX_END_SEC)
	d.set_export_end(-5.0)
	check(ep.export_end_is_auto(), "export end: a negative value means automatic")
	d.set_export_bit_depth(32)
	var len32 := d.export_size_bytes()
	d.set_export_bit_depth(16)
	var len16 := d.export_size_bytes()
	check(len32 - 56 == 2 * (len16 - 44), "export: 32-bit float data is twice the size of 16-bit (header 56 vs 44 bytes)")
	# The demo chains hold a Reverb, which rings: switch every ringing card off to measure the bare end.
	var ring_off: Array[AWEffect] = []
	var ring_chains: Array = [ep.master_chain]
	for rc in ep.clips:
		ring_chains.append(rc.chain)
	for rch: AWChain in ring_chains:
		for re in rch.effects:
			if not re.bypass and AWEffectLibrary.engine_rings(re.effect_type):
				re.bypass = true
				ring_off.append(re)
	var no_tail := d.export_end_sec()
	var last := ep.last_clip_end_sec()
	check(absf(no_tail - last) < 0.0001, "export end (auto): last clip end with no ringing effects (%.3f s)" % no_tail)
	var ring := AWEffect.create("Low Pass", ep.clips[0].chain.new_effect_id())
	ep.clips[0].chain.effects.append(ring)
	var with_tail := d.export_end_sec()
	check(absf(with_tail - maxf(last, ep.clips[0].start_sec + ep.clips[0].play_length() + AWProject.AUTO_TAIL_SEC)) < 0.0001, "export end (auto): a ringing card adds the automatic tail (%.3f s)" % with_tail)
	d.set_export_end(5.0)
	check(is_equal_approx(d.export_end_sec(), 5.0) and not ep.export_end_is_auto(), "export end: a placed marker is used as it is")
	if screen.engine.core != null:
		screen.engine.render_preview_range(0.0, 0.01)
		var plan_end := float(screen.engine.core.call("get_plan_end")) / AudioServer.get_mix_rate()
		check(absf(plan_end - 5.0) < 0.001, "export end: the engine's plan ends at the marker (%.4f s)" % plan_end)
		d.set_export_end(1.0)
		screen.engine.render_preview_range(0.0, 0.01)
		plan_end = float(screen.engine.core.call("get_plan_end")) / AudioServer.get_mix_rate()
		check(absf(plan_end - 1.0) < 0.001, "export end: a marker before the last clip cuts the sound short (%.4f s)" % plan_end)
	d.undo()
	check(is_equal_approx(ep.export_end_sec, 5.0), "export end: undo restores the previous marker")
	var xp: AWExportPanel = screen.export_panel
	check(absf(xp._end.value - 5.0) < 0.001 and not xp._auto.button_pressed, "export dock: End field shows the marker, Auto is off")
	xp._auto.button_pressed = true
	check(ep.export_end_is_auto() and xp._auto.button_pressed, "export dock: Auto puts the marker back on the clips")
	xp._end.value = 7.25
	check(is_equal_approx(ep.export_end_sec, 7.25), "export dock: typing a time places the marker")
	d.set_export_end(1.0)
	var ruler: AWTimeRuler = screen.timeline._ruler
	var ry := ruler.size.y - 6.0
	drag(ruler, Vector2(d.timeline_view.time_to_x(1.0), ry), Vector2(d.timeline_view.time_to_x(1.4), ry))
	check(absf(ep.export_end_sec - 1.4) < 0.06 and not ep.export_end_is_auto(), "ruler: dragging the end flag moves the marker (%.3f s)" % ep.export_end_sec)
	d.undo()
	check(is_equal_approx(ep.export_end_sec, 1.0), "ruler: the drag is one undo step")
	d.set_export_end(-1.0)
	ep.clips[0].chain.effects.erase(ring)
	check(absf(d.export_end_sec() - no_tail) < 0.0001, "export end (auto): removing the card removes the tail")
	for re in ring_off:
		re.bypass = false
	var tmp := "user://aw_selftest_overwrite.wav"
	d.set_export_path(tmp)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	check(not d.export_will_overwrite(), "export: a new file name does not warn")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_8(0)
	f.close()
	check(d.export_will_overwrite(), "export: an existing file warns")
	d.set_export_path(tmp)
	var xpanel: AWExportPanel = screen.export_panel
	check(xpanel != null and xpanel._warn.visible and xpanel._path.has_theme_stylebox_override("normal"), "export: overwrite shows the red warning and red field")
	d.set_export_path("assets/sfx/does_not_exist_%d.wav" % 12345)
	check(not xpanel._warn.visible and not xpanel._path.has_theme_stylebox_override("normal"), "export: field returns to normal")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	d.set_export_path("assets/sfx/jump.wav")

	if shots:
		d.seek(1.1)
		await shot(tree, "aw_lfo_panel.png")
		# Relative mode with the newer parameters, scrolled to the knobs.
		var saved_sig := lf.signature()
		lf.mode = AWLfo.Mode.RELATIVE
		lf.depth = 0.15
		lf.jitter_rate = 0.6
		lf.jitter_depth = 0.5
		lf.decay_sec = 1.2
		d.project_changed.emit(false)
		var sc: ScrollContainer = screen.lfo_panel.get_child(0)
		await frames(tree, 3)
		sc.scroll_vertical = 150
		await shot(tree, "aw_lfo_relative.png")
		sc.scroll_vertical = 330
		await shot(tree, "aw_lfo_knobs.png")
		sc.scroll_vertical = 0
		lf.mode = AWLfo.Mode.ABSOLUTE
		lf.depth = 0.1
		lf.jitter_rate = 0.0
		lf.jitter_depth = 0.0
		lf.decay_sec = 0.0
		d.project_changed.emit(false)
		check(lf.signature() == saved_sig, "LFO restored after the relative-mode screenshot")
	d.close_lfo()
	await frames(tree, 4)
	check(screen.lfo_panel._curve == null and wet2.lfo == lf, "deselecting empties the editor, the LFO stays on its curve")
	check(wet2.lfo == lf, "LFO kept after closing")

	print("--- LFO sync ---")
	var probes := [0.6, 1.2, 1.9, 2.6]
	var vals := probes.map(func(t: float) -> float: return ch.sample(wet2, c4.project_to_local(t)))
	r4 = grid.clip_rect(c4)
	drag(grid, Vector2(r4.position.x + 2, r4.get_center().y), Vector2(r4.position.x + 2 + 0.3 * grid.view.pixels_per_sec, r4.get_center().y))
	var vals2 := probes.map(func(t: float) -> float: return ch.sample(wet2, c4.project_to_local(t)))
	var same_lfo := true
	for i in probes.size():
		same_lfo = same_lfo and absf(float(vals[i]) - float(vals2[i])) < 0.003
	check(same_lfo, "left trim keeps the LFO on the same moments")
	d.undo()
	check(absf(lf.start_sec) < 1e-6, "undo trim restores LFO span")
	d.split_clip(c4, 1.5)
	var rh: AWClip = p.clips[p.clips.find(c4) + 1]
	var rc: AWCurve = rh.chain.curves[2]
	check(rc.lfo != null and rc.lfo != lf, "split copies the LFO")
	check(absf(rh.chain.sample(rc, rh.project_to_local(2.0)) - ch.sample(wet2, c4.project_to_local(2.0) if false else c4.warp().unwarp(2.0 - c4.start_sec))) < 0.003, "right half's LFO continues in phase")
	d.undo()
	r4 = grid.clip_rect(c4)
	var len_before := c4.length_sec
	drag(grid, Vector2(r4.end.x - 2, r4.get_center().y), Vector2(r4.end.x - 2 + 0.3 * grid.view.pixels_per_sec, r4.get_center().y))
	check(c4.length_sec > len_before + 0.1 and absf(lf.end_sec - c4.length_sec) < 1e-4, "right trim: an LFO reaching the end keeps reaching it")
	d.undo()
	check(absf(lf.end_sec - len_before) < 1e-4 and absf(c4.length_sec - len_before) < 1e-4, "undo right trim restores both")
	var pl0 := c4.play_length()
	var plfo := d.add_lfo(ch, ch.curves[0])
	d.set_props(plfo, {"min_value": -12.0, "max_value": -12.0, "fade_in_sec": 0.0, "fade_out_sec": 0.0}, "pitch lfo")
	check(absf(c4.play_length() - 2.0 * c4.length_sec) < 0.01, "an LFO on Pitch changes the clip's timing (held at -12 st doubles it)")
	d.undo(); d.undo()
	check(absf(c4.play_length() - pl0) < 1e-4, "undo pitch LFO")

	print("--- bake ---")
	var before_bake := []
	for i in 40:
		before_bake.append(ch.sample_norm(wet2, i * 0.07))
	d.bake_lfo(ch, wet2)
	check(wet2.lfo == null and ch.get_keys(wet2).size() > 100, "bake replaces the LFO with %d keys" % ch.get_keys(wet2).size())
	var worst := 0.0
	for i in 40:
		worst = maxf(worst, absf(ch.sample_norm(wet2, i * 0.07) - float(before_bake[i])))
	check(worst < 0.03, "baked keys reproduce the LFO (worst error %.4f)" % worst)
	d.undo()
	check(wet2.lfo == lf and ch.get_keys(wet2).size() == 4, "undo bake restores LFO and keys")
	for shp: int in [AWLfo.Shape.SINE, AWLfo.Shape.TRIANGLE, AWLfo.Shape.SAW, AWLfo.Shape.RANDOM]:
		d.set_props(lf, {"shape": shp, "fade_in_sec": 0.3, "fade_out_sec": 0.4}, "shape")
		var ref := []
		for i in 57:
			ref.append(ch.sample_norm(wet2, 0.013 + i * 0.049))
		d.bake_lfo(ch, wet2)
		var w2 := 0.0
		for i in 57:
			w2 = maxf(w2, absf(ch.sample_norm(wet2, 0.013 + i * 0.049) - float(ref[i])))
		check(w2 < 0.03, "bake %s with fades: worst error %.4f" % [AWLfo.SHAPE_NAMES[shp], w2])
		d.undo()
		d.undo()
	d.remove_lfo(wet2)
	check(wet2.lfo == null, "remove LFO")
	d.undo()
	check(wet2.lfo == lf, "undo remove LFO")
	var guard := 0
	while wet2.lfo != null and guard < 40:
		d.undo()
		guard += 1
	check(wet2.lfo == null, "undo all the way back to no LFO")

	if shots:
		d.seek(1.1)
		d.set_active_curve(ch.curves[2])
		g.selected_keys = [2]
		g.queue_redraw()
		g._hover_curve = ch.curves[3]
		g._hover_pos = Vector2(g.local_to_x(1.5), g.val_to_y(ch.curves[3], ch.sample(ch.curves[3], 1.5)))
		await shot(tree, "aw_main.png")
		g._hover_curve = null
		d.set_curve_time(AWDocument.CurveTime.PROJECT)
		d.select_clip(p.clips[0])
		await shot(tree, "aw_clip1_project_time.png")
		d.set_chain_tab(AWDocument.ChainTab.MASTER)
		await shot(tree, "aw_master.png")
	print("--- save and open ---")
	await save_open_tests(tree, screen)
	await source_tests(tree, screen)
	await recovery_tests(tree, screen)
	await load_tests(tree, screen)
	await empty_start_tests(tree, screen)
	await reexport_tests(tree, screen)
	await import_tests(tree, screen)
	await grid_edit_tests(tree, screen)
	await reverse_fade_tests(tree, screen)
	await row_tests(tree, screen)
	await multi_edit_tests(tree, screen)
	await timing_tests(tree, screen)
	await navigation_tests(tree, screen)
	await layer_tests(tree, screen)
	await group_tests(tree, screen)
	await shared_chain_tests(tree, screen)
	await editor_resource_tests(tree, screen)
	print("SELFTEST DONE fails=%d" % fails)
