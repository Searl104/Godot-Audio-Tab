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

// Waveshaper: tanh(k x) / k. Low levels pass at unity gain, loud peaks are squashed to 1/k.
inline float shape(float x, float k) {
	return std::tanh(k * x) / k;
}

// Params: drive 0..1, pre_gain dB, post_gain dB, keep_hf_hz. Gains and drive ramp per control
// block. Frequencies above keep_hf_hz (a one-pole split) bypass the shaper.
class DistortionFx : public Effect {
	const EffectSpec &spec;
	double sr;
	float pre = -1, post = -1, k = -1;
	float lp[2] = { 0, 0 };

public:
	DistortionFx(const EffectSpec &p_spec, double p_sr) :
			spec(p_spec), sr(p_sr) {}
	void reset() override {
		pre = post = k = -1.0f;
		lp[0] = lp[1] = 0.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float drive = std::min(std::max(spec.params[0].at(pos), 0.0f), 1.0f);
			const float t_pre = db_to_lin(spec.params[1].at(pos));
			const float t_post = db_to_lin(spec.params[2].at(pos));
			const float t_k = 1.0f + 19.0f * drive;
			const float hf = spec.params[3].at(pos);
			const bool split = hf < (float)(sr * 0.45);
			const float a = split ? std::exp(-(float)(TWO_PI * std::max(hf, 1.0f) / sr)) : 0.0f;
			if (pre < 0.0f) {
				pre = t_pre;
				post = t_post;
				k = t_k;
			}
			const float d_pre = (t_pre - pre) / (float)n;
			const float d_post = (t_post - post) / (float)n;
			const float d_k = (t_k - k) / (float)n;
			for (int64_t i = 0; i < n; i++) {
				pre += d_pre;
				post += d_post;
				k += d_k;
				for (int c = 0; c < 2; c++) {
					float &x = io[(b + i) * 2 + c];
					float low = x;
					float high = 0.0f;
					if (split) {
						lp[c] = flush(a * lp[c] + (1.0f - a) * x);
						low = lp[c];
						high = x - low;
					}
					x = (shape(low * pre, k) + high) * post;
				}
			}
		}
	}
};

// Params: tap1_delay_ms, tap1_level_db, feedback_level_db, dry (0..1). One tap fed back into
// itself; the delay time glides across each control block (a moving time bends the pitch).
class DelayFx : public Effect {
	const EffectSpec &spec;
	double sr;
	std::vector<float> buf; // interleaved stereo ring
	int64_t size = 0;
	int64_t w = 0;
	float cur_delay = -1.0f; // frames

public:
	DelayFx(const EffectSpec &p_spec, double p_sr) :
			spec(p_spec), sr(p_sr) {
		size = (int64_t)(sr * 1.6) + 8;
		buf.assign((size_t)size * 2, 0.0f);
	}
	void reset() override {
		std::fill(buf.begin(), buf.end(), 0.0f);
		w = 0;
		cur_delay = -1.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float ms = std::min(std::max(spec.params[0].at(pos), 0.0f), 1500.0f);
			const float t_delay = std::max(1.0f, ms * 0.001f * (float)sr);
			const float level = db_to_lin(spec.params[1].at(pos));
			const float fb = std::min(db_to_lin(spec.params[2].at(pos)), 0.995f);
			const float dry = spec.params[3].at(pos);
			if (cur_delay < 0.0f) {
				cur_delay = t_delay;
			}
			const float d_delay = (t_delay - cur_delay) / (float)n;
			for (int64_t i = 0; i < n; i++) {
				cur_delay += d_delay;
				double rp = (double)w - (double)cur_delay;
				while (rp < 0.0) {
					rp += (double)size;
				}
				const int64_t i0 = (int64_t)rp;
				const float fr = (float)(rp - (double)i0);
				const int64_t i1 = (i0 + 1) % size;
				for (int c = 0; c < 2; c++) {
					const float tap = buf[(size_t)(i0 % size) * 2 + c] * (1.0f - fr) + buf[(size_t)i1 * 2 + c] * fr;
					float &x = io[(b + i) * 2 + c];
					buf[(size_t)w * 2 + c] = flush(x + tap * fb);
					x = x * dry + tap * level;
				}
				w = (w + 1) % size;
			}
		}
	}
};

