#include "aw_core.h"

#include <chrono>
#include <thread>

#include <algorithm>
#include <cmath>
#include <cstring>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#ifndef AW_ENGINE_VERSION
#define AW_ENGINE_VERSION "dev"
#endif
#ifndef AW_GODOT_CPP
#define AW_GODOT_CPP "unknown"
#endif

using namespace godot;

void AWCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_version"), &AWCore::get_version);
	ClassDB::bind_method(D_METHOD("get_build_info"), &AWCore::get_build_info);
	ClassDB::bind_method(D_METHOD("set_sample_rate", "rate"), &AWCore::set_sample_rate);
	ClassDB::bind_method(D_METHOD("get_sample_rate"), &AWCore::get_sample_rate);
	ClassDB::bind_method(D_METHOD("set_test_tone", "hz", "gain_db"), &AWCore::set_test_tone);
	ClassDB::bind_method(D_METHOD("add_source", "frames"), &AWCore::add_source);
	ClassDB::bind_method(D_METHOD("get_source_frames", "id"), &AWCore::get_source_frames);
	ClassDB::bind_method(D_METHOD("get_peaks", "id", "per_second"), &AWCore::get_peaks);
	ClassDB::bind_method(D_METHOD("clear_sources"), &AWCore::clear_sources);
	ClassDB::bind_method(D_METHOD("sample_curve", "animation", "spec", "start", "step", "count", "unit"), &AWCore::sample_curve);
	ClassDB::bind_method(D_METHOD("sample_curve_at", "animation", "spec", "times", "unit"), &AWCore::sample_curve_at);
	ClassDB::bind_method(D_METHOD("set_plan", "voices", "master"), &AWCore::set_plan, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("get_plan_end"), &AWCore::get_plan_end);
	ClassDB::bind_method(D_METHOD("get_effect_types"), &AWCore::get_effect_types);
	ClassDB::bind_method(D_METHOD("get_api_level"), &AWCore::get_api_level);
	ClassDB::bind_method(D_METHOD("get_load"), &AWCore::get_load);
	ClassDB::bind_method(D_METHOD("get_fx_swaps"), &AWCore::get_fx_swaps);
	ClassDB::bind_method(D_METHOD("scrub_begin", "frame"), &AWCore::scrub_begin);
	ClassDB::bind_method(D_METHOD("scrub_to", "frame"), &AWCore::scrub_to);
	ClassDB::bind_method(D_METHOD("scrub_end"), &AWCore::scrub_end);
	ClassDB::bind_method(D_METHOD("is_scrubbing"), &AWCore::is_scrubbing);
	ClassDB::bind_method(D_METHOD("scrub_simulate", "targets", "block"), &AWCore::scrub_simulate);
	ClassDB::bind_method(D_METHOD("play", "from_frame"), &AWCore::play);
	ClassDB::bind_method(D_METHOD("stop"), &AWCore::stop);
	ClassDB::bind_method(D_METHOD("seek", "frame"), &AWCore::seek);
	ClassDB::bind_method(D_METHOD("set_loop", "enabled", "start_frame", "end_frame"), &AWCore::set_loop);
	ClassDB::bind_method(D_METHOD("is_playing"), &AWCore::is_playing);
	ClassDB::bind_method(D_METHOD("get_position"), &AWCore::get_position);
	ClassDB::bind_method(D_METHOD("render_range", "from_frame", "frames"), &AWCore::render_range);
	ClassDB::bind_method(D_METHOD("export_begin", "from_frame"), &AWCore::export_begin);
	ClassDB::bind_method(D_METHOD("export_next", "frames", "bits"), &AWCore::export_next);
	ClassDB::bind_method(D_METHOD("export_end"), &AWCore::export_end);
	ClassDB::bind_method(D_METHOD("export_configure", "kind", "quality", "total_frames"), &AWCore::export_configure);
	ClassDB::bind_method(D_METHOD("export_finish"), &AWCore::export_finish);
	ClassDB::bind_method(D_METHOD("render", "frames"), &AWCore::render);
	ClassDB::bind_method(D_METHOD("get_frames_rendered"), &AWCore::get_frames_rendered);
	ClassDB::bind_method(D_METHOD("reset"), &AWCore::reset);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sample_rate"), "set_sample_rate", "get_sample_rate");
}

String AWCore::get_version() const {
	return AW_ENGINE_VERSION;
}

Dictionary AWCore::get_build_info() const {
	Dictionary d;
	d["version"] = AW_ENGINE_VERSION;
	d["godot_cpp"] = AW_GODOT_CPP;
	d["api"] = "4.7";
#ifdef DEBUG_ENABLED
	d["target"] = "debug";
#else
	d["target"] = "release";
#endif
#if defined(__clang__)
	d["compiler"] = String("clang ") + __clang_version__;
#elif defined(__GNUC__)
	d["compiler"] = String("gcc ") + __VERSION__;
#elif defined(_MSC_VER)
	d["compiler"] = String("msvc ") + String::num_int64(_MSC_VER);
#else
	d["compiler"] = "unknown";
#endif
	d["built"] = String(__DATE__) + " " + __TIME__;
	return d;
}

void AWCore::set_sample_rate(double p_rate) {
	sample_rate = CLAMP(p_rate, 8000.0, 192000.0);
}

double AWCore::get_sample_rate() const {
	return sample_rate;
}

void AWCore::set_test_tone(double p_hz, double p_gain_db) {
	tone_hz = p_hz;
	tone_gain = std::pow(10.0, p_gain_db / 20.0);
}

// --- Voices ---------------------------------------------------------------------

void AWCore::Voice::prepare() {
	if (rates.empty()) {
		rates.push_back(1.0f);
	}
	for (float &r : rates) {
		r = CLAMP(r, 0.01f, 100.0f);
	}
	if (gains.empty()) {
		gains.push_back(1.0f);
	}
	if (pans.empty()) {
		pans.push_back(0.0f);
	}
	step = std::max<int64_t>(step, 1);
	cum.clear();
	if (rates.size() > 1) {
		cum.resize(rates.size());
		cum[0] = 0.0;
		for (size_t i = 0; i + 1 < rates.size(); i++) {
			cum[i + 1] = cum[i] + (double)step * 0.5 * (1.0 / rates[i] + 1.0 / rates[i + 1]);
		}
	}
	play_frames = warp(length);
}

