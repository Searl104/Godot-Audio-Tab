# Third-party code

Vendored so the engine can write Ogg Vorbis files (Godot itself only decodes them). Both are BSD-3-Clause
licensed, see `ogg/COPYING` and `vorbis/COPYING`.

- `ogg/`: libogg 1.3.5 (xiph/ogg tag v1.3.5): `bitwise.c`, `framing.c` and headers. `config_types.h` is hand-written.
- `vorbis/`: libvorbis 1.3.7 (xiph/vorbis tag v1.3.7): the encoder and the code it shares with the decoder
  (no `vorbisfile.c`, no tuning tools). Unmodified.
