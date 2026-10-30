# In-editor self-test

`selftest.gd` drives the real plugin inside a real Godot editor: simulated mouse input, undo/redo,
the native engine (when built) and dry playback. Prints `PASS`/`FAIL` lines and `SELFTEST DONE fails=N`.

It isn't loaded by the plugin. To run it:

1. Copy it to `addons/audio_workstation/_selftest.gd`.
2. Temporarily add this at the end of `_enter_tree()` in `plugin.gd`:
   ```gdscript
   if OS.get_environment("AW_TEST") != "":
       var T = load("res://addons/audio_workstation/_selftest.gd")
       T.call_deferred("run", _main_screen)
   ```
3. Run the editor (Linux example; use `--audio-driver Dummy` without a sound device):
   ```
   AW_TEST=1 AW_OUT=/tmp/out AW_EXPECT_ENGINE=1 xvfb-run -a godot --editor --audio-driver Dummy --path . --quit-after 4000
   ```
   `AW_EXPECT_ENGINE=0` expects the "engine not built" fallback instead (run it from a copy of the project
   without `addons/audio_workstation/bin/` and `aw_engine.gdextension`).
4. Remove the hook and the copy again.

Last results (v0.12.0, Godot 4.7 stable, Linux, engine 0.8.1): 489 checks with the engine, 0 failures.
