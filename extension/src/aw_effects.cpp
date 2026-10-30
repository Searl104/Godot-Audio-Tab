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
	const EffectSpec *spec;
	double sr;
	int mode;
	Biquad bq;
	float last_fc = -1.0f, last_res = -1.0f;

public:
	FilterFx(const EffectSpec &p_spec, double p_sr, int p_mode) :
			spec(&p_spec), sr(p_sr), mode(p_mode) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		bq.clear();
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t k = 0; k < frames; k += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - k);
			const float fc = spec->params[0].at((double)(pos0 + k));
			const float res = spec->params[1].at((double)(pos0 + k));
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
	const EffectSpec *spec;
	double sr;
	Biquad bq[BANDS];
	float last[BANDS] = { 1e9f, 1e9f, 1e9f, 1e9f, 1e9f, 1e9f };

public:
	Eq6Fx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		for (Biquad &b : bq) {
			b.clear();
		}
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t k = 0; k < frames; k += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - k);
			for (int b = 0; b < BANDS; b++) {
				const float db = spec->params[(size_t)b].at((double)(pos0 + k));
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
	const EffectSpec *spec;
	float gain = -1.0f;

public:
	explicit AmplifyFx(const EffectSpec &p_spec) :
			spec(&p_spec) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		gain = -1.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t k = 0; k < frames; k += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - k);
			const float target = db_to_lin(spec->params[0].at((double)(pos0 + k)));
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
	const EffectSpec *spec;
	double sr;
	float pre = -1, post = -1, k = -1;
	float lp[2] = { 0, 0 };

public:
	DistortionFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		pre = post = k = -1.0f;
		lp[0] = lp[1] = 0.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float drive = std::min(std::max(spec->params[0].at(pos), 0.0f), 1.0f);
			const float t_pre = db_to_lin(spec->params[1].at(pos));
			const float t_post = db_to_lin(spec->params[2].at(pos));
			const float t_k = 1.0f + 19.0f * drive;
			const float hf = spec->params[3].at(pos);
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
	const EffectSpec *spec;
	double sr;
	std::vector<float> buf; // interleaved stereo ring
	int64_t size = 0;
	int64_t w = 0;
	float cur_delay = -1.0f; // frames

public:
	DelayFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {
		size = (int64_t)(sr * 1.6) + 8;
		buf.assign((size_t)size * 2, 0.0f);
	}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		std::fill(buf.begin(), buf.end(), 0.0f);
		w = 0;
		cur_delay = -1.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float ms = std::min(std::max(spec->params[0].at(pos), 0.0f), 1500.0f);
			const float t_delay = std::max(1.0f, ms * 0.001f * (float)sr);
			const float level = db_to_lin(spec->params[1].at(pos));
			const float fb = std::min(db_to_lin(spec->params[2].at(pos)), 0.995f);
			const float dry = spec->params[3].at(pos);
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
	const EffectSpec *spec;
	double sr;
	float gr = 0.0f; // dB of reduction currently applied

public:
	CompressorFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		gr = 0.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float thr = spec->params[0].at(pos);
			const float ratio = std::max(spec->params[1].at(pos), 1.0f);
			const float makeup = db_to_lin(spec->params[2].at(pos));
			const float att = std::exp(-1.0f / (std::max(spec->params[3].at(pos), 1.0f) * 1e-6f * (float)sr));
			const float rel = std::exp(-1.0f / (std::max(spec->params[4].at(pos), 1.0f) * 1e-3f * (float)sr));
			const float mix = std::min(std::max(spec->params[5].at(pos), 0.0f), 1.0f);
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
	const EffectSpec *spec;
	double sr;
	float g = 1.0f;

public:
	LimiterFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		g = 1.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float pre = db_to_lin(spec->params[0].at(pos));
			const float ceil = db_to_lin(std::min(spec->params[1].at(pos), 0.0f));
			const float rc = 1.0f - std::exp(-1.0f / (std::max(spec->params[2].at(pos), 0.001f) * (float)sr));
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


