#pragma once
// Streaming encoder for the export: Ogg Vorbis (libvorbis). Plain C++, no Godot types. Feed interleaved stereo floats in chunks of any size;
// the bytes produced so far are appended to `r_out` (possibly none), and finish() flushes the rest.

#include <cstdint>
#include <memory>
#include <vector>

namespace aw {

class Encoder {
public:
	virtual ~Encoder() = default;
	virtual void feed(const float *p_interleaved, int64_t p_frames, std::vector<uint8_t> &r_out) = 0;
	virtual void finish(std::vector<uint8_t> &r_out) = 0;
};

// Ogg Vorbis, variable bit rate. p_quality -0.1 .. 1.0 (0.4 is about 128 kbit/s for stereo).
// Returns null when libvorbis rejects the settings.
std::unique_ptr<Encoder> make_ogg_encoder(int p_rate, float p_quality);

} // namespace aw
