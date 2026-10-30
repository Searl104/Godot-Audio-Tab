# Audio Workstation for Godot 4.7+ (developed against 4.8 beta) (interface phase, v0.9.1: automation)

An **Audio** main-screen tab for designing sound effects: layer clips on a free grid,
give each clip (and the master) an effect chain, and shape any parameter with Bezier
automation curves. This is the interface only. Nothing is audible yet (see TODO(logic)).

## Install
Copy `addons/audio_workstation` into your project, then enable **Audio Workstation** under
Project > Project Settings > Plugins. An **Audio** tab appears next to 2D / 3D / Script.
The included `project.godot` is a ready-to-open test project with demo content.

## Layout (from the sketch)
    toolbar: File, Edit, Undo/Redo, transport, clock, Snap, Export WAV
    [reserved] [ Timeline: clip grid ] [ Timeline: automation curves ]
    [Master] [Clip]  Effect Chain:  Clip | Limiter | Reverb | Chorus | [+]

## Timing model
Each clip has its own clock, called **clip time**, which is time in its audio. The clip's curves,
fades and length all live on that clock, so a key always sits on the same moment of the sound.

Pitch is playback rate. When the pitch drops, the audio plays slower, the clip lasts longer on the
timeline, and the clip's curve playhead moves slower to match. For example, at −12 semitones
1 s of audio takes 2 s. Trims, splits and fades work from the waveform you see, so the cut lands
on the sound under the cursor. The Master chain runs on project time.

## Controls
**Clip grid**
- Drag a clip to move it in time and across rows; all selected clips move together.
- Drag a clip's left or right edge to trim. Trimming the left edge also moves the source offset,
  and the clip's curves shift with it, so every key stays on the same moment of the sound.
  Keys trimmed out of view are kept, so trimming back out brings them back.
- Drag the small squares at a clip's top corners to set fades.
- Drag on empty space to box-select. Click empty space to deselect and move the playhead.
- Shift adds to the selection, Ctrl toggles. Hold Alt while dragging to ignore snap.
- Drop audio files from the FileSystem dock. Several files land on consecutive rows.
- Right-click for Split, Duplicate, Mute and Delete.
- Keys: S splits at the playhead, Ctrl+D duplicates, Del deletes, Ctrl+A selects all, Esc deselects, F fits.
- Ruler: the top strip edits the loop region; click or drag below it to seek.