double AWCore::Voice::warp(double s) const {
	if (cum.empty()) {
		return s / rates[0];
	}
	const double smax = (double)(rates.size() - 1) * (double)step;
	if (s <= 0.0) {
		return s / rates[0];
	}
	if (s >= smax) {
		return cum.back() + (s - smax) / rates.back();
	}
	const double x = s / (double)step;
	const size_t i = std::min((size_t)x, rates.size() - 2);
	return cum[i] + (cum[i + 1] - cum[i]) * (x - (double)i);
}

double AWCore::Voice::unwarp(double p) const {
	if (cum.empty()) {
		return p * rates[0];
	}
	const double smax = (double)(rates.size() - 1) * (double)step;
	if (p <= 0.0) {
		return p * rates[0];
	}
	if (p >= cum.back()) {
		return smax + (p - cum.back()) * rates.back();
	}
	size_t i = (size_t)(std::upper_bound(cum.begin(), cum.end(), p) - cum.begin());
	i = (i == 0) ? 0 : i - 1;
	i = std::min(i, cum.size() - 2);
	const double span = cum[i + 1] - cum[i];
	const double f = span > 0.0 ? (p - cum[i]) / span : 0.0;
	return ((double)i + f) * (double)step;
}

static inline float aw_at(const std::vector<float> &d, int64_t frames, int64_t i, int ch) {
	return (i < 0 || i >= frames) ? 0.0f : d[(size_t)(i * 2 + ch)];
}

// 4-point cubic Hermite interpolation between frames i and i+1.
static inline float aw_hermite(const AWCore::Source &src, double x, int ch) {
	const int64_t i = (int64_t)std::floor(x);
	const float t = (float)(x - (double)i);
	const float y0 = aw_at(src.data, src.frames, i - 1, ch);
	const float y1 = aw_at(src.data, src.frames, i, ch);
	const float y2 = aw_at(src.data, src.frames, i + 1, ch);
	const float y3 = aw_at(src.data, src.frames, i + 2, ch);
	const float c1 = 0.5f * (y2 - y0);
	const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
	const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
	return ((c3 * t + c2) * t + c1) * t + y1;
}

// Linear lookup in a table whose entry i belongs to position i * step (positions in frames).
static inline float aw_table(const std::vector<float> &t, double pos, int64_t step) {
	if (t.size() == 1 || pos <= 0.0) {
		return t[0];
	}
	const double x = pos / (double)step;
	const size_t last = t.size() - 1;
	if (x >= (double)last) {
		return t[last];
	}
	const size_t i = (size_t)x;
	const float f = (float)(x - (double)i);
	return t[i] + (t[i + 1] - t[i]) * f;
}

// Adds one voice's dry signal (source, rate warp, gain, pan, fades) for block frames
// [j0, j1) into r_out, where block frame j is written at r_out[(j - origin) * 2].
// AWClip.fade_gain: gain at fade position u (0 = silent end, 1 = full) for each fade shape.
static inline double aw_fade_shape(int p_shape, double u) {
	u = u < 0.0 ? 0.0 : (u > 1.0 ? 1.0 : u);
	switch (p_shape) {
		case 1: // fast: rises quickly, then levels off
			return 1.0 - (1.0 - u) * (1.0 - u);
		case 2: // slow: stays low, then rises
			return u * u;
		case 3: // S-curve
			return u * u * (3.0 - 2.0 * u);
		case 4: // equal power (for crossfades)
			return std::sin(u * 1.5707963267948966);
		default:
			return u;
	}
}

void AWCore::render_voice_dry(const Voice &p_voice, int64_t p_from, int64_t p_j0, int64_t p_j1, float *r_out, int64_t p_origin) {
	const int64_t j0 = p_j0, j1 = p_j1;
	const Source &src = *p_voice.source;
	// Cursor into the rate table, advanced monotonically across the block.
	size_t cur = 0;
	const bool table = !p_voice.cum.empty();
	if (table) {
		const double p0 = (double)(p_from + j0 - p_voice.start);
		if (p0 > 0.0) {
			cur = (size_t)(std::upper_bound(p_voice.cum.begin(), p_voice.cum.end(), p0) - p_voice.cum.begin());
			cur = cur == 0 ? 0 : cur - 1;
		}
	}
	const double smax = table ? (double)(p_voice.rates.size() - 1) * (double)p_voice.step : 0.0;
	for (int64_t j = j0; j < j1; j++) {
		const double p = (double)(p_from + j - p_voice.start);
		double s;
		if (!table) {
			s = p * p_voice.rates[0];
		} else if (p <= 0.0) {
			s = p * p_voice.rates[0];
		} else if (p >= p_voice.cum.back()) {
			s = smax + (p - p_voice.cum.back()) * p_voice.rates.back();
		} else {
			while (cur + 2 < p_voice.cum.size() && p >= p_voice.cum[cur + 1]) {
				cur++;
			}
			const double span = p_voice.cum[cur + 1] - p_voice.cum[cur];
			const double f = span > 0.0 ? (p - p_voice.cum[cur]) / span : 0.0;
			s = ((double)cur + f) * (double)p_voice.step;
		}
		if (s < 0.0 || s >= p_voice.length) {
			continue;
		}
		const double x = p_voice.reversed ? p_voice.offset + p_voice.length - s : p_voice.offset + s;
		if (x < -1.0 || x > (double)src.frames) {
			continue;
		}
		float g = aw_table(p_voice.gains, s, p_voice.step);
		const float pan = aw_table(p_voice.pans, s, p_voice.step);
		const float gl = pan > 0.0f ? 1.0f - pan : 1.0f;
		const float gr = pan < 0.0f ? 1.0f + pan : 1.0f;
		if (p_voice.fade_in > 0.0 && s < p_voice.fade_in) {
			g *= (float)aw_fade_shape(p_voice.fade_in_shape, s / p_voice.fade_in);
		}
		if (p_voice.fade_out > 0.0 && s > p_voice.length - p_voice.fade_out) {
			g *= (float)aw_fade_shape(p_voice.fade_out_shape, std::max(0.0, (p_voice.length - s) / p_voice.fade_out));
		}
		r_out[(j - p_origin) * 2] += aw_hermite(src, x, 0) * g * gl;
		r_out[(j - p_origin) * 2 + 1] += aw_hermite(src, x, 1) * g * gr;
	}
}

