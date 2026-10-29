#include "aw_preview_stream.h"

#include <cstring>

using namespace godot;

void AWPreviewStream::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_core", "core"), &AWPreviewStream::set_core);
	ClassDB::bind_method(D_METHOD("get_core"), &AWPreviewStream::get_core);
}

void AWPreviewStream::set_core(const Ref<AWCore> &p_core) {
	core = p_core;
}

Ref<AWCore> AWPreviewStream::get_core() const {
	return core;
}

Ref<AudioStreamPlayback> AWPreviewStream::_instantiate_playback() const {
	Ref<AWPreviewPlayback> pb;
	pb.instantiate();
	pb->set_core(core);
	return pb;
}

String AWPreviewStream::_get_stream_name() const {
	return "Audio Workstation preview";
}

double AWPreviewStream::_get_length() const {
	return 0.0;
}

bool AWPreviewStream::_is_monophonic() const {
	return true;
}

int32_t AWPreviewPlayback::_mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) {
	if (core.is_valid()) {
		return core->mix(p_buffer, p_frames);
	}
	std::memset(p_buffer, 0, sizeof(AudioFrame) * (size_t)p_frames);
	return p_frames;
}
