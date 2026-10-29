#pragma once
// AWCore: the native render core of the Audio Workstation.
//
// Milestone 1: proved the GDScript <-> C++ path (version, build info, test tone).
// Milestone 2: dry playback. Decoded sources are stored here, a "plan" describes the clip
// voices (start, offset, length, fades, gain, pan, rate table), and mix() renders them.
// The same mixer feeds the live preview (AWPreviewStream, audio thread) and offline
// rendering (render_range, used by tests and later by baking).
//
// Threading: the main thread calls set_plan / play / stop / seek / set_loop / add_source.
// The audio thread only calls mix(). The plan is an immutable object swapped under a mutex
// that is held just long enough to copy a pointer. Transport state is atomic.

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

#include "aw_effects.h"

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class AWCore : public RefCounted {
	GDCLASS(AWCore, RefCounted)

public:
	struct Source {
		std::vector<float> data; // interleaved stereo
		int64_t frames = 0;
	};

	// One clip on the timeline. All times are in frames at the core's sample rate.
	struct Voice {
		std::shared_ptr<const Source> source;
		int64_t start = 0; // project frame where the clip begins
		double offset = 0.0; // where in the source the clip's audio time 0 lies
		double length = 0.0; // clip (audio) time covered by the clip
		double fade_in = 0.0; // clip time
		double fade_out = 0.0;
		// Gain (linear) and pan (-1 left .. +1 right, balance) over clip time, same layout as
		// `rates`: entry i is the value at clip time i * step; one entry means constant.
		std::vector<float> gains;
		std::vector<float> pans;
		// Playback rate table over clip time: rates[i] is the rate at clip time i * step.
		// One entry means constant rate. cum[i] = elapsed project frames at clip time i * step.
		std::vector<float> rates;
		int64_t step = 64;
		std::vector<double> cum;
		double play_frames = 0.0; // length on the timeline (length warped to project time)
		// Effect chain after Gain/Pan (bypassed cards are left out). Parameter tables are over
		// elapsed project frames since the clip started. The chain keeps ringing for `tail_frames`
		// after the clip ends.
		std::vector<aw::EffectSpec> effects;
		int64_t tail_frames = 0;

		void prepare();
		double warp(double s) const; // clip time -> elapsed project frames
		double unwarp(double p) const; // elapsed project frames -> clip time
	};

	struct Plan {
		std::vector<Voice> voices;
		int64_t end_frame = 0;
		// Master (Output) volume over project time: entry i is the linear gain at frame
		// i * master_step; one entry means constant.
		std::vector<float> master;
		int64_t master_step = 64;
		// Master effect chain after the Output volume; tables over project frames.
		std::vector<aw::EffectSpec> master_effects;
		int64_t master_tail = 0;
	};

	// Effect objects and their memory for one plan. Owned by whoever renders (the audio thread
	// for the transport, a local for offline renders), never shared.
	struct FxRuntime {
		std::shared_ptr<const Plan> plan;
		std::vector<std::vector<std::unique_ptr<aw::Effect>>> voice;
		std::vector<std::unique_ptr<aw::Effect>> master;
		std::vector<float> scratch;
		int64_t next = -1; // the frame the next block should start at, or -1
		void bind(const std::shared_ptr<const Plan> &p_plan, double p_rate);
		void reset();
	};

private:
	double sample_rate = 48000.0;
	double tone_hz = 0.0; // <= 0: silence
	double tone_gain = 0.0; // linear
	double phase = 0.0; // 0..1
	int64_t frames_rendered = 0;

	std::vector<std::shared_ptr<Source>> sources; // index = source id
	std::mutex plan_mutex;
	std::shared_ptr<const Plan> plan;
	std::vector<std::shared_ptr<const Plan>> retired; // freed on the main thread only

	FxRuntime fx; // audio thread only
	std::atomic<bool> playing{ false };
	std::atomic<int64_t> position{ 0 };
	std::atomic<bool> loop_enabled{ false };
	std::atomic<int64_t> loop_start{ 0 };
	std::atomic<int64_t> loop_end{ 0 };

	std::shared_ptr<const Plan> current_plan();
	static void render_voice_dry(const Voice &p_voice, int64_t p_from, int64_t p_j0, int64_t p_j1, float *r_out, int64_t p_origin);
	static void render_voices(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_interleaved, FxRuntime *p_fx);
	static void apply_master_gain(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_interleaved);
	static void apply_master(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_interleaved, FxRuntime *p_fx);
	void mix_transport(float *r_interleaved, int64_t p_frames);
	PackedFloat32Array sample_curve_impl(const Ref<Animation> &p_anim, const Dictionary &p_spec, const double *p_times, double p_start, double p_step, int64_t p_count, int64_t p_unit) const;

protected:
	static void _bind_methods();

public:
	String get_version() const;
	Dictionary get_build_info() const;

	void set_sample_rate(double p_rate);
	double get_sample_rate() const;

	// Test signal used to verify the audio path. hz <= 0 turns it off (silence).
	void set_test_tone(double p_hz, double p_gain_db);

	// --- Sources -----------------------------------------------------------------
	// Stores decoded stereo audio (already at the core's sample rate). Returns the source id.
	int64_t add_source(const PackedVector2Array &p_frames);
	int64_t get_source_frames(int64_t p_id) const;
	// Peak amplitude (0..1) per bucket, `per_second` buckets per second of source audio.
	PackedFloat32Array get_peaks(int64_t p_id, double p_per_second) const;
	void clear_sources();

	// --- Curve sampling ----------------------------------------------------------
	// Evaluates an automation curve at start + i * step for i in [0, count): the drawn Bezier
	// track plus its optional LFO, converted exactly like AWChain.sample_norm()/sample().
	// spec: track (index in the Animation, -1 = none), scale (AWCurve.Scale), lo/hi (parameter
	// range), static_norm (height used when the track has no keys), lfo (Dictionary with
	// shape, min, max, freq, fade_in, fade_out, start, end, seed; empty = none).
	// unit: 0 parameter value, 1 curve height 0..1, 2 linear gain from dB (<= -59.9 dB is
	// silence), 3 playback rate from semitones, 4 curve height without the LFO.
	PackedFloat32Array sample_curve(const Ref<Animation> &p_anim, const Dictionary &p_spec, double p_start, double p_step, int64_t p_count, int64_t p_unit) const;
	// Same, at arbitrary curve times (e.g. graph pixels when the view is in project time).
	PackedFloat32Array sample_curve_at(const Ref<Animation> &p_anim, const Dictionary &p_spec, const PackedFloat64Array &p_times, int64_t p_unit) const;

	// --- Plan --------------------------------------------------------------------
	// voices: Array of Dictionaries with source, start_frame, offset, length, fade_in,
	// fade_out, rates, gains, pans (PackedFloat32Array tables over clip time) and rate_step
	// (frames between table entries). Static "gain"/"pan" numbers are accepted in place of
	// the tables. master: optional Dictionary {"gains": PackedFloat32Array, "step": int}, the
	// Output volume over project time. Frames are at the core's sample rate.
	// Effects: a voice may carry "effects": Array of {type, params: Array of PackedFloat32Array
	// tables, step} and "tail_frames"; master takes the same as "effects" / "tail_frames".
	// Types: 1 low pass, 2 high pass, 3 band pass, 4 EQ6, 5 amplify.
	// master["end_frame"], when given, sets the plan's last frame (the export marker).
	// Returns the plan's last frame (content end, tails included).
	int64_t set_plan(const Array &p_voices, const Dictionary &p_master = Dictionary());
	// The effect type ids this build can run (see above).
	PackedInt32Array get_effect_types() const;
	// Bumped when the plugin needs new behaviour from the engine (older libraries show as out of date).
	int64_t get_api_level() const;
	int64_t get_plan_end() const;

	// --- Transport ---------------------------------------------------------------
	void play(int64_t p_from_frame);
	void stop();
	void seek(int64_t p_frame);
	void set_loop(bool p_enabled, int64_t p_start_frame, int64_t p_end_frame);
	bool is_playing() const;
	int64_t get_position() const;

	// Renders the next `frames` frames from the transport (silence when stopped) plus the
	// optional test tone.
	PackedVector2Array render(int64_t p_frames);
	// Stateless offline render of [from, from + frames) from the plan. Ignores the transport.
	PackedVector2Array render_range(int64_t p_from_frame, int64_t p_frames);
	int64_t get_frames_rendered() const;
	void reset();

	// Audio thread entry point (AWPreviewStream).
	int32_t mix(AudioFrame *p_buffer, int32_t p_frames);
};

} // namespace godot