// Adds every voice that overlaps [from, from + frames) into the interleaved buffer, running
// each voice's effect chain (and its tail) when `p_fx` is given.
void AWCore::render_voices(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_out, FxRuntime *p_fx) {
	for (size_t vi = 0; vi < p_plan.voices.size(); vi++) {
		const Voice &v = p_plan.voices[vi];
		if (!v.source) {
			continue;
		}
		const int64_t play_end = (int64_t)std::ceil(v.play_frames) + v.start - p_from;
		const int64_t j0 = std::max<int64_t>(0, v.start - p_from);
		const int64_t j1 = std::min<int64_t>(p_frames, play_end);
		const bool has_fx = p_fx && vi < p_fx->voice.size() && !p_fx->voice[vi].empty();
		const int64_t jx = has_fx ? std::min<int64_t>(p_frames, play_end + v.tail_frames) : j1;
		if (j0 >= jx) {
			continue;
		}
		if (!has_fx) {
			render_voice_dry(v, p_from, j0, j1, r_out, 0);
			continue;
		}
		const int64_t n = jx - j0;
		p_fx->scratch.assign((size_t)n * 2, 0.0f);
		if (j0 < j1) {
			render_voice_dry(v, p_from, j0, j1, p_fx->scratch.data(), j0);
		}
		const int64_t pos0 = p_from + j0 - v.start;
		for (auto &e : p_fx->voice[vi]) {
			e->process(p_fx->scratch.data(), n, pos0);
		}
		float *dst = r_out + j0 * 2;
		for (int64_t i = 0; i < n * 2; i++) {
			dst[i] += p_fx->scratch[(size_t)i];
		}
	}
}

void AWCore::apply_master(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_out, FxRuntime *p_fx) {
	apply_master_gain(p_plan, p_from, p_frames, r_out);
	if (p_fx) {
		for (auto &e : p_fx->master) {
			e->process(r_out, p_frames, p_from);
		}
	}
}

void AWCore::apply_master_gain(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_out) {
	if (p_plan.master.size() == 1) {
		const float g = p_plan.master[0];
		if (g != 1.0f) {
			for (int64_t j = 0; j < p_frames * 2; j++) {
				r_out[j] *= g;
			}
		}
		return;
	}
	for (int64_t j = 0; j < p_frames; j++) {
		const float g = aw_table(p_plan.master, (double)(p_from + j), p_plan.master_step);
		r_out[j * 2] *= g;
		r_out[j * 2 + 1] *= g;
	}
}

// --- Sources --------------------------------------------------------------------

int64_t AWCore::add_source(const PackedVector2Array &p_frames) {
	auto src = std::make_shared<Source>();
	src->frames = p_frames.size();
	src->data.resize((size_t)src->frames * 2);
	const Vector2 *r = p_frames.ptr();
	for (int64_t i = 0; i < src->frames; i++) {
		src->data[(size_t)i * 2] = r[i].x;
		src->data[(size_t)i * 2 + 1] = r[i].y;
	}
	sources.push_back(src);
	return (int64_t)sources.size() - 1;
}

int64_t AWCore::get_source_frames(int64_t p_id) const {
	if (p_id < 0 || p_id >= (int64_t)sources.size()) {
		return 0;
	}
	return sources[(size_t)p_id]->frames;
}

PackedFloat32Array AWCore::get_peaks(int64_t p_id, double p_per_second) const {
	PackedFloat32Array out;
	if (p_id < 0 || p_id >= (int64_t)sources.size() || p_per_second <= 0.0) {
		return out;
	}
	const Source &src = *sources[(size_t)p_id];
	const double per_bucket = sample_rate / p_per_second;
	const int64_t n = (int64_t)std::ceil((double)src.frames / per_bucket);
	out.resize(n);
	float *w = out.ptrw();
	for (int64_t b = 0; b < n; b++) {
		const int64_t a = (int64_t)std::floor((double)b * per_bucket);
		const int64_t e = std::min<int64_t>(src.frames, (int64_t)std::floor((double)(b + 1) * per_bucket));
		float m = 0.0f;
		for (int64_t i = a; i < std::max(e, a + 1) && i < src.frames; i++) {
			m = std::max(m, std::max(std::fabs(src.data[(size_t)i * 2]), std::fabs(src.data[(size_t)i * 2 + 1])));
		}
		w[b] = std::min(m, 1.0f);
	}
	return out;
}

void AWCore::clear_sources() {
	// Voices keep their own shared_ptr to the source, so a running plan stays valid.
	sources.clear();
}

// --- Curve sampling -------------------------------------------------------------
// A port of AWCurveMath.to_norm/from_norm, AWLfo.wave/envelope and AWChain.base_norm/
// sample_norm. The GDScript versions stay the reference (the self-test compares them).

static const double AW_FADER_EXP = 0.25;

static inline double aw_db_to_linear(double db) {
	return std::pow(10.0, db / 20.0);
}

static inline double aw_clamp01(double x) {
	return x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);
}

// AWLfo.hash01 / _smooth.
static inline double aw_hash01(double k, double seed) {
	const double r = std::sin(k * 12.9898 + seed * 78.233) * 43758.5453;
	return r - std::floor(r);
}

static inline double aw_smooth(double x) {
	x = aw_clamp01(x);
	return x * x * (3.0 - 2.0 * x);
}

static double aw_to_norm(int scale, double v, double lo, double hi) {
	if (scale == 1) { // LOG
		if (lo > 0.0 && hi > lo) {
			return aw_clamp01(std::log(std::max(v, lo) / lo) / std::log(hi / lo));
		}
	} else if (scale == 2) { // FADER
		const double f0 = std::pow(aw_db_to_linear(lo), AW_FADER_EXP);
		const double f1 = std::pow(aw_db_to_linear(hi), AW_FADER_EXP);
		return aw_clamp01((std::pow(aw_db_to_linear(v), AW_FADER_EXP) - f0) / (f1 - f0));
	}
	return hi > lo ? aw_clamp01((v - lo) / (hi - lo)) : 0.0;
}

static double aw_from_norm(int scale, double n, double lo, double hi) {
	n = aw_clamp01(n);
	if (scale == 1) {
		if (lo > 0.0 && hi > lo) {
			return lo * std::pow(hi / lo, n);
		}
	} else if (scale == 2) {
		const double f0 = std::pow(aw_db_to_linear(lo), AW_FADER_EXP);
		const double f1 = std::pow(aw_db_to_linear(hi), AW_FADER_EXP);
		const double lin = std::pow(f0 + n * (f1 - f0), 1.0 / AW_FADER_EXP);
		const double db = lin <= 0.0 ? -INFINITY : 20.0 * std::log10(lin);
		return CLAMP(db, lo, hi);
	}
	return lo + n * (hi - lo);
}

