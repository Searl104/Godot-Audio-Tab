#pragma once
// AWPreviewStream: an AudioStream that pulls its audio from an AWCore on the audio thread.
// Put it on an AudioStreamPlayer; it plays forever (silence while the core is stopped).

#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "aw_core.h"

namespace godot {

class AWPreviewStream : public AudioStream {
	GDCLASS(AWPreviewStream, AudioStream)

	Ref<AWCore> core;

protected:
	static void _bind_methods();

public:
	void set_core(const Ref<AWCore> &p_core);
	Ref<AWCore> get_core() const;

	virtual Ref<AudioStreamPlayback> _instantiate_playback() const override;
	virtual String _get_stream_name() const override;
	virtual double _get_length() const override;
	virtual bool _is_monophonic() const override;
};

class AWPreviewPlayback : public AudioStreamPlayback {
	GDCLASS(AWPreviewPlayback, AudioStreamPlayback)

	Ref<AWCore> core;
	bool active = false;

protected:
	static void _bind_methods() {}

public:
	void set_core(const Ref<AWCore> &p_core) { core = p_core; }

	virtual void _start(double p_from_pos) override { active = true; }
	virtual void _stop() override { active = false; }
	virtual bool _is_playing() const override { return active; }
	virtual int32_t _get_loop_count() const override { return 0; }
	virtual double _get_playback_position() const override { return 0.0; }
	virtual void _seek(double p_position) override {}
	virtual int32_t _mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) override;
};

} // namespace godot
