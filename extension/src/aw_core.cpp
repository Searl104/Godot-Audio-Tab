#include "aw_core.h"

#include <cmath>

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

PackedVector2Array AWCore::render(int64_t p_frames) {
	PackedVector2Array out;
	if (p_frames <= 0) {
		return out;
	}
	out.resize(p_frames);
	Vector2 *w = out.ptrw();
	if (tone_hz <= 0.0) {
		for (int64_t i = 0; i < p_frames; i++) {
			w[i] = Vector2();
		}
	} else {
		const double step = tone_hz / sample_rate;
		for (int64_t i = 0; i < p_frames; i++) {
			const float s = (float)(std::sin(phase * 6.283185307179586) * tone_gain);
			w[i] = Vector2(s, s);
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
}