**Curve graph** (controls follow Godot's Bezier editor)
- Click a key to select it; drag to move. Shift locks an axis, Alt ignores snap.
- Drag the handles of selected keys. Handle modes are Free, Linear, Balanced and Mirrored (right-click).
- Double-click or Ctrl+click adds a key to the active curve, or to the curve under the mouse.
- Drag on empty space to box-select keys. Del deletes, Ctrl+A selects all, F frames.
- Wheel zooms, Shift+wheel scrolls, middle-drag pans.
- Right-click also offers Smooth and Ease (flat handles), plus Solo, Mute and Remove for the curve under the mouse.
- **Scales**: each curve fills the graph's height on its parameter's natural scale. Frequencies
  (Hz) use a log scale (equal space per octave). Decibels use a mixing-fader scale (more room
  near 0 dB). Everything else is linear. Keys are stored on that scale, so a straight line between
  two keys is an even change to the ear, such as a filter sweep that moves evenly through octaves.
  Frequency sliders on the cards are logarithmic too.
- **Value axis** (right edge): shows the selected curve's range in real units, on that curve's
  scale. Hz uses decades (20, 50, 100 … 1k … 20k), dB crowds toward 0, and pitch uses octaves first
  (0, ±12, ±24). The unit sits above the axis, the grid lines follow the ticks, and the selected
  key's exact value is tagged on the axis while you drag. Ticks thin out when the graph is short.
- **Clip Time / Project Time** toggle: show the clip's curves on its own audio clock (0 = clip start,
  playhead at the clip's playback rate), or on the project timeline, where pitch changes stretch
  them to line up with the clip block. Keys can be edited in either view. The Master chain always
  uses project time.

**LFO** (right-click a curve, its dot, or its parameter row › LFO…)
- A panel docks beside the graph with Shape (sine, triangle, square, saw, random), Max, Min,
  Freq, Fade In and Fade Out. Slider drags preview live and undo as one step.
- Between its start and end (the whole clip by default) the parameter swings between Min and Max.
  Fade In and Fade Out blend from the drawn curve into the LFO and back out. The drawn curve stays
  visible as a faint line and its keys stay editable.
- The swing uses the curve's scale (a cutoff LFO swings evenly in octaves). Freq runs on the
  clip's clock, so it slows when Pitch drops. An LFO on Pitch itself changes the clip's timing.
- While the panel is open, the graph shows the Max/Min lines and an "LFO depth" strip with the
  fades, and the axis tags the Max/Min values. Dots of curves with an LFO carry a wave mark, and the
  card's parameter row reads "lfo".
- Trims and splits keep the LFO on the same moments of the sound. If the LFO reaches the clip's
  end, a right trim keeps it reaching the end.
- **Bake to Keys** replaces the LFO with ordinary keys (16 per cycle, with sharp edges for square,
  saw and random). **Remove LFO** removes it. On/Off keeps the settings.

**Dots**: one colour per curve, in the dot column and on each parameter.
- Click cycles **On / Dim / Off**. Dim curves are drawn faint and can't be edited; Off curves are hidden.
- Shift+click solos the curve.
- Right-click offers Select, On/Dim/Off, Solo, Mute, Show All and Remove Curve.
- A grey outline means the parameter has no curve. It has a slider and a field instead; right-click it and choose **Make Curve**.

**Effect chain**
- Master / Clip tabs switch between the master chain and the selected clip's chain. The curve graph follows the active tab.
- Cards are processed left to right. Drag a card's header onto another card to reorder.
- The ⋮ menu on each card offers Move, Reset and Remove. The toggle on the card bypasses it. The + card adds an effect.
- The first card is the fixed source stage: **Clip** (Gain, Pitch, Pan) or **Output** (Volume).
  Pitch is applied as playback rate, so it changes the clip's length too.

Global keys: Space play/pause, Enter stop, Home go to start, L loop, G snap on/off, Ctrl+S save.

## Code map
    plugin.gd                       registers the tab
    core/aw_project.gd              saved document (clips, master chain, loop), demo content
    core/aw_clip.gd                 grid block: time, row, trim, fades, its own chain
    core/aw_clip_warp.gd            clip time <-> project time through the playback rate (pitch)
    core/aw_chain.gd                effects + curves; automation keys live in an Animation (Bezier tracks)
    core/aw_effect.gd, aw_effect_library.gd   effect cards; parameter keys = real AudioEffect property names
    core/aw_lfo.gd                  LFO settings, waveform and fade envelope
    core/aw_curve.gd, aw_curve_math.gd        curve metadata (colour, On/Dim/Off, handle modes, scale),
                                              handle and scale maths
    core/aw_document.gd             selection, view state, and every undoable edit
    core/aw_engine.gd               ENGINE BOUNDARY: finds the native AWCore class, falls back to stubs
    extension/                      C++ GDExtension source (godot-cpp 10.0.0-stable, SCons); see BUILDING.md
    bin/ (after build)              libawengine.<platform>... + aw_engine.gdextension next to plugin.cfg
    core/aw_time_view.gd            zoom/scroll for one time axis
    ui/aw_lfo_panel.gd              the docked LFO panel
    ui/aw_curve_axis.gd             value axis + tick generation (linear / log / fader / semitones)
    ui/*                            toolbar, clip grid, curve graph + dot column, effect cards, main screen

## Native engine (milestones 1 to 4)
The plugin looks for the `AWCore` class at startup. With the library built, the toolbar shows
`● Engine 0.5.0`; without it, `○ Engine not built` (or `Engine X is out of date` if the library is older
than the plugin: rebuild it) and everything except sound still works. Build steps: `BUILDING.md`.

**Dry playback (milestone 2).** Play, Stop, seek, loop and double-click audition now make sound.
- `AWSourceCache` decodes files with Godot's own decoders (WAV, Ogg, MP3, imported resources, or raw files
  by path) and hands stereo frames at the audio mix rate to the core.
- `AWEngine` builds a plan of clip voices from the project (start, offset, length, fades, static Gain and
  Pan, pitch as a playback-rate table) and an `AudioStreamPlayer` plays the core through `AWPreviewStream`.
  The playhead is the real playback position; the sound stops by itself at its end (or loops).
- Waveforms in the clip grid are real peaks of the source file (clips with no audio keep the placeholder).
- Not yet: export/bake (5), save/open (6). Clips without an audio file stay silent but still move the playhead.
- The decoder lag of Godot's resampler (about 2 source frames) is removed, so a source sample lands on
  the exact frame the timing model says.
- **Automation (milestone 3).** The Gain, Pan and Pitch curves of a clip (including their LFOs) and the
  Output volume curve are audible. Each is sampled every 64 frames (about 1.5 ms) into a table; the mixer
  interpolates it per sample. Clip curves run on the clip's own clock, so they slow down with Pitch; the Output
  curve runs on project time. Square LFO edges become 1.5 ms ramps (no clicks). A value at the bottom of a dB
  range (-60 dB) is true silence. Tables are cached per curve and rebuilt only when its keys, LFO or the clip
  length change, so dragging a key or an LFO slider re-samples just that curve.
  Sampling is native (`AWCore.sample_curve`, a C++ port of `AWChain.sample`; the self-test compares it with the
  GDScript version on every scale, LFO shape and unit). It also draws the curve graph and builds the pitch
  warp. Eight layered 20 s clips with 24 curves, all with 20 Hz LFOs: plan rebuild 61 ms (it was 8.9 s in GDScript);
  an LFO edit re-samples one curve in about 7 ms.
  Edits while playing are heard within 50 ms.
- **Effects (milestone 4, in progress).** Effect cards now run in the native engine, in chain order after the
  Clip card (per clip) and after Output (master). Done so far: Low Pass, High Pass, Band Pass, EQ (6 bands) and
  Amplify. The other cards (Distortion, Delay, Reverb, Compressor, Limiter, Chorus, Phaser, Stereo Enhance) are
  skipped for now, so they don't sound yet. The DSP is our own (RBJ biquads), built to fit the engine rather than
  matching Godot's effects.
  - Parameters come from the same curve tables as Gain/Pan, updated every 32 frames; a curve or LFO on a cutoff
    sweeps the filter. Clip chains read their curves on the clip's own clock; the master chain on project time.
  - Tails and the end marker: the orange **end marker** on the timeline sets where the exported sound ends, so one
    marker sets both the length and the tail. Drag its flag on a ruler, or type a time in the Export dock's End
    field. Chains that ring on (filters, EQ) keep sounding after their clip until the marker; a marker before the
    last clip cuts the sound short. **Auto** (the default, dashed marker) puts it at the last clip's end, plus 2.5 s
    when a ringing card is in a chain. Bypassed cards are left out.
  - Filter memory carries across audio blocks and is cleared on a seek or loop wrap, so the first moments after a
    jump start from silence (a short pre-roll is possible later).
  - Resonance maps to Q: 0.35 at 0, 0.707 (flat) at 0.5, about 14 at 1.
- Interpolation is 4-point cubic; pitching up does not anti-alias yet.
- Alt+wheel over the clip grid changes the row height (default 48 px), so waveforms can be made larger.

## Placeholders (search for TODO(logic))
- `AWEngine`: `render_wav` and `render_audio_stream` are stubs (milestone 5).
- Without the native engine, waveforms are a fake pattern (`AWEngine.get_waveform_peaks`) and
  `AWDocument.tick_preview` is a fallback clock that moves the playhead.
- Save, Open and both exports only post a status message.

## Verified
- Tested on Godot 4.7 stable: all scripts parse and the plugin loads without errors.
- An automated run inside the rendered editor passed 135 checks. It covered model edits with undo/redo, and real
  mouse events on the controls: clip move/trim/fade, box-select, multi-move, key move, handle drag,
  key insert, the dot cycle, Make Curve and slider drags. It also checks that curves keep their values at the same
  moments after a left trim, and that scales round-trip and a straight log-scale line gives an even sweep.
  The playback-rate timing is checked against the exact formula, and splits and trims are checked on
  a pitched clip.
- Not covered: drag-and-drop from the FileSystem dock, card reordering by drag, popup menus clicked by a person.

## Open points for the logic phase
- A per-curve scale toggle (e.g. linear vs log) is planned. The scale is already stored per
  curve, and `AWChain.set_curve_scale()` converts the keys; it only needs a UI control.
- Curve keys are stored as 0..1 on the curve's scale. The engine should read real values with
  `AWChain.sample()`, never the raw Animation track.
- `AWChain.sample()` already includes the LFO. The engine needs nothing extra, as long as it
  samples curves often enough for a 20 Hz LFO (≥ 200 Hz control rate is plenty).
- The timing contract for the engine is written at the top of `AWEngine.set_project()`. Evaluate
  clip curves at `clip.project_to_local(t)`, and play the audio at rate 2^(pitch/12).
- Undo and Redo are toolbar buttons. Ctrl+Z from this tab is not wired or tested.
- Projects save as `.tres`/`.res`. A custom `.sfx`-style extension needs a ResourceFormatSaver/Loader.
- The reserved column is a placeholder.

## Effect panels and the control kit (v0.11)

Effects can have a custom detail panel. It opens in the **Audio Effect** dock (bottom by default; double-click a card's header or use ⋮ > Open Panel). Every engine-capable effect has one (Low Pass, High Pass, Band Pass, EQ, Amplify), shown compactly on their cards (small response plot plus knobs); effects not yet ported keep their generic parameter rows.

- `ui/kit/aw_binding.gd`: `AWParamBinding` is the only thing a control uses to edit a parameter (undo, live preview, curve dot state, right-click menu, one undo step for multi-parameter drags).
- `ui/kit/`: `AWKnob` (optional bipolar and view range), `AWResponsePlot` (log-frequency plot with draggable handles). Gestures: drag, Shift = fine, wheel, double-click = reset, right-click = curve options. A driven parameter shows a yellow dotted ring and a click selects its curve.
- `ui/kit/aw_panel_registry.gd`: effect type to panel. To add one, subclass `AWEffectPanel` (`ui/panels/`), register it there.
- `core/aw_filter_response.gd`: the drawn response mirrors the engine's biquads; the self-test compares it with the engine's measured output.

The LFO editor is its own **Audio LFO** dock, a single column that suits a tall side dock (lower right by default; it also works at the bottom). It has a waveform preview, shape buttons and knobs for Freq, **Accel** (frequency drift, shown in mHz/s, fine near zero; negative slows down and stops at 0 Hz), Max, Min, Fade In, Fade Out and **Smoothing** (eases the fades). Beside them, **All LFOs** lists every LFO in the project as `Clip 2\Low Pass\Cutoff` (Master first); click one to select its clip and open it. The **LFOs** button in the curve header brings the dock up. Needs engine 0.4.2 or newer (the engine evaluates Accel and Smoothing natively).

Knob gestures: drag, Shift = fine, wheel, **double-click to type a value** (`2k` works, Enter applies, Esc cancels), **Ctrl+click to reset**, right-click for options.
