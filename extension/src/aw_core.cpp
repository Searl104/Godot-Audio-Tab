#include "aw_core.h"

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
	ClassDB::bind_method(D_METHOD("set_plan", "voices"), &AWCore::set_plan);
	ClassDB::bind_method(D_METHOD("get_plan_end"), &AWCore::get_plan_end);
	ClassDB::bind_method(D_METHOD("play", "from_frame"), &AWCore::play);
	ClassDB::bind_method(D_METHOD("stop"), &AWCore::stop);
	ClassDB::bind_method(D_METHOD("seek", "frame"), &AWCore::seek);
	ClassDB::bind_method(D_METHOD("set_loop", "enabled", "start_frame", "end_frame"), &AWCore::set_loop);
	ClassDB::bind_method(D_METHOD("is_playing"), &AWCore::is_playing);
	ClassDB::bind_method(D_METHOD("get_position"), &AWCore::get_position);
	ClassDB::bind_method(D_METHOD("render_range", "from_frame", "frames"), &AWCore::render_range);
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

// Adds every voice that overlaps [from, from + frames) into the interleaved buffer.
void AWCore::render_voices(const Plan &p_plan, int64_t p_from, int64_t p_frames, float *r_out) {
	for (const Voice &v : p_plan.voices) {
		if (!v.source) {
			continue;
		}
		const int64_t j0 = std::max<int64_t>(0, v.start - p_from);
		const int64_t j1 = std::min<int64_t>(p_frames, (int64_t)std::ceil(v.play_frames) + v.start - p_from);
		if (j0 >= j1) {
			continue;
		}
		const float gl = v.pan > 0.0f ? 1.0f - v.pan : 1.0f;
		const float gr = v.pan < 0.0f ? 1.0f + v.pan : 1.0f;
		const Source &src = *v.source;
		// Cursor into the rate table, advanced monotonically across the block.
		size_t cur = 0;
		const bool table = !v.cum.empty();
		if (table) {
			const double p0 = (double)(p_from + j0 - v.start);
			if (p0 > 0.0) {
				cur = (size_t)(std::upper_bound(v.cum.begin(), v.cum.end(), p0) - v.cum.begin());
				cur = cur == 0 ? 0 : cur - 1;
			}
		}
		const double smax = table ? (double)(v.rates.size() - 1) * (double)v.step : 0.0;
		for (int64_t j = j0; j < j1; j++) {
			const double p = (double)(p_from + j - v.start);
			double s;
			if (!table) {
				s = p * v.rates[0];
			} else if (p <= 0.0) {
				s = p * v.rates[0];
			} else if (p >= v.cum.back()) {
				s = smax + (p - v.cum.back()) * v.rates.back();
			} else {
				while (cur + 2 < v.cum.size() && p >= v.cum[cur + 1]) {
					cur++;
				}
				const double span = v.cum[cur + 1] - v.cum[cur];
				const double f = span > 0.0 ? (p - v.cum[cur]) / span : 0.0;
				s = ((double)cur + f) * (double)v.step;
			}
			if (s < 0.0 || s >= v.length) {
				continue;
			}
			const double x = v.offset + s;
			if (x < -1.0 || x > (double)src.frames) {
				continue;
			}
			float g = v.gain;
			if (v.fade_in > 0.0 && s < v.fade_in) {
				g *= (float)(s / v.fade_in);
			}
			if (v.fade_out > 0.0 && s > v.length - v.fade_out) {
				g *= (float)std::max(0.0, (v.length - s) / v.fade_out);
			}
			r_out[j * 2] += aw_hermite(src, x, 0) * g * gl;
			r_out[j * 2 + 1] += aw_hermite(src, x, 1) * g * gr;
		}
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

// --- Plan -----------------------------------------------------------------------

int64_t AWCore::set_plan(const Array &p_voices) {
	auto np = std::make_shared<Plan>();
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
		v.gain = d.get("gain", 1.0);
		v.pan = CLAMP((float)(double)d.get("pan", 0.0), -1.0f, 1.0f);
		const PackedFloat32Array rates = d.get("rates", PackedFloat32Array());
		v.rates.assign(rates.ptr(), rates.ptr() + rates.size());
		v.step = d.get("rate_step", 64);
		v.prepare();
		np->end_frame = std::max(np->end_frame, v.start + (int64_t)std::ceil(v.play_frames));
		np->voices.push_back(std::move(v));
	}
	{
		std::lock_guard<std::mutex> lock(plan_mutex);
		retired.push_back(plan);
		plan = np;
	}
	// Keep the last couple of plans alive so the audio thread never drops the final reference.
	while (retired.size() > 2) {
		retired.erase(retired.begin());
	}
	return np->end_frame;
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
		render_voices(*pl, pos, limit, r_out + done * 2);
		pos += limit;
		done += limit;
		if (loop && pos >= loop_end.load()) {
			pos = loop_start.load();
		}
	}
	position.store(pos);
}

int32_t AWCore::mix(AudioFrame *p_buffer, int32_t p_frames) {
	float buf[2048];
	int32_t done = 0;
	while (done < p_frames) {
		const int32_t n = std::min(p_frames - done, 1024);
		mix_transport(buf, n);
		for (int32_t i = 0; i < n; i++) {
			p_buffer[done + i].left = buf[i * 2];
			p_buffer[done + i].right = buf[i * 2 + 1];
		}
		done += n;
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
		render_voices(*pl, p_from_frame, p_frames, buf.data());
	}
	Vector2 *w = out.ptrw();
	for (int64_t i = 0; i < p_frames; i++) {
		w[i] = Vector2(buf[(size_t)i * 2], buf[(size_t)i * 2 + 1]);
	}
	return out;
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