// ---- Reverb (Freeverb layout) ----------------------------------------------------------
// Params: room_size, damping, spread, wet, dry (all 0..1).
// Eight damped feedback combs in parallel, then four allpasses in series, per channel; the right
// channel's delays are offset so the two sides decorrelate. `spread` blends the two wet sides.
class ReverbFx : public Effect {
	static constexpr int NCOMB = 8;
	static constexpr int NAP = 4;
	const EffectSpec *spec;
	struct Comb {
		std::vector<float> buf;
		size_t i = 0;
		float store = 0.0f;
	};
	struct Allpass {
		std::vector<float> buf;
		size_t i = 0;
	};
	Comb comb[2][NCOMB];
	Allpass ap[2][NAP];

public:
	ReverbFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec) {
		static const int comb_t[NCOMB] = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
		static const int ap_t[NAP] = { 556, 441, 341, 225 };
		const double k = p_sr / 44100.0;
		for (int c = 0; c < 2; c++) {
			const int off = c * 23;
			for (int j = 0; j < NCOMB; j++) {
				comb[c][j].buf.assign((size_t)std::max(8.0, (comb_t[j] + off) * k), 0.0f);
			}
			for (int j = 0; j < NAP; j++) {
				ap[c][j].buf.assign((size_t)std::max(8.0, (ap_t[j] + off) * k), 0.0f);
			}
		}
	}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		for (int c = 0; c < 2; c++) {
			for (int j = 0; j < NCOMB; j++) {
				std::fill(comb[c][j].buf.begin(), comb[c][j].buf.end(), 0.0f);
				comb[c][j].i = 0;
				comb[c][j].store = 0.0f;
			}
			for (int j = 0; j < NAP; j++) {
				std::fill(ap[c][j].buf.begin(), ap[c][j].buf.end(), 0.0f);
				ap[c][j].i = 0;
			}
		}
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float room = std::min(std::max(spec->params[0].at(pos), 0.0f), 1.0f);
			const float damp = std::min(std::max(spec->params[1].at(pos), 0.0f), 1.0f) * 0.4f;
			const float spread = std::min(std::max(spec->params[2].at(pos), 0.0f), 1.0f);
			const float wet = std::min(std::max(spec->params[3].at(pos), 0.0f), 1.0f);
			const float dry = std::min(std::max(spec->params[4].at(pos), 0.0f), 1.0f);
			const float fb = room * 0.28f + 0.7f;
			const float w1 = wet * 3.0f * (spread * 0.5f + 0.5f);
			const float w2 = wet * 3.0f * (1.0f - spread) * 0.5f;
			for (int64_t i = 0; i < n; i++) {
				float *f = io + (b + i) * 2;
				const float in = (f[0] + f[1]) * 0.015f;
				float out[2];
				for (int c = 0; c < 2; c++) {
					float acc = 0.0f;
					for (int j = 0; j < NCOMB; j++) {
						Comb &cb = comb[c][j];
						const float y = cb.buf[cb.i];
						cb.store = flush(y * (1.0f - damp) + cb.store * damp);
						cb.buf[cb.i] = flush(in + cb.store * fb);
						if (++cb.i >= cb.buf.size()) {
							cb.i = 0;
						}
						acc += y;
					}
					for (int j = 0; j < NAP; j++) {
						Allpass &a = ap[c][j];
						const float bo = a.buf[a.i];
						a.buf[a.i] = flush(acc + bo * 0.5f);
						acc = bo - acc;
						if (++a.i >= a.buf.size()) {
							a.i = 0;
						}
					}
					out[c] = acc;
				}
				f[0] = f[0] * dry + out[0] * w1 + out[1] * w2;
				f[1] = f[1] * dry + out[1] * w1 + out[0] * w2;
			}
		}
	}
};

// ---- Chorus -----------------------------------------------------------------------------
// Params: rate_hz, depth_ms, wet, dry. Three modulated delay voices (12, 15, 18 ms centres) with
// spread phases, panned left / centre / right. Linear interpolation.
class ChorusFx : public Effect {
	const EffectSpec *spec;
	double sr;
	std::vector<float> buf;
	int64_t size = 0;
	int64_t w = 0;
	double phase = 0.0;

public:
	ChorusFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {
		size = (int64_t)(sr * 0.08) + 8;
		buf.assign((size_t)size * 2, 0.0f);
	}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		std::fill(buf.begin(), buf.end(), 0.0f);
		w = 0;
		phase = 0.0;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		static const float centre_ms[3] = { 12.0f, 15.0f, 18.0f };
		static const float gl[3] = { 1.0f, 0.707f, 0.35f };
		static const float gr[3] = { 0.35f, 0.707f, 1.0f };
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float rate = std::min(std::max(spec->params[0].at(pos), 0.01f), 20.0f);
			const float depth = std::min(std::max(spec->params[1].at(pos), 0.0f), 20.0f) * 0.001f * (float)sr;
			const float wet = spec->params[2].at(pos);
			const float dry = spec->params[3].at(pos);
			const double inc = (double)rate / sr;
			for (int64_t i = 0; i < n; i++) {
				float *f = io + (b + i) * 2;
				buf[(size_t)w * 2] = f[0];
				buf[(size_t)w * 2 + 1] = f[1];
				float oL = 0.0f, oR = 0.0f;
				for (int v = 0; v < 3; v++) {
					const double ph = phase + (double)v / 3.0;
					const float lfo = (float)std::sin(TWO_PI * (ph - std::floor(ph)));
					const float d = std::max(1.0f, centre_ms[v] * 0.001f * (float)sr + lfo * depth);
					double rp = (double)w - (double)d;
					while (rp < 0.0) {
						rp += (double)size;
					}
					const int64_t i0 = (int64_t)rp;
					const float fr = (float)(rp - (double)i0);
					const int64_t i1 = (i0 + 1) % size;
					const size_t a0 = (size_t)(i0 % size) * 2, a1 = (size_t)i1 * 2;
					const float tl = buf[a0] * (1.0f - fr) + buf[a1] * fr;
					const float tr = buf[a0 + 1] * (1.0f - fr) + buf[a1 + 1] * fr;
					oL += tl * gl[v];
					oR += tr * gr[v];
				}
				f[0] = f[0] * dry + oL * wet * 0.6f;
				f[1] = f[1] * dry + oR * wet * 0.6f;
				w = (w + 1) % size;
				phase += inc;
				if (phase >= 1.0) {
					phase -= 1.0;
				}
			}
		}
	}
};

