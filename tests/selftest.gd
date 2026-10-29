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
	var ramp_clip: AWClip = AWProject.create_default().clips[3]
	ramp_clip.source_path = dc
	ramp_clip.start_sec = 0.0
	ramp_clip.fade_in_sec = 0.0
	ramp_clip.fade_out_sec = 0.0
	ramp_clip.source_offset_sec = 0.0
	ramp_clip.length_sec = minf(ramp_clip.length_sec, 3.0)
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
	var demo := AWProject.create_default()
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
		check(info.get("version") == "0.4.1" and info.get("api") == "4.7" and info.get("godot_cpp") == "10.0.0-stable", "build info: %s" % str(info))
		check(chip != null and chip.text.contains("Engine 0.4.1"), "toolbar says '%s'" % (chip.text if chip else "?"))
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
	var on_line := Vector2(g.local_to_x(1.5), g.val_to_y(chorus, ch.sample_norm(chorus, 1.5)))
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
	var lim_card: AWEffectCard = cards[1]
	var row: AWParamRow = lim_card.rows[0]
	check(row.curve() == null and row._slider.visible, "uncurved param shows slider + field")
	var lim: AWEffect = row.effect
	row._on_menu(1)
	await frames(tree, 4)
	check(ch.get_curve(lim.id, "pre_gain_db") != null, "right-click > Make Curve creates curve")
	cards = screen.chain_panel._cards
	var row2: AWParamRow = (cards[1] as AWEffectCard).rows[0]
	check(not row2._slider.visible and row2._curve_value.visible, "curved param shows curve value instead")
	d.undo()
	await frames(tree, 4)
	var row3: AWParamRow = (screen.chain_panel._cards[1] as AWEffectCard).rows[0]
	row3._slider.drag_started.emit()
	row3._slider.value = -6.0
	row3._slider.drag_ended.emit(true)
	check(is_equal_approx(ch.effects[1].get_param("pre_gain_db"), -6.0), "slider drag sets value")
	d.undo()
	check(is_equal_approx(ch.effects[1].get_param("pre_gain_db"), 0.0), "slider drag is one undo step")

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
	d.remove_curve(ch, lpc)
	await frames(tree, 4)
	var lp_card: AWEffectCard = screen.chain_panel._cards.back()
	check(lp_card.effect == lp and lp_card.rows[0]._slider.exp_edit, "cutoff slider is logarithmic")
	d.undo(); d.undo(); d.undo(); d.undo()
	check(not ch.effects.has(lp), "undo back to before Low Pass")
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
	var panel := screen.curves.lfo_panel
	check(panel.visible and d.lfo_curve == wet2 and d.active_curve == wet2, "right-click > Edit LFO opens the panel")
	var fs := panel.find_child("freq_hz_slider", true, false) as HSlider
	var ff := panel.find_child("freq_hz_field", true, false) as SpinBox
	check(fs != null and ff != null and fs.exp_edit, "Freq has a log slider and a field")
	var f0 := lf.freq_hz
	fs.drag_started.emit()
	fs.value = 7.5
	fs.drag_ended.emit(true)
	check(is_equal_approx(lf.freq_hz, 7.5), "Freq slider drag sets 7.5 Hz")
	d.undo()
	check(is_equal_approx(lf.freq_hz, f0), "slider drag is one undo step")
	var mf := panel.find_child("max_value_field", true, false) as SpinBox
	mf.value = 0.95
	check(is_equal_approx(lf.max_value, 0.95), "Max field sets the value")
	await frames(tree, 2)
	check(is_equal_approx((panel.find_child("max_value_slider", true, false) as HSlider).value, 0.95), "slider follows the field")
	d.undo()
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
	check(len32 - 44 == 2 * (len16 - 44), "export: 32-bit float file is twice the size of 16-bit")
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
	check(not screen.curves.lfo_panel.visible, "close hides the panel (LFO stays)")
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
	while wet2.lfo != null and guard < 12:
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
	print("SELFTEST DONE fails=%d" % fails)
