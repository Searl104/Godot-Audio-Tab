#pragma once
// AWCore: the native render core of the Audio Workstation.
//
// Milestone 1 (scaffold): proves the GDScript <-> C++ path. render() produces silence or a
// test tone. Later milestones add the render plan, clip voices, effects and tails; the
// GDScript side (AWEngine) only ever talks to this class.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class AWCore : public RefCounted {
	GDCLASS(AWCore, RefCounted)

	double sample_rate = 48000.0;
	double tone_hz = 0.0; // <= 0: silence
	double tone_gain = 0.0; // linear
	double phase = 0.0; // 0..1
	int64_t frames_rendered = 0;

protected:
	static void _bind_methods();

public:
	String get_version() const;
	Dictionary get_build_info() const;

	void set_sample_rate(double p_rate);
	double get_sample_rate() const;

	// Test signal used to verify the audio path. hz <= 0 turns it off (silence).
	void set_test_tone(double p_hz, double p_gain_db);

	// Renders the next `frames` stereo frames.
	PackedVector2Array render(int64_t p_frames);
	int64_t get_frames_rendered() const;
	void reset();
};

} // namespace godot