// Params: threshold dB, ratio, gain (makeup) dB, attack us, release ms, mix 0..1.
// Feed-forward, stereo-linked peak detector; the gain reduction is smoothed in dB.
class CompressorFx : public Effect {
	const EffectSpec &spec;
	double sr;
	float gr = 0.0f; // dB of reduction currently applied

public:
	CompressorFx(const EffectSpec &p_spec, double p_sr) :
			spec(p_spec), sr(p_sr) {}
	void reset() override {
		gr = 0.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float thr = spec.params[0].at(pos);
			const float ratio = std::max(spec.params[1].at(pos), 1.0f);
			const float makeup = db_to_lin(spec.params[2].at(pos));
			const float att = std::exp(-1.0f / (std::max(spec.params[3].at(pos), 1.0f) * 1e-6f * (float)sr));
			const float rel = std::exp(-1.0f / (std::max(spec.params[4].at(pos), 1.0f) * 1e-3f * (float)sr));
			const float mix = std::min(std::max(spec.params[5].at(pos), 0.0f), 1.0f);
			const float slope = 1.0f - 1.0f / ratio;
			for (int64_t i = 0; i < n; i++) {
				float &l = io[(b + i) * 2];
				float &r = io[(b + i) * 2 + 1];
				const float peak = std::max(std::fabs(l), std::fabs(r));
				const float lvl = 20.0f * std::log10(std::max(peak, 1e-6f));
				const float target = std::max(lvl - thr, 0.0f) * slope;
				const float c = target > gr ? att : rel;
				gr = flush(target + c * (gr - target));
				const float g = db_to_lin(-gr) * makeup;
				l = l * (1.0f - mix) + l * g * mix;
				r = r * (1.0f - mix) + r * g * mix;
			}
		}
	}
};

// Params: pre_gain dB, ceiling dB, release s. Instant attack, so nothing passes the ceiling.
class LimiterFx : public Effect {
	const EffectSpec &spec;
	double sr;
	float g = 1.0f;

public:
	LimiterFx(const EffectSpec &p_spec, double p_sr) :
			spec(p_spec), sr(p_sr) {}
	void reset() override {
		g = 1.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float pre = db_to_lin(spec.params[0].at(pos));
			const float ceil = db_to_lin(std::min(spec.params[1].at(pos), 0.0f));
			const float rc = 1.0f - std::exp(-1.0f / (std::max(spec.params[2].at(pos), 0.001f) * (float)sr));
			for (int64_t i = 0; i < n; i++) {
				float &l = io[(b + i) * 2];
				float &r = io[(b + i) * 2 + 1];
				l *= pre;
				r *= pre;
				const float peak = std::max(std::fabs(l), std::fabs(r));
				const float need = peak > ceil ? ceil / peak : 1.0f;
				g = std::min(need, g + (1.0f - g) * rc);
				l *= g;
				r *= g;
			}
		}
	}
};

} // namespace

float distort_shape(float p_x, float p_k) {
	return shape(p_x, p_k);
}

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
		case FX_DISTORTION:
			return 4;
		case FX_DELAY:
			return 4;
		case FX_COMPRESSOR:
			return 6;
		case FX_LIMITER:
			return 3;
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
		case FX_DISTORTION:
			return std::make_unique<DistortionFx>(p_spec, p_sr);
		case FX_DELAY:
			return std::make_unique<DelayFx>(p_spec, p_sr);
		case FX_COMPRESSOR:
			return std::make_unique<CompressorFx>(p_spec, p_sr);
		case FX_LIMITER:
			return std::make_unique<LimiterFx>(p_spec, p_sr);
	}
	return nullptr;
}

} // namespace aw