// ---- Phaser -----------------------------------------------------------------------------
// Params: rate_hz, feedback, depth. Six first-order allpasses swept on a sine LFO around 840 Hz,
// +/- (0.93 * depth) octaves; the result is mixed 50/50 with the dry signal for deep notches.
class PhaserFx : public Effect {
	const EffectSpec *spec;
	double sr;
	double phase = 0.0;
	float z[2][6] = {};
	float last[2] = {};

public:
	PhaserFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		phase = 0.0;
		std::fill(&z[0][0], &z[0][0] + 12, 0.0f);
		last[0] = last[1] = 0.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float rate = std::min(std::max(spec->params[0].at(pos), 0.01f), 20.0f);
			const float fb = std::min(std::max(spec->params[1].at(pos), 0.0f), 0.95f);
			const float depth = std::min(std::max(spec->params[2].at(pos), 0.0f), 4.0f);
			const double inc = (double)rate / sr;
			for (int64_t i = 0; i < n; i++) {
				const float lfo = (float)std::sin(TWO_PI * phase);
				double fc = 840.0 * std::pow(2.0, (double)lfo * 0.93 * (double)depth);
				fc = std::min(std::max(fc, 40.0), sr * 0.45);
				const float t = (float)std::tan(3.141592653589793 * fc / sr);
				const float a = (t - 1.0f) / (t + 1.0f);
				for (int c = 0; c < 2; c++) {
					const float x = io[(b + i) * 2 + c];
					float y = x + last[c] * fb;
					for (int s = 0; s < 6; s++) {
						const float o = a * y + z[c][s];
						z[c][s] = flush(y - a * o);
						y = o;
					}
					last[c] = flush(y);
					io[(b + i) * 2 + c] = 0.5f * (x + y);
				}
				phase += inc;
				if (phase >= 1.0) {
					phase -= 1.0;
				}
			}
		}
	}
};

// ---- Stereo Enhance ---------------------------------------------------------------------
// Params: width (0..4), time_ms (0..50), surround (0..1).
// Mid/side: the side is scaled by `width` (1 = unchanged, 0 = mono). `time_ms` delays the side
// signal (a Haas-style spread). `surround` adds a 10 ms delayed, polarity-inverted cross-feed.
class StereoEnhanceFx : public Effect {
	const EffectSpec *spec;
	double sr;
	std::vector<float> side_buf; // side history
	std::vector<float> cross_buf; // cross-feed history (L and R interleaved)
	int64_t size = 0;
	int64_t w = 0;
	float cur_t = -1.0f;

public:
	StereoEnhanceFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {
		size = (int64_t)(sr * 0.06) + 8;
		side_buf.assign((size_t)size, 0.0f);
		cross_buf.assign((size_t)size * 2, 0.0f);
	}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		std::fill(side_buf.begin(), side_buf.end(), 0.0f);
		std::fill(cross_buf.begin(), cross_buf.end(), 0.0f);
		w = 0;
		cur_t = -1.0f;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		const int64_t cross_d = (int64_t)(sr * 0.010);
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float width = std::min(std::max(spec->params[0].at(pos), 0.0f), 4.0f);
			const float t = std::min(std::max(spec->params[1].at(pos), 0.0f), 50.0f) * 0.001f * (float)sr;
			const float sur = std::min(std::max(spec->params[2].at(pos), 0.0f), 1.0f);
			if (cur_t < 0.0f) {
				cur_t = t;
			}
			const float dt = (t - cur_t) / (float)n;
			for (int64_t i = 0; i < n; i++) {
				cur_t += dt;
				float *f = io + (b + i) * 2;
				const float m = (f[0] + f[1]) * 0.5f;
				const float s = (f[0] - f[1]) * 0.5f * width;
				side_buf[(size_t)w] = s;
				cross_buf[(size_t)w * 2] = f[0];
				cross_buf[(size_t)w * 2 + 1] = f[1];
				double rp = (double)w - (double)cur_t;
				while (rp < 0.0) {
					rp += (double)size;
				}
				const int64_t i0 = (int64_t)rp;
				const float fr = (float)(rp - (double)i0);
				const float sd = side_buf[(size_t)(i0 % size)] * (1.0f - fr) + side_buf[(size_t)((i0 + 1) % size)] * fr;
				const int64_t ci = ((w - cross_d) % size + size) % size;
				const float xl = cross_buf[(size_t)ci * 2];
				const float xr = cross_buf[(size_t)ci * 2 + 1];
				f[0] = m + sd - sur * 0.5f * xr;
				f[1] = m - sd - sur * 0.5f * xl;
				w = (w + 1) % size;
			}
		}
	}
};