PackedFloat32Array AWCore::sample_curve(const Ref<Animation> &p_anim, const Dictionary &p_spec, double p_start, double p_step, int64_t p_count, int64_t p_unit) const {
	return sample_curve_impl(p_anim, p_spec, nullptr, p_start, p_step, p_count, p_unit);
}

PackedFloat32Array AWCore::sample_curve_at(const Ref<Animation> &p_anim, const Dictionary &p_spec, const PackedFloat64Array &p_times, int64_t p_unit) const {
	return sample_curve_impl(p_anim, p_spec, p_times.ptr(), 0.0, 0.0, p_times.size(), p_unit);
}

PackedFloat32Array AWCore::sample_curve_impl(const Ref<Animation> &p_anim, const Dictionary &p_spec, const double *p_times, double p_start, double p_step, int64_t p_count, int64_t p_unit) const {
	PackedFloat32Array out;
	if (p_count <= 0) {
		return out;
	}
	out.resize(p_count);
	float *w = out.ptrw();

	const int track = p_spec.get("track", -1);
	const int scale = p_spec.get("scale", 0);
	const double lo = p_spec.get("lo", 0.0);
	const double hi = p_spec.get("hi", 1.0);
	const double static_norm = p_spec.get("static_norm", 0.0);
	const Dictionary lfo = p_spec.get("lfo", Dictionary());

	int key_count = 0;
	double first_t = 0.0, last_t = 0.0, first_v = 0.0, last_v = 0.0;
	if (p_anim.is_valid() && track >= 0 && track < p_anim->get_track_count()) {
		key_count = p_anim->track_get_key_count(track);
		if (key_count > 0) {
			first_t = p_anim->track_get_key_time(track, 0);
			last_t = p_anim->track_get_key_time(track, key_count - 1);
			first_v = p_anim->bezier_track_get_key_value(track, 0);
			last_v = p_anim->bezier_track_get_key_value(track, key_count - 1);
		}
	}

	const bool has_lfo = !lfo.is_empty();
	int shape = 0;
	double lmin = 0, lmax = 0, freq = 1, fade_in = 0, fade_out = 0, lstart = 0, lend = 1, seed = 1, accel = 0, smooth = 0;
	int lmode = 0;
	double depth = 0.1, phase0 = 0.0, jit_rate = 0.0, jit_depth = 0.0, glide = 0.0, decay = 0.0;
	double lo_n = 0, hi_n = 0, f_in = 0, f_out = 0, span = 0;
	if (has_lfo) {
		shape = lfo.get("shape", 0);
		lmin = lfo.get("min", 0.0);
		lmax = lfo.get("max", 1.0);
		freq = lfo.get("freq", 4.0);
		fade_in = lfo.get("fade_in", 0.0);
		fade_out = lfo.get("fade_out", 0.0);
		lstart = lfo.get("start", 0.0);
		lend = lfo.get("end", 1.0);
		seed = (double)(int64_t)lfo.get("seed", 1);
		accel = lfo.get("accel", 0.0);
		smooth = lfo.get("smooth", 0.0);
		lmode = lfo.get("mode", 0);
		depth = lfo.get("depth", 0.1);
		phase0 = lfo.get("phase", 0.0); // cycles
		jit_rate = lfo.get("jit_rate", 0.0);
		jit_depth = lfo.get("jit_depth", 0.0);
		glide = lfo.get("glide", 0.0);
		decay = lfo.get("decay", 0.0);
		lo_n = aw_to_norm(scale, std::min(lmin, lmax), lo, hi);
		hi_n = aw_to_norm(scale, std::max(lmin, lmax), lo, hi);
		span = std::max(lend - lstart, 0.0);
		f_in = CLAMP(fade_in, 0.0, span);
		f_out = CLAMP(fade_out, 0.0, span - f_in);
	}

	for (int64_t i = 0; i < p_count; i++) {
		const double t = p_times ? p_times[i] : p_start + (double)i * p_step;
		double b;
		if (key_count == 0) {
			b = static_norm;
		} else if (t <= first_t) {
			b = first_v;
		} else if (t >= last_t) {
			b = last_v;
		} else {
			b = aw_clamp01(p_anim->bezier_track_interpolate(track, t));
		}
		double n = b;
		if (has_lfo && p_unit != 4) {
			double e = 0.0;
			if (!(t < lstart || t > lend || span <= 0.0)) {
				e = 1.0;
				if (f_in > 0.0) {
					e = std::min(e, (t - lstart) / f_in);
				}
				if (f_out > 0.0) {
					e = std::min(e, (lend - t) / f_out);
				}
				e = aw_clamp01(e);
				e = e + smooth * (e * e * (3.0 - 2.0 * e) - e);
				if (decay > 0.0) {
					e *= std::pow(0.5, (t - lstart) / decay);
				}
			}
			if (e > 0.0) {
				double tau = t - lstart;
				double p;
				if (tau <= 0.0 || accel == 0.0) {
					p = tau * freq;
				} else {
					if (accel < 0.0) {
						tau = std::min(tau, freq / -accel);
					}
					p = freq * tau + 0.5 * accel * tau * tau;
				}
				// AWLfo.warped_phase: Phase offset, then Jitter's per-cycle stretch.
				p += phase0;
				if (jit_rate > 0.0) {
					const double k = std::floor(p);
					const double ja = (aw_hash01(k, seed + 17.0) - 0.5) * 0.5 * jit_rate;
					const double jb = (aw_hash01(k + 1.0, seed + 17.0) - 0.5) * 0.5 * jit_rate;
					p += ja + (jb - ja) * aw_smooth(p - k);
				}
				// AWLfo.shape_at
				const double fl = std::floor(p);
				const double ph = p - fl;
				double wv;
				switch (shape) {
					case 1:
						wv = 1.0 - std::fabs(ph * 2.0 - 1.0);
						break;
					case 2:
						if (glide <= 0.0) {
							wv = ph < 0.5 ? 1.0 : 0.0;
						} else {
							wv = 0.5 + 0.5 * CLAMP(std::sin(6.283185307179586 * p) / glide, -1.0, 1.0);
						}
						break;
					case 3:
						if (glide <= 0.0 || ph < 1.0 - glide * 0.5) {
							wv = ph / (1.0 - glide * 0.5);
						} else {
							wv = 1.0 - aw_smooth((ph - (1.0 - glide * 0.5)) / (glide * 0.5));
						}
						break;
					case 4: {
						const double r = aw_hash01(fl, seed);
						if (glide <= 0.0 || ph < 1.0 - glide) {
							wv = r;
						} else {
							wv = r + (aw_hash01(fl + 1.0, seed) - r) * aw_smooth((ph - (1.0 - glide)) / glide);
						}
						break;
					}
					default:
						wv = 0.5 + 0.5 * std::sin(6.283185307179586 * p);
				}
				// AWLfo.cycle_amp, then AWChain.sample_norm
				double amp = 1.0;
				if (jit_depth > 0.0) {
					const double aa = 1.0 - jit_depth * aw_hash01(fl, seed + 31.0);
					const double ab = 1.0 - jit_depth * aw_hash01(fl + 1.0, seed + 31.0);
					amp = aa + (ab - aa) * aw_smooth(ph);
				}
				const double sw = (wv * 2.0 - 1.0) * amp;
				if (lmode == 1) {
					n = aw_clamp01(b + depth * sw * e);
				} else {
					const double target = lo_n + (hi_n - lo_n) * (0.5 + 0.5 * sw);
					n = aw_clamp01(b + (target - b) * e);
				}
			}
		}
		double v;
		switch (p_unit) {
			case 1:
			case 4:
				v = n;
				break;
			case 2: {
				const double db = aw_from_norm(scale, n, lo, hi);
				v = db <= -59.9 ? 0.0 : aw_db_to_linear(db);
				break;
			}
			case 3:
				v = std::pow(2.0, aw_from_norm(scale, n, lo, hi) / 12.0);
				break;
			default:
				v = aw_from_norm(scale, n, lo, hi);
		}
		w[i] = (float)v;
	}
	return out;
}

