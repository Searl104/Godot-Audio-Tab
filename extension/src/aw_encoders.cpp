#include "aw_encoders.h"

#include <algorithm>
#include <cstdlib>

#include <ogg/ogg.h>
#include <vorbis/codec.h>
#include <vorbis/vorbisenc.h>

namespace aw {

namespace {

// ---- Ogg Vorbis ------------------------------------------------------------------------------
class OggEncoder : public Encoder {
	ogg_stream_state os;
	vorbis_info vi;
	vorbis_comment vc;
	vorbis_dsp_state vd;
	vorbis_block vb;
	bool ready = false;
	bool done = false;

	static void put_page(const ogg_page &p_page, std::vector<uint8_t> &r_out) {
		r_out.insert(r_out.end(), p_page.header, p_page.header + p_page.header_len);
		r_out.insert(r_out.end(), p_page.body, p_page.body + p_page.body_len);
	}

	void drain(std::vector<uint8_t> &r_out) {
		ogg_packet op;
		ogg_page og;
		while (vorbis_analysis_blockout(&vd, &vb) == 1) {
			vorbis_analysis(&vb, nullptr);
			vorbis_bitrate_addblock(&vb);
			while (vorbis_bitrate_flushpacket(&vd, &op)) {
				ogg_stream_packetin(&os, &op);
				while (ogg_stream_pageout(&os, &og)) {
					put_page(og, r_out);
				}
			}
		}
	}

public:
	std::vector<uint8_t> headers;

	OggEncoder(int p_rate, float p_quality) {
		vorbis_info_init(&vi);
		if (vorbis_encode_init_vbr(&vi, 2, p_rate, p_quality) != 0) {
			vorbis_info_clear(&vi);
			return;
		}
		vorbis_comment_init(&vc);
		vorbis_comment_add_tag(&vc, "ENCODER", "Audio Workstation (libvorbis)");
		vorbis_analysis_init(&vd, &vi);
		vorbis_block_init(&vd, &vb);
		ogg_stream_init(&os, (int)(std::rand() & 0x7FFFFFFF));
		ogg_packet h, hc, hcode;
		vorbis_analysis_headerout(&vd, &vc, &h, &hc, &hcode);
		ogg_stream_packetin(&os, &h);
		ogg_stream_packetin(&os, &hc);
		ogg_stream_packetin(&os, &hcode);
		ogg_page og;
		while (ogg_stream_flush(&os, &og)) {
			put_page(og, headers);
		}
		ready = true;
	}

	bool ok() const { return ready; }

	~OggEncoder() override {
		if (ready) {
			ogg_stream_clear(&os);
			vorbis_block_clear(&vb);
			vorbis_dsp_clear(&vd);
			vorbis_comment_clear(&vc);
			vorbis_info_clear(&vi);
		}
	}

	void feed(const float *p_in, int64_t p_frames, std::vector<uint8_t> &r_out) override {
		if (!ready || done) {
			return;
		}
		if (!headers.empty()) {
			r_out.insert(r_out.end(), headers.begin(), headers.end());
			headers.clear();
		}
		int64_t at = 0;
		while (at < p_frames) {
			const int n = (int)std::min<int64_t>(p_frames - at, 8192);
			float **buf = vorbis_analysis_buffer(&vd, n);
			for (int i = 0; i < n; i++) {
				buf[0][i] = p_in[(at + i) * 2];
				buf[1][i] = p_in[(at + i) * 2 + 1];
			}
			vorbis_analysis_wrote(&vd, n);
			drain(r_out);
			at += n;
		}
	}

	void finish(std::vector<uint8_t> &r_out) override {
		if (!ready || done) {
			return;
		}
		if (!headers.empty()) {
			r_out.insert(r_out.end(), headers.begin(), headers.end());
			headers.clear();
		}
		done = true;
		vorbis_analysis_wrote(&vd, 0);
		drain(r_out);
		ogg_page og;
		while (ogg_stream_flush(&os, &og)) {
			put_page(og, r_out);
		}
	}
};

} // namespace

std::unique_ptr<Encoder> make_ogg_encoder(int p_rate, float p_quality) {
	auto e = std::make_unique<OggEncoder>(p_rate, std::min(std::max(p_quality, -0.1f), 1.0f));
	if (!e->ok()) {
		return nullptr;
	}
	return e;
}

} // namespace aw
