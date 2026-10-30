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


static func click(ctrl: Control, pos: Vector2, button := MOUSE_BUTTON_LEFT, pressed := true, double := false, shift := false, ctrl_key := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = ctrl.get_global_transform() * pos
	e.double_click = double
	e.shift_pressed = shift
	e.ctrl_pressed = ctrl_key
	ctrl._gui_input(e)


static func move(ctrl: Control, pos: Vector2, shift := false) -> void:
	var e := InputEventMouseMotion.new()
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
	for i in 20:
		d.preview_param(rev, "wet", 0.1 + 0.02 * i)
		await frames(tree, 2)
	var s1: Array = e.get_fx_swaps()
	print("SWAPS knob drag: kept %d, fresh %d" % [int(s1[0]) - int(s0[0]), int(s1[1]) - int(s0[1])])
	check(int(s1[0]) - int(s0[0]) >= 5 and int(s1[1]) == int(s0[1]), "playing: a knob drag keeps effect state across plan swaps (kept %d, fresh %d)" % [int(s1[0]) - int(s0[0]), int(s1[1]) - int(s0[1])])
	d.add_effect(small.clips[0].chain, "Chorus")
	await frames(tree, 6)
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
	AWProjectIO.migrations = {}
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
		check(info.get("version") == "0.8.2" and info.get("api") == "4.7" and info.get("godot_cpp") == "10.0.0-stable", "build info: %s" % str(info))
		check(chip != null and chip.text.contains("Engine 0.8.2"), "toolbar says '%s'" % (chip.text if chip else "?"))
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
	check(is_equal_approx(d.view_to_project(0.0), p.clips[0].start_sec), "clip-time view maps 0 to clip start")

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
	var g := screen.curves.graph
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
	var dots: AWCurveDots = g.get_parent().get_child(0)
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
	check(absf(d.project_to_view(c4.end_sec()) - L) < 1e-3, "Clip Time: curve playhead reaches the last key exactly when the clip ends")
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
	var axis: AWCurveAxis = g.get_parent().get_child(2)
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
	check(fk != null and fk.binding.scale == AWCurve.Scale.LOG and panel.knobs.size() == 7, "seven knobs; Freq is logarithmic")
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
	ak._entry.text_submitted.emit("-2500")
	check(is_equal_approx(lf.freq_accel, -2.5) and ak.binding.text() == "-2500 mHz/s", "typing -2500 sets -2.5 Hz/s, shown as %s" % ak.binding.text())
	var fine_a := ak.binding.from_norm(0.5 + 1.0 / 220.0)
	var wide_a := ak.binding.from_norm(0.75)
	check(absf(fine_a) <= 0.001 and absf(wide_a) > 0.5 and absf(ak.binding.to_norm(ak.binding.from_norm(0.8)) - 0.8) < 0.01, "Accel knob is fine near 0 and wide at the ends (1 px = %.3f Hz/s, 75%% = %.2f Hz/s)" % [fine_a, wide_a])
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

	var shape_btns: Array = panel.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.button_group != null)
	check(shape_btns.size() == 5, "five shape buttons")
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
	await editor_resource_tests(tree, screen)
	print("SELFTEST DONE fails=%d" % fails)