// --- Plan -----------------------------------------------------------------------

// --- Effects ----------------------------------------------------------------------

static bool aw_parse_effects(const Array &p_in, std::vector<aw::EffectSpec> &r_out) {
	for (int i = 0; i < p_in.size(); i++) {
		const Dictionary d = p_in[i];
		aw::EffectSpec spec;
		spec.type = d.get("type", 0);
		const Array tables = d.get("params", Array());
		const int64_t step = std::max<int64_t>(1, (int64_t)d.get("step", 64));
		for (int k = 0; k < tables.size(); k++) {
			const PackedFloat32Array t = tables[k];
			aw::Param p;
			p.step = step;
			if (!t.is_empty()) {
				p.table.assign(t.ptr(), t.ptr() + t.size());
			}
			spec.params.push_back(std::move(p));
		}
		if (spec.type != aw::FX_NONE) {
			r_out.push_back(std::move(spec));
		}
	}
	return !r_out.empty();
}

void AWCore::FxRuntime::bind(const std::shared_ptr<const Plan> &p_plan, double p_rate) {
	plan = p_plan;
	voice.clear();
	master.clear();
	next = -1;
	if (!plan) {
		return;
	}
	voice_src.clear();
	master_src.clear();
	for (const Voice &v : plan->voices) {
		voice.emplace_back();
		voice_src.emplace_back();
		for (size_t i = 0; i < v.effects.size(); i++) {
			if (auto e = aw::make_effect(v.effects[i], p_rate)) {
				voice.back().push_back(std::move(e));
				voice_src.back().emplace_back(i, v.effects[i].type);
			}
		}
	}
	for (size_t i = 0; i < plan->master_effects.size(); i++) {
		if (auto e = aw::make_effect(plan->master_effects[i], p_rate)) {
			master.push_back(std::move(e));
			master_src.emplace_back(i, plan->master_effects[i].type);
		}
	}
	scratch.reserve(4096);
}

static bool same_layout(const std::vector<std::pair<size_t, int>> &p_src, const std::vector<aw::EffectSpec> &p_specs) {
	size_t made = 0;
	for (const aw::EffectSpec &s : p_specs) {
		if (aw::can_make(s)) {
			made++;
		}
	}
	if (made != p_src.size()) {
		return false;
	}
	for (const auto &e : p_src) {
		if (e.first >= p_specs.size() || p_specs[e.first].type != e.second || !aw::can_make(p_specs[e.first])) {
			return false;
		}
	}
	return true;
}

bool AWCore::FxRuntime::adopt(const std::shared_ptr<const Plan> &p_plan) {
	if (!plan || !p_plan || p_plan->voices.size() != plan->voices.size() || voice_src.size() != p_plan->voices.size()) {
		return false;
	}
	for (size_t v = 0; v < p_plan->voices.size(); v++) {
		if (!same_layout(voice_src[v], p_plan->voices[v].effects)) {
			return false;
		}
	}
	if (!same_layout(master_src, p_plan->master_effects)) {
		return false;
	}
	for (size_t v = 0; v < voice.size(); v++) {
		for (size_t i = 0; i < voice[v].size(); i++) {
			voice[v][i]->rebind(p_plan->voices[v].effects[voice_src[v][i].first]);
		}
	}
	for (size_t i = 0; i < master.size(); i++) {
		master[i]->rebind(p_plan->master_effects[master_src[i].first]);
	}
	plan = p_plan;
	return true;
}

void AWCore::FxRuntime::reset() {
	for (auto &chain : voice) {
		for (auto &e : chain) {
			e->reset();
		}
	}
	for (auto &e : master) {
		e->reset();
	}
}