// ---- Noise Gate -------------------------------------------------------------------------
// Params: threshold dB, range dB (how far the closed gate turns the sound down), attack ms,
// hold ms, release ms, hysteresis dB. Stereo-linked peak detector, no look-ahead.
class GateFx : public Effect {
	const EffectSpec *spec;
	double sr;
	bool open = false;
	float gain = -1.0f; // current linear gain; negative = not started (snaps to the first target)
	int64_t hold_left = 0;

public:
	GateFx(const EffectSpec &p_spec, double p_sr) :
			spec(&p_spec), sr(p_sr) {}
	void rebind(const EffectSpec &p_spec) override { spec = &p_spec; }
	void reset() override {
		open = false;
		gain = -1.0f;
		hold_left = 0;
	}

	void process(float *io, int64_t frames, int64_t pos0) override {
		for (int64_t b = 0; b < frames; b += CONTROL_BLOCK) {
			const int64_t n = std::min(CONTROL_BLOCK, frames - b);
			const double pos = (double)(pos0 + b);
			const float thr_open = db_to_lin(spec->params[0].at(pos));
			const float floor_g = db_to_lin(std::min(spec->params[1].at(pos), 0.0f));
			const float att = std::exp(-1.0f / (std::max(spec->params[2].at(pos), 0.01f) * 0.001f * (float)sr));
			const int64_t hold = (int64_t)(std::max(spec->params[3].at(pos), 0.0f) * 0.001f * (float)sr);
			const float rel = std::exp(-1.0f / (std::max(spec->params[4].at(pos), 1.0f) * 0.001f * (float)sr));
			const float thr_close = thr_open * db_to_lin(-std::max(spec->params[5].at(pos), 0.0f));
			for (int64_t i = 0; i < n; i++) {
				float *f = io + (b + i) * 2;
				const float lvl = std::max(std::fabs(f[0]), std::fabs(f[1]));
				if (lvl >= thr_open) {
					open = true;
					hold_left = hold;
				} else if (open && lvl < thr_close) {
					if (hold_left > 0) {
						hold_left--;
					} else {
						open = false;
					}
				} else if (open) {
					hold_left = hold;
				}
				const float target = open ? 1.0f : floor_g;
				if (gain < 0.0f) {
					gain = target;
				}
				const float coef = target > gain ? att : rel;
				gain = flush(target + (gain - target) * coef);
				f[0] *= gain;
				f[1] *= gain;
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
		case FX_REVERB:
			return 5;
		case FX_CHORUS:
			return 4;
		case FX_PHASER:
			return 3;
		case FX_STEREO_ENHANCE:
			return 3;
		case FX_GATE:
			return 6;
	}
	return 0;
}

bool can_make(const EffectSpec &p_spec) {
	return p_spec.type >= FX_LOW_PASS && p_spec.type <= FX_GATE && p_spec.params.size() >= param_count(p_spec.type);
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
		case FX_REVERB:
			return std::make_unique<ReverbFx>(p_spec, p_sr);
		case FX_CHORUS:
			return std::make_unique<ChorusFx>(p_spec, p_sr);
		case FX_PHASER:
			return std::make_unique<PhaserFx>(p_spec, p_sr);
		case FX_STEREO_ENHANCE:
			return std::make_unique<StereoEnhanceFx>(p_spec, p_sr);
		case FX_GATE:
			return std::make_unique<GateFx>(p_spec, p_sr);
	}
	return nullptr;
}

} // namespace aw
