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

#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
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
		float gain = 1.0f;
		float pan = 0.0f; // -1 left .. +1 right (balance)
		// Playback rate table over clip time: rates[i] is the rate at clip time i * step.
		// One entry means constant rate. cum[i] = elapsed project frames at clip time i * step.
		std::vector<float> rates;
		int64_t step = 64;
		std::vector<double> cum;
		double play_frames = 0.0; // length on the timeline (length warped to project time)

		void prepare();
		double warp(double s) const; // clip time -> elapsed project frames
		double unwarp(double p) const; // elapsed project frames -> clip time
	};

	struct Plan {
		std::vector<Voice> voices;
		int64_t end_frame = 0;
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

	std::atomic<bool> playing{ false };
	std::atomic<int64_t> position{ 0 };
	std::atomic<bool> loop_enabled{ false };
	std::atomic<int64_t> loop_start{ 0 };
	std::atomic<int64_t> loop_end{ 0 };

	std::shared_ptr<const Plan> current_plan();
	static void render_voices(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_interleaved);
	void mix_transport(float *r_interleaved, int64_t p_frames);

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

	// --- Plan --------------------------------------------------------------------
	// Array of Dictionaries: source, start_frame, offset, length, fade_in, fade_out, gain,
	// pan, rates (PackedFloat32Array), rate_step. Frames are at the core's sample rate.
	// Returns the plan's last frame (content end).
	int64_t set_plan(const Array &p_voices);
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