int64_t AWCore::set_plan(const Array &p_voices, const Dictionary &p_master) {
	auto np = std::make_shared<Plan>();
	{
		const PackedFloat32Array mg = p_master.get("gains", PackedFloat32Array());
		if (!mg.is_empty()) {
			np->master.assign(mg.ptr(), mg.ptr() + mg.size());
			np->master_step = std::max<int64_t>(1, (int64_t)p_master.get("step", 64));
		} else {
			np->master.push_back(1.0f);
		}
		aw_parse_effects(p_master.get("effects", Array()), np->master_effects);
		np->master_tail = np->master_effects.empty() ? 0 : std::max<int64_t>(0, (int64_t)p_master.get("tail_frames", 0));
	}
	for (int i = 0; i < p_voices.size(); i++) {
		const Dictionary d = p_voices[i];
		Voice v;
		const int64_t id = d.get("source", -1);
		if (id >= 0 && id < (int64_t)sources.size()) {
			v.source = sources[(size_t)id];
		}
		v.start = d.get("start_frame", 0);
		v.offset = d.get("offset", 0.0);
		v.length = d.get("length", 0.0);
		v.fade_in = d.get("fade_in", 0.0);
		v.fade_out = d.get("fade_out", 0.0);
		v.fade_in_shape = d.get("fade_in_shape", 0);
		v.fade_out_shape = d.get("fade_out_shape", 0);
		v.reversed = d.get("reversed", false);
		const PackedFloat32Array gains = d.get("gains", PackedFloat32Array());
		if (gains.is_empty()) {
			v.gains.push_back((float)(double)d.get("gain", 1.0));
		} else {
			v.gains.assign(gains.ptr(), gains.ptr() + gains.size());
		}
		const PackedFloat32Array pans = d.get("pans", PackedFloat32Array());
		if (pans.is_empty()) {
			v.pans.push_back((float)(double)d.get("pan", 0.0));
		} else {
			v.pans.assign(pans.ptr(), pans.ptr() + pans.size());
		}
		for (float &p : v.pans) {
			p = CLAMP(p, -1.0f, 1.0f);
		}
		const PackedFloat32Array rates = d.get("rates", PackedFloat32Array());
		v.rates.assign(rates.ptr(), rates.ptr() + rates.size());
		v.step = d.get("rate_step", 64);
		v.prepare();
		if (aw_parse_effects(d.get("effects", Array()), v.effects)) {
			v.tail_frames = std::max<int64_t>(0, (int64_t)d.get("tail_frames", 0));
		}
		np->end_frame = std::max(np->end_frame, v.start + (int64_t)std::ceil(v.play_frames) + v.tail_frames);
		np->voices.push_back(std::move(v));
	}
	if (p_master.has("end_frame")) {
		// The export marker decides where the sound ends, however the clips and tails add up.
		np->end_frame = std::max<int64_t>(0, (int64_t)p_master["end_frame"]);
	} else {
		np->end_frame += np->master_tail;
	}
	auto staged = std::make_unique<FxRuntime>();
	staged->bind(np, sample_rate); // allocates the delay and reverb buffers here, not on the audio thread
	std::unique_ptr<FxRuntime> old_staged;
	{
		std::lock_guard<std::mutex> lock(plan_mutex);
		retired.push_back(plan);
		plan = np;
		old_staged = std::move(staged_fx);
		staged_fx = std::move(staged);
	}
	old_staged.reset();
	// Keep the last couple of plans alive so the audio thread never drops the final reference.
	while (retired.size() > 2) {
		retired.erase(retired.begin());
	}
	return np->end_frame;
}

int64_t AWCore::get_api_level() const {
	return 12; // 12: scrub; 11: clip reverse and fade shapes; 10: LFO mode, depth, phase, jitter, glide, decay; 9: effect state kept across plan swaps, get_fx_swaps; 8: get_load; 7: export_configure / export_finish (Ogg Vorbis); 6: export_begin / export_next / export_end; 5: Reverb, Chorus, Phaser, Stereo Enhance, Gate; 4: Distortion, Delay, Compressor, Limiter; 2: set_plan's master dictionary takes end_frame; 3: LFO accel and fade smoothing
}

PackedInt32Array AWCore::get_effect_types() const {
	PackedInt32Array out;
	out.push_back(aw::FX_LOW_PASS);
	out.push_back(aw::FX_HIGH_PASS);
	out.push_back(aw::FX_BAND_PASS);
	out.push_back(aw::FX_EQ6);
	out.push_back(aw::FX_AMPLIFY);
	out.push_back(aw::FX_DISTORTION);
	out.push_back(aw::FX_DELAY);
	out.push_back(aw::FX_COMPRESSOR);
	out.push_back(aw::FX_LIMITER);
	out.push_back(aw::FX_REVERB);
	out.push_back(aw::FX_CHORUS);
	out.push_back(aw::FX_PHASER);
	out.push_back(aw::FX_STEREO_ENHANCE);
	out.push_back(aw::FX_GATE);
	return out;
}

std::shared_ptr<const AWCore::Plan> AWCore::current_plan() {
	std::lock_guard<std::mutex> lock(plan_mutex);
	return plan;
}

int64_t AWCore::get_plan_end() const {
	AWCore *self = const_cast<AWCore *>(this);
	auto p = self->current_plan();
	return p ? p->end_frame : 0;
}

// --- Transport ------------------------------------------------------------------

void AWCore::play(int64_t p_from_frame) {
	position.store(std::max<int64_t>(0, p_from_frame));
	playing.store(true);
}

void AWCore::stop() {
	playing.store(false);
}

void AWCore::seek(int64_t p_frame) {
	position.store(std::max<int64_t>(0, p_frame));
}

void AWCore::set_loop(bool p_enabled, int64_t p_start_frame, int64_t p_end_frame) {
	loop_start.store(std::max<int64_t>(0, p_start_frame));
	loop_end.store(p_end_frame);
	loop_enabled.store(p_enabled);
}

// --- Scrub --------------------------------------------------------------------------

void AWCore::Scrub::prepare(const std::shared_ptr<const Plan> &p_plan, double p_rate, double p_pos) {
	buf.assign((size_t)CHUNK * 2, 0.0f);
	buf_start = INT64_MIN;
	pos = p_pos;
	vel = 0.0;
	fx.bind(p_plan, p_rate);
	fx.scratch.reserve((size_t)CHUNK * 2 + 64);
}

