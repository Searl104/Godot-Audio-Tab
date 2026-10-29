#pragma once
// Effect DSP for the Audio Workstation chains. Plain C++ (no Godot types) so it can be used
// from the audio thread and offline renders alike.
//
// Every effect reads its parameters from tables (see AWParam) at control rate, so curves and
// LFOs automate it, and keeps its own filter state. A chain is run on interleaved stereo.

#include <cstdint>
#include <memory>
#include <vector>

namespace aw {

enum EffectType {
	FX_NONE = 0,
	FX_LOW_PASS = 1,
	FX_HIGH_PASS = 2,
	FX_BAND_PASS = 3,
	FX_EQ6 = 4,
	FX_AMPLIFY = 5,
};

// One automated parameter: entry i is the value at position i * step (frames); one entry
// means constant. Positions past the end hold the last value.
struct Param {
	std::vector<float> table{ 0.0f };
	int64_t step = 64;
	float at(double p_pos) const;
};

// What an effect card asks for. Parameter order is fixed per type (see aw_effects.cpp).
struct EffectSpec {
	int type = FX_NONE;
	std::vector<Param> params;
};

class Effect {
public:
	virtual ~Effect() = default;
	// Processes `frames` interleaved stereo frames in place. `pos0` is the position of the
	// first frame on the parameter tables' time base.
	virtual void process(float *p_io, int64_t p_frames, int64_t p_pos0) = 0;
	// Clears filter memory and tails (after a seek or a loop wrap). Never allocates.
	virtual void reset() = 0;
};

// Returns null for an unknown type. The spec must outlive the effect.
std::unique_ptr<Effect> make_effect(const EffectSpec &p_spec, double p_sample_rate);

// Filter helpers, exposed for the tests.
float resonance_to_q(float p_resonance);

} // namespace aw
