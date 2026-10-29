# Building the audio engine

The Audio Workstation's native engine is a GDExtension in `extension/`. It's built with
godot-cpp 10.0.0-stable against the Godot 4.7 API. The plugin works without it (editing,
undo, curves), but playback and export need it. The toolbar shows **Engine x.y.z** when it's
loaded, or **Engine not built** when it isn't.

## Prerequisites
- Python 3.8+ and SCons 4 (`python -m pip install scons`)
- A C++17 compiler: GCC or Clang (Linux), Xcode command-line tools (macOS), MSVC 2022 or MinGW (Windows)

## Build
```
git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp.git extension/godot-cpp
cd extension
scons                              # debug build: this is what the editor loads
scons target=template_release      # optional: release build for exported games
```
The first build compiles godot-cpp, which takes a few minutes; later builds are quick.
The libraries go to `addons/audio_workstation/bin/`, and the build installs
`addons/audio_workstation/aw_engine.gdextension`. Restart the editor once after the first
build. After that the extension hot-reloads when you rebuild.

Cross-compiling from Linux: `scons platform=windows` (needs MinGW-w64).

## CI
`.github/workflows/build-engine.yml` builds Linux (x86_64, arm64), Windows (x86_64) and macOS
(universal), debug and release. It uploads an `audio_workstation-addon` artifact with every
binary and the manifest, ready to drop into a project.