void AWCore::Scrub::render(const std::shared_ptr<const Plan> &p_plan, double p_rate, double p_target, float *r_out, int64_t p_frames) {
	std::memset(r_out, 0, sizeof(float) * (size_t)p_frames * 2);
	if (!p_plan || buf.empty()) {
		return;
	}
	const bool fx_ok = fx.plan == p_plan;
	// Velocity follows the distance to the target (reaches it in ~50 ms), smoothed over ~20 ms.
	const double reach = p_rate * 0.05;
	const double k = 1.0 - std::exp(-1.0 / (p_rate * 0.02));
	for (int64_t i = 0; i < p_frames; i++) {
		double want = (p_target - pos) / reach;
		want = want > 4.0 ? 4.0 : (want < -4.0 ? -4.0 : want);
		vel += (want - vel) * k;
		pos += vel;
		const int64_t f0 = (int64_t)std::floor(pos);
		if (f0 < 0) {
			continue;
		}
		if (buf_start == INT64_MIN || f0 < buf_start || f0 + 1 >= buf_start + CHUNK) {
			// Refill around the position: ahead of it when moving forward, behind it when backward.
			int64_t start = vel >= 0.0 ? f0 - 16 : f0 - CHUNK + 16;
			start = std::max<int64_t>(0, start);
			std::fill(buf.begin(), buf.end(), 0.0f);
			if (fx_ok && fx.next != start) {
				fx.reset();
			}
			render_voices(*p_plan, start, CHUNK, buf.data(), fx_ok ? &fx : nullptr);
			apply_master(*p_plan, start, CHUNK, buf.data(), fx_ok ? &fx : nullptr);
			if (fx_ok) {
				fx.next = start + CHUNK;
			}
			buf_start = start;
		}
		const int64_t j = f0 - buf_start;
		const float f = (float)(pos - (double)f0);
		const float g = (float)std::min(1.0, std::fabs(vel) * 3.0); // a stopped tape is silent
		r_out[i * 2] = (buf[(size_t)j * 2] * (1.0f - f) + buf[(size_t)(j + 1) * 2] * f) * g;
		r_out[i * 2 + 1] = (buf[(size_t)j * 2 + 1] * (1.0f - f) + buf[(size_t)(j + 1) * 2 + 1] * f) * g;
	}
}

void AWCore::scrub_begin(double p_frame) {
	playing.store(false);
	scrubbing.store(false); // the audio thread leaves the state alone before it is rebuilt
	while (scrub_rendering.load()) {
		std::this_thread::yield();
	}
	scrub_target.store(p_frame);
	scrub_state.prepare(current_plan(), sample_rate, p_frame);
	scrubbing.store(true);
}

void AWCore::scrub_to(double p_frame) {
	scrub_target.store(std::max(0.0, p_frame));
}

void AWCore::scrub_end() {
	scrubbing.store(false);
	position.store((int64_t)std::llround(scrub_target.load()));
}

bool AWCore::is_scrubbing() const {
	return scrubbing.load();
}

PackedVector2Array AWCore::scrub_simulate(const PackedFloat64Array &p_targets, int64_t p_block) {
	PackedVector2Array out;
	if (p_targets.is_empty() || p_block <= 0) {
		return out;
	}
	Scrub s;
	const auto pl = current_plan();
	s.prepare(pl, sample_rate, p_targets[0]);
	std::vector<float> tmp((size_t)p_block * 2);
	out.resize(p_targets.size() * p_block);
	Vector2 *w = out.ptrw();
	for (int64_t b = 0; b < p_targets.size(); b++) {
		s.render(pl, sample_rate, p_targets[b], tmp.data(), p_block);
		for (int64_t i = 0; i < p_block; i++) {
			w[b * p_block + i] = Vector2(tmp[(size_t)i * 2], tmp[(size_t)i * 2 + 1]);
		}
	}
	return out;
}

bool AWCore::is_playing() const {
	return playing.load();
}

int64_t AWCore::get_position() const {
	return position.load();
}

// Renders `frames` (<= any size) from the transport into an interleaved, zeroed buffer.
void AWCore::mix_transport(float *r_out, int64_t p_frames) {
	std::memset(r_out, 0, sizeof(float) * (size_t)p_frames * 2);
	if (!playing.load()) {
		return;
	}
	const auto pl = current_plan();
	if (!pl) {
		playing.store(false);
		return;
	}
	int64_t pos = position.load();
	int64_t done = 0;
	while (done < p_frames) {
		const bool loop = loop_enabled.load() && loop_end.load() > loop_start.load();
		int64_t limit = p_frames - done;
		if (loop && pos < loop_end.load()) {
			limit = std::min(limit, loop_end.load() - pos);
		} else if (pos >= pl->end_frame) {
			playing.store(false);
			position.store(pl->end_frame);
			return;
		} else {
			limit = std::min(limit, pl->end_frame - pos);
		}
		if (fx.plan != pl && fx.adopt(pl)) {
			fx_adopted.fetch_add(1);
		} else if (fx.plan != pl) {
			fx_rebuilt.fetch_add(1);
			bool swapped = false;
			{
				std::lock_guard<std::mutex> lock(plan_mutex);
				if (staged_fx && staged_fx->plan == pl) {
					std::swap(fx, *staged_fx); // the old runtime is freed later by set_plan
					swapped = true;
				}
			}
			if (!swapped) {
				fx.bind(pl, sample_rate);
			}
		} else if (fx.next != pos) {
			fx.reset();
		}
		render_voices(*pl, pos, limit, r_out + done * 2, &fx);
		apply_master(*pl, pos, limit, r_out + done * 2, &fx);
		fx.next = pos + limit;
		pos += limit;
		done += limit;
		if (loop && pos >= loop_end.load()) {
			pos = loop_start.load();
		}
	}
	position.store(pos);
}

Array AWCore::get_fx_swaps() const {
	Array a;
	a.push_back(fx_adopted.load());
	a.push_back(fx_rebuilt.load());
	return a;
}

Array AWCore::get_load() const {
	Array a;
	a.push_back((double)load_avg.load());
	a.push_back((double)load_peak.load());
	return a;
}

int32_t AWCore::mix(AudioFrame *p_buffer, int32_t p_frames) {
	const auto t0 = std::chrono::steady_clock::now();
	float buf[2048];
	int32_t done = 0;
	while (done < p_frames) {
		const int32_t n = std::min(p_frames - done, 1024);
		scrub_rendering.store(true);
		if (scrubbing.load()) {
			scrub_state.render(current_plan(), sample_rate, scrub_target.load(), buf, n);
			position.store((int64_t)std::max(0.0, scrub_state.pos));
			scrub_rendering.store(false);
		} else {
			scrub_rendering.store(false);
			mix_transport(buf, n);
		}
		for (int32_t i = 0; i < n; i++) {
			p_buffer[done + i].left = buf[i * 2];
			p_buffer[done + i].right = buf[i * 2 + 1];
		}
		done += n;
	}
	if (p_frames > 0) {
		const double spent = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
		const float r = playing.load() ? (float)(spent / ((double)p_frames / sample_rate)) : 0.0f;
		load_avg.store(load_avg.load() * 0.9f + r * 0.1f);
		load_peak.store(std::max(r, load_peak.load() * 0.995f));
	}
	return p_frames;
}

