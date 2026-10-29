#include "aw_effects.h"

#include <algorithm>
#include <cmath>

namespace aw {

float Param::at(double p_pos) const {
	if (table.size() == 1 || p_pos <= 0.0) {
		return table[0];
	}
	const double x = p_pos / (double)step;
	const size_t last = table.size() - 1;
	if (x >= (double)last) {
		return table[last];
	}
	const size_t i = (size_t)x;
	const float f = (float)(x - (double)i);
	return table[i] + (table[i + 1] - table[i]) * f;
}

namespace {

constexpr int64_t CONTROL_BLOCK = 32; // frames between parameter updates
constexpr double TWO_PI = 6.283185307179586;

inline float flush(float v) {
	return std::fabs(v) < 1e-20f ? 0.0f : v;
}

inline float db_to_lin(float db) {
	return std::pow(10.0f, db * 0.05f);
}

// Direct form II transposed, one state pair per channel.
struct Biquad {
	float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
	float z1[2] = { 0, 0 };
	float z2[2] = { 0, 0 };
	bool identity = true;

	void set(double B0, double B1, double B2, double A0, double A1, double A2) {
		b0 = (float)(B0 / A0);
		b1 = (float)(B1 / A0);
		b2 = (float)(B2 / A0);
		a1 = (float)(A1 / A0);
		a2 = (float)(A2 / A0);
		identity = false;
	}
	void set_identity() {
		identity = true;
	}
	void clear() {
		z1[0] = z1[1] = z2[0] = z2[1] = 0.0f;
	}
	inline float tick(float x, int ch) {
		const float y = b0 * x + z1[ch];
		z1[ch] = flush(b1 * x - a1 * y + z2[ch]);
		z2[ch] = flush(b2 * x - a2 * y);
		return y;
	}
	void run(float *io, int64_t frames) {
		if (identity) {
			return;
		}
		for (int64_t i = 0; i < frames; i++) {
			io[i * 2] = tick(io[i * 2], 0);
			io[i * 2 + 1] = tick(io[i * 2 + 1], 1);
		}
	}
};

double clamp_hz(double hz, double sr) {
	return std::min(std::max(hz, 10.0), sr * 0.45);
}

// Params: cutoff_hz, resonance.
class FilterFx : public Effect {
	const EffectSpec &spec;
	double sr;
	int mode;
	Biquad bq;
	float last_fc = -1.0f, last_res = -1.0f;

public:
	FilterFx(const EffectSpec &p_spec, double p_sr, int p_mode) :
			spec(p_spec), sr(p_sr), mode(p_mode) {}
	void reset() override {
		bq.clear();
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t k = 0; k < frames; k += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - k);
			const float fc = spec.params[0].at((double)(pos0 + k));
			const float res = spec.params[1].at((double)(pos0 + k));
			if (fc != last_fc || res != last_res) {
				last_fc = fc;
				last_res = res;
				const double w0 = TWO_PI * clamp_hz(fc, sr) / sr;
				const double cw = std::cos(w0), sw = std::sin(w0);
				const double alpha = sw / (2.0 * resonance_to_q(res));
				switch (mode) {
					case FX_LOW_PASS:
						bq.set((1 - cw) * 0.5, 1 - cw, (1 - cw) * 0.5, 1 + alpha, -2 * cw, 1 - alpha);
						break;
					case FX_HIGH_PASS:
						bq.set((1 + cw) * 0.5, -(1 + cw), (1 + cw) * 0.5, 1 + alpha, -2 * cw, 1 - alpha);
						break;
					default: // band pass, 0 dB at the centre
						bq.set(alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha);
						break;
				}
			}
			bq.run(io + k * 2, n);
		}
	}
};

// Params: six band gains in dB (32, 100, 320, 1k, 3.2k, 10k Hz).
class Eq6Fx : public Effect {
	static constexpr int BANDS = 6;
	static constexpr double FREQ[BANDS] = { 32.0, 100.0, 320.0, 1000.0, 3200.0, 10000.0 };
	static constexpr double Q = 1.0;
	const EffectSpec &spec;
	double sr;
	Biquad bq[BANDS];
	float last[BANDS] = { 1e9f, 1e9f, 1e9f, 1e9f, 1e9f, 1e9f };

public:
	Eq6Fx(const EffectSpec &p_spec, double p_sr) :
			spec(p_spec), sr(p_sr) {}
	void reset() override {
		for (Biquad &b : bq) {
			b.clear();
		}
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t k = 0; k < frames; k += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - k);
			for (int b = 0; b < BANDS; b++) {
				const float db = spec.params[(size_t)b].at((double)(pos0 + k));
				if (db != last[b]) {
					last[b] = db;
					if (std::fabs(db) < 0.01f || FREQ[b] >= sr * 0.45) {
						bq[b].set_identity();
					} else {
						const double A = std::pow(10.0, (double)db / 40.0);
						const double w0 = TWO_PI * FREQ[b] / sr;
						const double cw = std::cos(w0);
						const double alpha = std::sin(w0) / (2.0 * Q);
						bq[b].set(1 + alpha * A, -2 * cw, 1 - alpha * A, 1 + alpha / A, -2 * cw, 1 - alpha / A);
					}
				}
				bq[b].run(io + k * 2, n);
			}
		}
	}
};

// Params: volume_db. The gain ramps across each control block, so automation doesn't zipper.
class AmplifyFx : public Effect {
	const EffectSpec &spec;
	float gain = -1.0f;

public:
	explicit AmplifyFx(const EffectSpec &p_spec) :
			spec(p_spec) {}
	void reset() override {
		gain = -1.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t k = 0; k < frames; k += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - k);
			const float target = db_to_lin(spec.params[0].at((double)(pos0 + k)));
			if (gain < 0.0f) {
				gain = target;
			}
			const float step = (target - gain) / (float)n;
			float g = gain;
			for (int64_t i = 0; i < n; i++) {
				g += step;
				io[(k + i) * 2] *= g;
				io[(k + i) * 2 + 1] *= g;
			}
			gain = target;
		}
	}
};

} // namespace

// 0 -> 0.35 (gentle), 0.5 -> 0.707 (flat, Butterworth), 1 -> about 14 (ringing).
float resonance_to_q(float p_res) {
	const float r = std::min(std::max(p_res, 0.0f), 1.0f);
	if (r <= 0.5f) {
		return 0.35f + (r / 0.5f) * (0.707f - 0.35f);
	}
	return 0.707f * std::pow(20.0f, (r - 0.5f) / 0.5f);
}

static size_t param_count(int type) {
	switch (type) {
		case FX_LOW_PASS:
		case FX_HIGH_PASS:
		case FX_BAND_PASS:
			return 2;
		case FX_EQ6:
			return 6;
		case FX_AMPLIFY:
			return 1;
	}
	return 0;
}

std::unique_ptr<Effect> make_effect(const EffectSpec &p_spec, double p_sr) {
	if (p_spec.params.size() < param_count(p_spec.type)) {
		return nullptr;
	}
	switch (p_spec.type) {
		case FX_LOW_PASS:
		case FX_HIGH_PASS:
		case FX_BAND_PASS:
			return std::make_unique<FilterFx>(p_spec, p_sr, p_spec.type);
		case FX_EQ6:
			return std::make_unique<Eq6Fx>(p_spec, p_sr);
		case FX_AMPLIFY:
			return std::make_unique<AmplifyFx>(p_spec);
	}
	return nullptr;
}

} // namespace aw