PackedVector2Array AWCore::render_range(int64_t p_from_frame, int64_t p_frames) {
	PackedVector2Array out;
	if (p_frames <= 0) {
		return out;
	}
	out.resize(p_frames);
	std::vector<float> buf((size_t)p_frames * 2, 0.0f);
	const auto pl = current_plan();
	if (pl) {
		FxRuntime rt;
		rt.bind(pl, sample_rate);
		render_voices(*pl, p_from_frame, p_frames, buf.data(), &rt);
		apply_master(*pl, p_from_frame, p_frames, buf.data(), &rt);
	}
	Vector2 *w = out.ptrw();
	for (int64_t i = 0; i < p_frames; i++) {
		w[i] = Vector2(buf[(size_t)i * 2], buf[(size_t)i * 2 + 1]);
	}
	return out;
}

// Starts an offline render at p_from_frame with the current plan and fresh effect state.
// Returns the plan's end frame (the export marker), or 0 when there is no plan.
int64_t AWCore::export_begin(int64_t p_from_frame) {
	off_plan = current_plan();
	off_pos = std::max<int64_t>(0, p_from_frame);
	off_rng = 0x9E3779B9u;
	off_enc.reset();
	if (!off_plan) {
		return 0;
	}
	off_rt = FxRuntime();
	off_rt.bind(off_plan, sample_rate);
	off_rt.next = off_pos;
	return off_plan->end_frame;
}

// Renders the next p_frames of the export and returns them as little-endian interleaved PCM:
// p_bits 16 = signed 16-bit with TPDF dither, 32 = IEEE float. "peak" is the largest sample before
// clipping, "clipped" counts samples beyond full scale. Effect state carries over between calls.
Dictionary AWCore::export_next(int64_t p_frames, int64_t p_bits) {
	Dictionary result;
	result["peak"] = 0.0;
	result["clipped"] = (int64_t)0;
	result["frames"] = (int64_t)0;
	if (!off_plan || p_frames <= 0) {
		result["data"] = PackedByteArray();
		return result;
	}
	std::vector<float> buf((size_t)p_frames * 2, 0.0f);
	render_voices(*off_plan, off_pos, p_frames, buf.data(), &off_rt);
	apply_master(*off_plan, off_pos, p_frames, buf.data(), &off_rt);
	off_rt.next = off_pos + p_frames;
	off_pos += p_frames;

	if (off_enc) { // Ogg: encode, return the bytes produced so far
		float peak = 0.0f;
		int64_t clipped = 0;
		for (int64_t i = 0; i < p_frames * 2; i++) {
			const float a = std::fabs(buf[(size_t)i]);
			peak = std::max(peak, a);
			clipped += a > 1.0f ? 1 : 0;
		}
		std::vector<uint8_t> bytes;
		off_enc->feed(buf.data(), p_frames, bytes);
		PackedByteArray data;
		data.resize((int64_t)bytes.size());
		if (!bytes.empty()) {
			std::memcpy(data.ptrw(), bytes.data(), bytes.size());
		}
		result["data"] = data;
		result["peak"] = (double)peak;
		result["clipped"] = clipped;
		result["frames"] = p_frames;
		return result;
	}

	const bool f32 = p_bits == 32;
	PackedByteArray data;
	data.resize(p_frames * 2 * (f32 ? 4 : 2));
	uint8_t *w = data.ptrw();
	float peak = 0.0f;
	int64_t clipped = 0;
	auto next_rand = [this]() -> float { // uniform in [-0.5, 0.5)
		off_rng = off_rng * 1664525u + 1013904223u;
		return (float)(off_rng >> 8) / 16777216.0f - 0.5f;
	};
	for (int64_t i = 0; i < p_frames * 2; i++) {
		const float x = buf[(size_t)i];
		const float a = std::fabs(x);
		peak = std::max(peak, a);
		if (a > 1.0f) {
			clipped++;
		}
		if (f32) {
			std::memcpy(w + i * 4, &x, 4);
		} else {
			float v = x * 32767.0f + next_rand() + next_rand();
			v = std::min(std::max(std::nearbyint(v), -32768.0f), 32767.0f);
			const int16_t s = (int16_t)v;
			w[i * 2] = (uint8_t)(s & 0xFF);
			w[i * 2 + 1] = (uint8_t)((s >> 8) & 0xFF);
		}
	}
	result["data"] = data;
	result["peak"] = (double)peak;
	result["clipped"] = clipped;
	result["frames"] = p_frames;
	return result;
}

// Chooses a compressed format for the export in progress: kind 1 = Ogg Vorbis (quality -0.1 .. 1.0).
// Call after export_begin. Returns false if the encoder couldn't be set up. (p_total_frames is
// kept for encoders whose headers need the length.)
bool AWCore::export_configure(int64_t p_kind, double p_quality, int64_t p_total_frames) {
	off_enc.reset();
	(void)p_total_frames;
	if (p_kind == 1) {
		off_enc = aw::make_ogg_encoder((int)sample_rate, (float)p_quality);
	}
	return (bool)off_enc;
}

// The last bytes of a compressed export (call once after the final export_next).
PackedByteArray AWCore::export_finish() {
	PackedByteArray data;
	if (off_enc) {
		std::vector<uint8_t> bytes;
		off_enc->finish(bytes);
		data.resize((int64_t)bytes.size());
		if (!bytes.empty()) {
			std::memcpy(data.ptrw(), bytes.data(), bytes.size());
		}
	}
	return data;
}

void AWCore::export_end() {
	off_enc.reset();
	off_plan.reset();
	off_rt = FxRuntime();
}

PackedVector2Array AWCore::render(int64_t p_frames) {
	PackedVector2Array out;
	if (p_frames <= 0) {
		return out;
	}
	out.resize(p_frames);
	Vector2 *w = out.ptrw();
	std::vector<float> buf((size_t)p_frames * 2, 0.0f);
	mix_transport(buf.data(), p_frames);
	for (int64_t i = 0; i < p_frames; i++) {
		w[i] = Vector2(buf[(size_t)i * 2], buf[(size_t)i * 2 + 1]);
	}
	if (tone_hz > 0.0) {
		const double step = tone_hz / sample_rate;
		for (int64_t i = 0; i < p_frames; i++) {
			const float t = (float)(std::sin(phase * 6.283185307179586) * tone_gain);
			w[i] += Vector2(t, t);
			phase += step;
			phase -= std::floor(phase);
		}
	}
	frames_rendered += p_frames;
	return out;
}

int64_t AWCore::get_frames_rendered() const {
	return frames_rendered;
}

void AWCore::reset() {
	phase = 0.0;
	frames_rendered = 0;
	playing.store(false);
	position.store(0);
}
